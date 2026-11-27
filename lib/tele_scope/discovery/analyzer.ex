defmodule TeleScope.Discovery.Analyzer do
  @moduledoc """
  Analyzes the abstract forms of one module.

  Produces `TeleScope.Discovery.CallSite`s for:

    * `:telemetry.execute/2,3`, `execute_lazy/2,3`, `span/3`
    * `:telemetry.attach/4`, `attach_many/4`, `detach/1`
    * `Telemetry.Metrics.{counter,sum,last_value,summary,distribution}/1,2`
    * calls watched by library rules (`TeleScope.Discovery.Rule`)
    * calls to *wrapper functions* - functions whose telemetry event name
      depends on one of their parameters (e.g. `Finch.Telemetry.start/3`)

  Wrapper resolution works through *templates*: a template is a telemetry
  call whose event pattern still references `{:param, i}`. When a call to
  the wrapper is found, its argument expressions are substituted into the
  template. Within a module this is iterated to a fixpoint (wrapper chains,
  default-argument clauses); across modules the scanner feeds in the
  templates of other modules (`external_templates`).
  """

  alias TeleScope.Discovery.{CallSite, Eval}
  alias TeleScope.EventName

  @emitters %{
    {:execute, 2} => :execute,
    {:execute, 3} => :execute,
    {:execute_lazy, 2} => :execute_lazy,
    {:execute_lazy, 3} => :execute_lazy,
    {:span, 3} => :span
  }

  @metric_funs [:counter, :sum, :last_value, :summary, :distribution]
  @max_local_rounds 6

  @doc "MFAs whose presence in a module's import table makes it worth decoding."
  def interesting_imports do
    emit = for {{f, a}, _} <- @emitters, do: {:telemetry, f, a}
    handlers = [{:telemetry, :attach, 4}, {:telemetry, :attach_many, 4}, {:telemetry, :detach, 1}]

    metrics =
      for f <- @metric_funs, a <- [1, 2], do: {:"Elixir.Telemetry.Metrics", f, a}

    emit ++ handlers ++ metrics
  end

  @type template :: %{kind: atom(), patterns: [EventName.pattern()], line: integer() | nil}

  @doc """
  Analyzes `forms` of `module`.

  Options:
    * `:app` - owning OTP application
    * `:external_templates` - `%{mfa => [template]}` from other modules
    * `:rules` - list of rule modules with `watched_calls/0` + `on_call/3`

  Returns `%{sites: [CallSite.t()], templates: %{mfa => [template]}}` where
  `templates` are the wrapper templates *defined by this module*.
  """
  def analyze(module, forms, opts \\ []) do
    app = Keyword.get(opts, :app)
    external = Keyword.get(opts, :external_templates, %{})
    rules = Keyword.get(opts, :rules, [])
    watched = rule_index(rules)

    {functions, files} = index_functions(forms)
    ctx = %{module: module, app: app, functions: functions, files: files, watched: watched}

    iterate(ctx, external, %{}, 0)
  end

  defp iterate(ctx, external, local_templates, round) do
    templates = Map.merge(external, local_templates)

    {sites, new_local} =
      Enum.reduce(ctx.functions, {[], %{}}, fn {{name, arity}, clauses}, {sites, tmpls} ->
        mfa = {ctx.module, name, arity}
        file = Map.get(ctx.files, {name, arity})

        Enum.reduce(clauses, {sites, tmpls}, fn clause, acc ->
          env = Eval.env_for_clause(clause, ctx.functions)
          fctx = Map.merge(ctx, %{mfa: mfa, file: file, env: env, templates: templates})
          walk(clause_body(clause), fctx, acc)
        end)
      end)

    new_local = Map.new(new_local, fn {k, v} -> {k, Enum.uniq(v)} end)

    if new_local == local_templates or round >= @max_local_rounds do
      %{sites: finalize(sites), templates: new_local}
    else
      iterate(ctx, external, new_local, round + 1)
    end
  end

  defp clause_body({:clause, _, _params, guards, body}), do: [guards, body]

  defp index_functions(forms) do
    {_file, fun_map, file_map} =
      Enum.reduce(forms, {nil, %{}, %{}}, fn
        {:attribute, _, :file, {file, _}}, {_, funs, files} ->
          {to_string(file), funs, files}

        {:function, _anno, name, arity, clauses}, {file, funs, files} ->
          {file, Map.put(funs, {name, arity}, clauses), Map.put(files, {name, arity}, file)}

        _, acc ->
          acc
      end)

    {fun_map, file_map}
  end

  defp rule_index(rules) do
    for rule <- rules,
        Code.ensure_loaded?(rule),
        function_exported?(rule, :watched_calls, 0),
        mfa <- rule.watched_calls(),
        into: %{},
        do: {mfa, rule}
  end

  # ---- traversal -----------------------------------------------------------

  defp walk({:call, anno, callee, args} = _node, ctx, acc) do
    acc = walk(args, ctx, acc)
    acc = walk(callee, ctx, acc)
    handle_call(callee, args, anno, ctx, acc)
  end

  defp walk(tuple, ctx, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> walk(ctx, acc)
  end

  defp walk(list, ctx, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, ctx, &2))
  defp walk(_other, _ctx, acc), do: acc

  defp handle_call({:remote, _, {:atom, _, :telemetry}, {:atom, _, fun}}, args, anno, ctx, acc) do
    arity = length(args)

    cond do
      kind = Map.get(@emitters, {fun, arity}) ->
        emitter(kind, hd(args), anno, ctx, acc)

      {fun, arity} in [{:attach, 4}, {:attach_many, 4}] ->
        attach(fun, args, anno, ctx, acc)

      {fun, arity} == {:detach, 1} ->
        site = base_site(:detach, anno, ctx)
        add_site(%{site | handler: %{id: literal_or_unknown(hd(args))}}, acc)

      true ->
        acc
    end
  end

  defp handle_call(
         {:remote, _, {:atom, _, :"Elixir.Telemetry.Metrics"}, {:atom, _, fun}},
         args,
         anno,
         ctx,
         acc
       )
       when fun in @metric_funs and length(args) in [1, 2] do
    metric(fun, args, anno, ctx, acc)
  end

  defp handle_call({:remote, _, {:atom, _, m}, {:atom, _, f}}, args, anno, ctx, acc) do
    mfa = {m, f, length(args)}
    acc = maybe_rule(mfa, args, anno, ctx, acc)
    maybe_wrapper(mfa, args, anno, ctx, acc)
  end

  # Inside the telemetry library itself, events such as
  # [:telemetry, :handler, :failure] are emitted with *local* calls. Only
  # literal names are taken: telemetry's own span/3 etc. must not become
  # wrapper templates (their callers are handled as direct emitters).
  defp handle_call({:atom, _, f}, [name | _] = args, anno, %{module: :telemetry} = ctx, acc) do
    case Map.get(@emitters, {f, length(args)}) do
      nil ->
        acc

      kind ->
        patterns = Eval.name(name, ctx.env)

        if patterns != [] and Enum.all?(patterns, &EventName.literal?/1),
          do: emitter(kind, name, anno, ctx, acc),
          else: acc
    end
  end

  defp handle_call({:atom, _, f}, args, anno, ctx, acc) do
    mfa = {ctx.module, f, length(args)}
    maybe_wrapper(mfa, args, anno, ctx, acc)
  end

  defp handle_call(_callee, _args, _anno, _ctx, acc), do: acc

  # ---- emitters ------------------------------------------------------------

  defp emitter(kind, name_expr, anno, ctx, {sites, tmpls}) do
    patterns = Eval.name(name_expr, ctx.env)
    line = line(anno)
    {parametric, plain} = Enum.split_with(patterns, &EventName.parametric?/1)

    tmpls =
      if parametric == [] do
        tmpls
      else
        Map.update(tmpls, ctx.mfa, [%{kind: kind, patterns: parametric, line: line}], fn l ->
          [%{kind: kind, patterns: parametric, line: line} | l]
        end)
      end

    # Report the direct call site with parameters forgotten: it is a partial
    # / dynamic pattern unless resolved at some wrapper call site.
    reported = plain ++ Enum.map(parametric, &EventName.forget_params/1)

    site = %{
      base_site(kind, anno, ctx)
      | patterns: Enum.uniq(reported),
        extra: if(parametric != [], do: %{wrapper_template: true}, else: %{})
    }

    add_site(site, {sites, tmpls})
  end

  defp maybe_wrapper(mfa, args, anno, ctx, {sites, tmpls} = acc) do
    case Map.fetch(ctx.templates, mfa) do
      {:ok, templates} when mfa != ctx.mfa ->
        Enum.reduce(templates, acc, fn tmpl, {sites, tmpls} ->
          resolved =
            tmpl.patterns
            |> Enum.flat_map(&Eval.substitute(&1, args, ctx.env))
            |> Enum.uniq()

          {parametric, plain} = Enum.split_with(resolved, &EventName.parametric?/1)

          tmpls =
            if parametric == [] do
              tmpls
            else
              t = %{kind: tmpl.kind, patterns: parametric, line: tmpl.line}
              Map.update(tmpls, ctx.mfa, [t], &[t | &1])
            end

          acc =
            if plain == [] do
              {sites, tmpls}
            else
              site = %{
                base_site(tmpl.kind, anno, ctx)
                | patterns: plain,
                  via: {:wrapper, mfa, tmpl.line}
              }

              add_site(site, {sites, tmpls})
            end

          # this function passes its own parameter through: it is an
          # intermediate wrapper; report its (partial) template here too
          if parametric == [] do
            acc
          else
            site = %{
              base_site(tmpl.kind, anno, ctx)
              | patterns: Enum.map(parametric, &EventName.forget_params/1) |> Enum.uniq(),
                via: {:wrapper, mfa, tmpl.line},
                extra: %{wrapper_template: true}
            }

            add_site(site, acc)
          end
        end)

      _ ->
        _ = sites
        _ = tmpls
        acc
    end
  end

  # ---- handlers ------------------------------------------------------------

  defp attach(fun, [id, names, handler_fun, _config], anno, ctx, acc) do
    patterns =
      case fun do
        :attach ->
          Eval.name(names, ctx.env)

        :attach_many ->
          case list_elements(names) do
            {:ok, elems} -> Enum.flat_map(elems, &Eval.name(&1, ctx.env))
            :error -> [[{:splice, :unknown}]]
          end
      end

    site = %{
      base_site(fun, anno, ctx)
      | patterns: Enum.uniq(patterns),
        handler: %{id: literal_or_unknown(id), function: handler_function(handler_fun, ctx)}
    }

    add_site(site, acc)
  end

  defp list_elements({nil, _}), do: {:ok, []}

  defp list_elements({:cons, _, h, t}) do
    with {:ok, rest} <- list_elements(t), do: {:ok, [h | rest]}
  end

  defp list_elements(_), do: :error

  defp handler_function(
         {:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}},
         _
       ),
       do: {m, f, a}

  defp handler_function({:fun, _, {:function, f, a}}, ctx) when is_atom(f),
    do: {ctx.module, f, a}

  defp handler_function({:fun, _, {:clauses, _}}, ctx), do: {:anonymous, ctx.mfa}
  defp handler_function({:named_fun, _, _, _}, ctx), do: {:anonymous, ctx.mfa}
  defp handler_function(_, _ctx), do: :unknown

  defp literal_or_unknown(expr) do
    case Eval.literal(expr) do
      {:ok, term} -> term
      :error -> :unknown
    end
  end

  # ---- Telemetry.Metrics definitions --------------------------------------

  defp metric(fun, [name_expr | rest], anno, ctx, acc) do
    # Options are read key by key: a single non-literal option (for example
    # `measurement: &__MODULE__.count/1`) must not discard the others
    # (real-app validation, hexpm: 21 false metric_measurement_missing).
    opts = keyword_entries(rest)

    with {:ok, full} when length(full) >= 2 <- metric_name(name_expr),
         {:ok, event} <- metric_event(opts, full, ctx) do
      site = %{
        base_site(:metric, anno, ctx)
        | patterns: [event],
          extra: %{
            metric_type: fun,
            metric_name: Enum.map_join(full, ".", &Atom.to_string/1),
            measurement: metric_measurement(opts, full),
            unit: literal_opt(opts, :unit, nil),
            tags: literal_opt(opts, :tags, [])
          }
      }

      add_site(site, acc)
    else
      _ -> acc
    end
  end

  defp keyword_entries([opts_expr]), do: keyword_entries(opts_expr, [])
  defp keyword_entries(_), do: []

  defp keyword_entries({:cons, _, {:tuple, _, [{:atom, _, key}, value]}, tail}, acc),
    do: keyword_entries(tail, [{key, value} | acc])

  defp keyword_entries(_other, acc), do: Enum.reverse(acc)

  # `event_name:` overrides the name-derived event. When it is present but
  # cannot be resolved, the event is unknown: never fall back to the name.
  defp metric_event(opts, full, ctx) do
    case List.keyfind(opts, :event_name, 0) do
      nil ->
        {:ok, Enum.drop(full, -1)}

      {:event_name, expr} ->
        case Eval.name(expr, ctx.env) do
          [event] -> if EventName.literal?(event), do: {:ok, event}, else: :error
          _ -> :error
        end
    end
  end

  # `measurement:` may be an atom or a function; a function is :custom and is
  # never checked against observed keys.
  defp metric_measurement(opts, full) do
    case List.keyfind(opts, :measurement, 0) do
      nil -> List.last(full)
      {:measurement, {:atom, _, m}} -> m
      {:measurement, _} -> :custom
    end
  end

  defp literal_opt(opts, key, default) do
    with {^key, expr} <- List.keyfind(opts, key, 0),
         {:ok, value} <- Eval.literal(expr) do
      value
    else
      _ -> default
    end
  end

  defp metric_name(expr) do
    case Eval.literal(expr) do
      {:ok, bin} when is_binary(bin) ->
        {:ok, bin |> String.split(".", trim: true) |> Enum.map(&String.to_atom/1)}

      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_atom/1), do: {:ok, list}, else: :error

      _ ->
        :error
    end
  end

  # ---- rules ---------------------------------------------------------------

  defp maybe_rule(mfa, args, anno, ctx, acc) do
    case Map.fetch(ctx.watched, mfa) do
      {:ok, rule} ->
        rule_ctx = %{
          module: ctx.module,
          app: ctx.app,
          eval_name: &Eval.name(&1, ctx.env),
          literal: &Eval.literal/1
        }

        results =
          try do
            rule.on_call(mfa, args, rule_ctx)
          rescue
            _ -> []
          end

        Enum.reduce(results, acc, fn {kind, patterns, extra}, acc ->
          site = %{
            base_site(kind, anno, ctx)
            | patterns: Enum.reject(patterns, &EventName.parametric?/1),
              via: {:rule, rule},
              extra: Map.put(extra, :rule_call, mfa)
          }

          if site.patterns == [], do: acc, else: add_site(site, acc)
        end)

      :error ->
        acc
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp base_site(kind, anno, ctx) do
    {_m, f, a} = ctx.mfa

    %CallSite{
      kind: kind,
      app: ctx.app,
      module: ctx.module,
      function: {f, a},
      file: ctx.file,
      line: line(anno)
    }
  end

  defp add_site(site, {sites, tmpls}), do: {[site | sites], tmpls}

  defp line(anno) do
    :erl_anno.line(anno)
  rescue
    _ -> nil
  end

  defp finalize(sites) do
    sites
    |> Enum.uniq_by(&CallSite.key/1)
    |> Enum.sort_by(&{&1.module, &1.line || 0})
  end
end
