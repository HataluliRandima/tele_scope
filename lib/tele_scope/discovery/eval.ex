defmodule TeleScope.Discovery.Eval do
  @moduledoc """
  A small, bounded symbolic evaluator over Erlang abstract forms.

  It answers one question: *what event name(s) can this expression produce?*

  Supported:
    * literal lists / cons cells of atoms (including Elixir module attributes,
      which are inlined at compile time)
    * `++` / `:lists.append/2`
    * variables bound by `Var = Expr` anywhere in the same function clause
      (Elixir's variable versioning makes these effectively single-assignment)
    * `case` / `if` / blocks -> union of alternatives
    * function parameters -> `{:param, i}` origins (for wrapper resolution)
    * local function calls whose clauses return names (bounded depth)

  Everything else becomes an unknown part. The evaluator never executes code.
  Alternatives are capped at `@max_alternatives`; beyond that the result
  collapses to a single unknown pattern so analysis stays linear.
  """

  alias TeleScope.EventName

  @max_alternatives 16
  @max_depth 4

  defstruct params: %{}, bindings: %{}, functions: %{}, depth: 0, seen: MapSet.new()

  @type t :: %__MODULE__{}

  @doc """
  Builds an environment for a function clause.

  `functions` is a map `{name, arity} => [clause]` of the enclosing module,
  used to evaluate local calls.
  """
  def env_for_clause({:clause, _anno, params, _guards, body}, functions) do
    param_map =
      params
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {p, i}, acc -> bind_param(p, i, acc) end)

    %__MODULE__{params: param_map, bindings: collect_bindings(body, %{}), functions: functions}
  end

  defp bind_param({:var, _, :_}, _i, acc), do: acc
  defp bind_param({:var, _, name}, i, acc), do: Map.put(acc, name, i)
  # `pattern = var` / `var = pattern` in a function head binds the var to the whole param
  defp bind_param({:match, _, left, right}, i, acc),
    do: bind_param(right, i, bind_param(left, i, acc))

  defp bind_param(_other, _i, acc), do: acc

  defp collect_bindings({:match, _, {:var, _, name}, expr}, acc) when name != :_ do
    acc = Map.update(acc, name, [expr], &[expr | &1])
    collect_bindings(expr, acc)
  end

  defp collect_bindings(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect_bindings(acc)

  defp collect_bindings(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_bindings/2)

  defp collect_bindings(_, acc), do: acc

  @doc "Evaluates `expr` as an event name. Returns a list of alternative patterns."
  @spec name(tuple(), t()) :: [EventName.pattern()]
  def name(expr, env) do
    expr
    |> list(env)
    |> cap()
    |> Enum.map(&normalize/1)
    |> Enum.uniq()
  end

  # a pattern that contains an invalid segment is invalid as a whole
  defp normalize(parts) when is_list(parts) do
    if Enum.any?(parts, &(&1 == :invalid_segment)), do: :invalid, else: parts
  end

  defp normalize(:invalid), do: :invalid

  defp cap(alts) when length(alts) > @max_alternatives, do: [[{:splice, :unknown}]]
  defp cap(alts), do: alts

  # ---- list evaluation -----------------------------------------------------

  @doc false
  def list({nil, _}, _env), do: [[]]

  def list({:cons, _, head, tail}, env) do
    for h <- seg(head, env), t <- list(tail, env), do: prepend(h, t)
  end

  def list({:op, _, :++, a, b}, env), do: append(list(a, env), list(b, env))

  def list({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, [a, b]}, env)
      when {m, f} in [{:erlang, :++}, {:lists, :append}],
      do: append(list(a, env), list(b, env))

  def list({:var, _, name}, env), do: var(name, env, :list)
  def list({:match, _, _left, right}, env), do: list(right, env)

  def list({:block, _, exprs}, env), do: list(List.last(exprs), env)

  def list({:case, _, _subject, clauses}, env), do: union_clauses(clauses, env, :list)
  def list({:if, _, clauses}, env), do: union_clauses(clauses, env, :list)

  def list({:call, _, {:atom, _, fun}, args}, env), do: local_call(fun, args, env, :list)

  # Literals that are provably not lists of atoms
  def list({kind, _, _}, _env) when kind in [:atom, :integer, :float, :char, :bin],
    do: [:invalid]

  def list({:string, _, []}, _env), do: [[]]
  def list({:string, _, _}, _env), do: [:invalid]
  def list({kind, _, _}, _env) when kind in [:map, :tuple], do: [:invalid]
  def list({:map, _, _, _}, _env), do: [:invalid]

  def list(_other, _env), do: [[{:splice, :unknown}]]

  # ---- single segment evaluation -----------------------------------------

  @doc false
  def seg({:atom, _, a}, _env), do: [a]
  def seg({:var, _, name}, env), do: var(name, env, :seg)
  def seg({:match, _, _left, right}, env), do: seg(right, env)
  def seg({:block, _, exprs}, env), do: seg(List.last(exprs), env)
  def seg({:case, _, _subject, clauses}, env), do: union_clauses(clauses, env, :seg)
  def seg({:if, _, clauses}, env), do: union_clauses(clauses, env, :seg)
  def seg({:call, _, {:atom, _, fun}, args}, env), do: local_call(fun, args, env, :seg)

  def seg({kind, _, _}, _env) when kind in [:integer, :float, :char, :bin, :string],
    do: [:invalid_segment]

  def seg(_other, _env), do: [{:var, :unknown}]

  # ---- helpers -------------------------------------------------------------

  defp prepend(_h, :invalid), do: :invalid
  defp prepend(h, t), do: [h | t]

  defp append(as, bs) do
    for a <- as, b <- bs do
      if a == :invalid or b == :invalid, do: :invalid, else: a ++ b
    end
    |> cap()
  end

  defp var(name, env, mode) do
    cond do
      Map.has_key?(env.params, name) ->
        i = Map.fetch!(env.params, name)
        if mode == :list, do: [[{:splice, {:param, i}}]], else: [{:var, {:param, i}}]

      env.depth < @max_depth and Map.has_key?(env.bindings, name) and
          not MapSet.member?(env.seen, name) ->
        env = %{env | depth: env.depth + 1, seen: MapSet.put(env.seen, name)}

        env.bindings
        |> Map.fetch!(name)
        |> Enum.flat_map(fn expr ->
          if mode == :list, do: list(expr, env), else: seg(expr, env)
        end)
        |> Enum.uniq()
        |> cap_mode(mode)

      true ->
        unknown(mode)
    end
  end

  defp unknown(:list), do: [[{:splice, :unknown}]]
  defp unknown(:seg), do: [{:var, :unknown}]

  defp cap_mode(alts, mode) when length(alts) > @max_alternatives, do: unknown(mode)
  defp cap_mode(alts, _mode), do: alts

  defp union_clauses(clauses, env, mode) do
    clauses
    |> Enum.flat_map(fn
      {:clause, _, _head, _guards, body} ->
        last = List.last(body)
        if mode == :list, do: list(last, env), else: seg(last, env)

      _ ->
        unknown(mode)
    end)
    |> Enum.uniq()
    |> cap_mode(mode)
  end

  # Evaluate a local call by evaluating the callee's return expressions with
  # the callee's own environment, then substituting parameters with the
  # caller's argument values.
  defp local_call(fun, args, env, mode) do
    key = {fun, length(args)}

    with true <- env.depth < @max_depth,
         false <- MapSet.member?(env.seen, key),
         {:ok, clauses} <- Map.fetch(env.functions, key) do
      callee_alts =
        Enum.flat_map(clauses, fn clause ->
          {:clause, _, _, _, body} = clause
          cenv = env_for_clause(clause, env.functions)
          cenv = %{cenv | depth: env.depth + 1, seen: MapSet.put(env.seen, key)}
          if mode == :list, do: list(List.last(body), cenv), else: seg(List.last(body), cenv)
        end)

      caller_env = %{env | depth: env.depth + 1}

      callee_alts
      |> Enum.flat_map(fn
        :invalid -> [:invalid]
        :invalid_segment -> [:invalid_segment]
        parts when is_list(parts) -> substitute(parts, args, caller_env)
        part -> substitute_seg(part, args, caller_env)
      end)
      |> Enum.uniq()
      |> cap_mode(mode)
    else
      _ -> unknown(mode)
    end
  end

  @doc """
  Substitutes `{:param, i}` origins in `pattern` with the evaluation of the
  i-th argument expression in `env`. Returns alternatives.
  """
  def substitute(:invalid, _args, _env), do: [:invalid]

  def substitute(parts, args, env) do
    parts
    |> Enum.reduce([[]], fn part, acc ->
      options =
        case part do
          {:var, {:param, i}} -> arg_eval(args, i, env, :seg) |> Enum.map(&[&1])
          {:splice, {:param, i}} -> arg_eval(args, i, env, :list)
          other -> [[other]]
        end

      for prefix <- acc, opt <- options do
        if prefix == :invalid or opt == :invalid, do: :invalid, else: prefix ++ opt
      end
      |> cap()
    end)
    |> Enum.map(&normalize/1)
  end

  defp substitute_seg({:var, {:param, i}}, args, env), do: arg_eval(args, i, env, :seg)
  defp substitute_seg(other, _args, _env), do: [other]

  defp arg_eval(args, i, env, mode) do
    case Enum.at(args, i) do
      nil -> unknown(mode)
      expr when mode == :list -> list(expr, env)
      expr -> seg(expr, env)
    end
  end

  @doc "Converts an abstract literal expression to a term, if it is one."
  def literal(expr) do
    {:ok, :erl_parse.normalise(expr)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
