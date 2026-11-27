defmodule TeleScope.Discovery.Scanner do
  @moduledoc """
  Static discovery over a set of `ebin` directories.

  Pipeline:

    1. **Index** every `.beam`: read only the `imports` and `attributes`
       chunks (cheap, present even without debug info).
    2. **Prefilter**: only modules that import a telemetry API, a
       `Telemetry.Metrics` constructor or a rule-watched MFA are decoded.
    3. **Analyze** those modules in parallel (abstract forms via debug info).
    4. **Wrapper fixpoint**: modules that import a discovered wrapper MFA are
       (re)analyzed with the global template table, until no new templates
       appear (bounded rounds).
    5. Collect `telemetry_event` declarations (telemetry_registry convention).

  The scan never loads the scanned modules into the VM and never executes
  their code.
  """

  alias TeleScope.Discovery.{Analyzer, Beam}

  @max_global_rounds 4

  defmodule Result do
    @moduledoc "Raw result of a static scan."
    defstruct sites: [],
              declarations: [],
              templates: %{},
              stats: %{},
              no_debug_info: [],
              errors: [],
              implementations: %{},
              modules: %{}
  end

  @doc """
  Scans the given `{app, ebin_dir}` pairs.

  Options:
    * `:rules` - rule modules (default `TeleScope.Discovery.Rule.default_rules/0`)
    * `:max_concurrency` - default `System.schedulers_online()`
  """
  def scan(app_dirs, opts \\ []) do
    rules = Keyword.get_lazy(opts, :rules, &TeleScope.Discovery.Rule.default_rules/0)
    concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    t0 = System.monotonic_time()

    # a configured directory that does not exist is reported, not ignored:
    # an empty scan must never look like "this app emits nothing"
    missing_dirs =
      for {app, dir} <- app_dirs,
          not File.dir?(dir),
          do: %{app: app, path: dir, reason: :missing_directory}

    beams =
      for {app, dir} <- app_dirs,
          path <- Path.wildcard(Path.join(dir, "*.beam")),
          do: {app, path}

    # 1. index
    {index, index_errors} =
      beams
      |> parallel(concurrency, fn {app, path} -> index_beam(app, path) end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    index = Enum.map(index, fn {:ok, entry} -> entry end)
    t_index = System.monotonic_time()

    rule_mfas =
      rules
      |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :watched_calls, 0)))
      |> Enum.flat_map(& &1.watched_calls())

    base_interest = MapSet.new(Analyzer.interesting_imports() ++ rule_mfas)

    # 2+3. first round
    candidates = Enum.filter(index, &(interesting?(&1, base_interest) or &1.module == :telemetry))
    forms_cache = decode(candidates, concurrency)

    {analyses, templates, rounds} =
      fixpoint(index, forms_cache, base_interest, rules, concurrency, %{}, %{}, 1)

    t_analyze = System.monotonic_time()

    {decode_ok, decode_err} =
      forms_cache.status |> Map.values() |> Enum.split_with(&(&1 == :ok))

    sites = analyses |> Map.values() |> Enum.flat_map(& &1.sites)

    declarations =
      for entry <- index, decl <- entry.declarations do
        Map.merge(decl, %{module: entry.module, app: entry.app})
      end

    no_debug =
      for {mod, {:error, :no_debug_info}} <- forms_cache.status,
          do: mod

    analysis_errors =
      for {mod, %{error: err}} <- analyses, do: %{module: mod, reason: {:analysis_failed, err}}

    errors =
      missing_dirs ++
        Enum.map(index_errors, fn {:error, info} -> info end) ++
        analysis_errors ++
        for {mod, {:error, reason}} <- forms_cache.status,
            reason != :no_debug_info,
            do: %{module: mod, reason: reason}

    implementations =
      for entry <- index, b <- entry.behaviours, reduce: %{} do
        acc -> Map.update(acc, b, [entry.module], &[entry.module | &1])
      end

    %Result{
      sites: sites,
      implementations: implementations,
      modules: Map.new(index, &{&1.module, &1.app}),
      declarations: declarations,
      templates: templates,
      no_debug_info: Enum.sort(no_debug),
      errors: errors,
      stats: %{
        beams: length(beams),
        indexed: length(index),
        candidates: length(candidates),
        decoded: length(decode_ok),
        decode_failed: length(decode_err),
        analyzed_modules: map_size(analyses),
        wrapper_rounds: rounds,
        wrapper_mfas: map_size(templates),
        index_ms: ms(t_index - t0),
        analyze_ms: ms(t_analyze - t_index),
        total_ms: ms(System.monotonic_time() - t0)
      }
    }
  end

  @doc "Default `{app, ebin_dir}` pairs for the current Mix project (`_build/ENV/lib/*/ebin`)."
  def mix_app_dirs(build_path \\ nil) do
    build_path = build_path || Mix.Project.build_path()

    build_path
    |> Path.join("lib/*/ebin")
    |> Path.wildcard()
    |> Enum.map(fn ebin ->
      {ebin |> Path.dirname() |> Path.basename() |> String.to_atom(), ebin}
    end)
    |> Enum.sort()
  end

  # ---- internals -------------------------------------------------------------

  defp index_beam(app, path) do
    case :beam_lib.chunks(to_charlist(path), [:imports, :attributes]) do
      {:ok, {module, [imports: imports, attributes: attrs]}} ->
        {:ok,
         %{
           app: app,
           module: module,
           path: path,
           imports: imports,
           declarations: declarations(attrs),
           behaviours: behaviours(attrs)
         }}

      _ ->
        # fall back to Beam for consistent error classification
        case Beam.imports(path) do
          {:ok, module, imports} ->
            {:ok,
             %{
               app: app,
               module: module,
               path: path,
               imports: imports,
               declarations: [],
               behaviours: []
             }}

          {:error, reason} ->
            {:error, %{path: path, app: app, reason: reason}}
        end
    end
  rescue
    _ -> {:error, %{path: path, app: app, reason: :invalid_beam}}
  end

  defp behaviours(attrs) do
    (Keyword.get_values(attrs, :behaviour) ++ Keyword.get_values(attrs, :behavior))
    |> List.flatten()
  end

  # telemetry_registry convention: -telemetry_event(#{event => [...], ...})
  defp declarations(attrs) do
    attrs
    |> Keyword.get_values(:telemetry_event)
    |> List.flatten()
    |> Enum.flat_map(fn
      %{event: event} = d when is_list(event) -> [d]
      _ -> []
    end)
  end

  defp interesting?(entry, interest) do
    Enum.any?(entry.imports, &MapSet.member?(interest, &1))
  end

  defp decode(entries, concurrency, cache \\ %{forms: %{}, status: %{}, entries: %{}}) do
    todo = Enum.reject(entries, &Map.has_key?(cache.status, &1.module))

    todo
    |> parallel(concurrency, fn entry -> {entry, Beam.forms(entry.path)} end)
    |> Enum.reduce(cache, fn
      {entry, {:ok, _mod, forms}}, c ->
        %{
          c
          | forms: Map.put(c.forms, entry.module, forms),
            status: Map.put(c.status, entry.module, :ok),
            entries: Map.put(c.entries, entry.module, entry)
        }

      {entry, {:error, reason}}, c ->
        %{
          c
          | status: Map.put(c.status, entry.module, {:error, reason}),
            entries: Map.put(c.entries, entry.module, entry)
        }
    end)
  end

  defp fixpoint(index, cache, interest, rules, concurrency, analyses, templates, round) do
    # modules to analyze this round: interesting ones + importers of wrappers
    wrapper_mfas = templates |> Map.keys() |> MapSet.new()
    interest = MapSet.union(interest, wrapper_mfas)

    targets =
      Enum.filter(index, fn e ->
        interesting?(e, interest) or e.module == :telemetry or
          Map.has_key?(templates_by_module(templates), e.module)
      end)

    cache = decode(targets, concurrency, cache)

    new_analyses =
      targets
      |> Enum.filter(&(Map.get(cache.status, &1.module) == :ok))
      # Pair each entry with its own forms *before* spawning: capturing the
      # whole cache in the closure would copy every module's forms into every
      # task (measured: 6.4s -> see BENCHMARKS.md).
      |> Enum.map(&{&1, Map.fetch!(cache.forms, &1.module)})
      |> parallel(concurrency, fn {entry, forms} ->
        # A bug or an unexpected form in one module must never abort the scan.
        try do
          {entry.module,
           Analyzer.analyze(entry.module, forms,
             app: entry.app,
             external_templates: templates,
             rules: rules
           )}
        rescue
          e ->
            {entry.module,
             %{sites: [], templates: %{}, error: Exception.format(:error, e, __STACKTRACE__)}}
        end
      end)
      |> Map.new()

    analyses = Map.merge(analyses, new_analyses)

    new_templates =
      analyses
      |> Map.values()
      |> Enum.reduce(%{}, fn a, acc -> Map.merge(acc, a.templates) end)

    if new_templates == templates or round >= @max_global_rounds do
      {analyses, new_templates, round}
    else
      fixpoint(index, cache, interest, rules, concurrency, analyses, new_templates, round + 1)
    end
  end

  defp templates_by_module(templates) do
    templates |> Map.keys() |> Map.new(fn {m, _, _} -> {m, true} end)
  end

  # ordered: results (and therefore reports and diagnostics) must not depend
  # on which task finishes first
  defp parallel(items, concurrency, fun) do
    items
    |> Task.async_stream(fun, max_concurrency: concurrency, ordered: true, timeout: :infinity)
    |> Enum.map(fn {:ok, r} -> r end)
  end

  defp ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
