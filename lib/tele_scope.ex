defmodule TeleScope do
  @moduledoc """
  Telemetry discovery, observation and diagnostics.

  TeleScope answers four questions about an Elixir/Erlang system:

    1. Which telemetry events can the application and its dependencies emit?
       -> `scan/1` (static analysis of compiled BEAM files + library rules)
    2. Which events actually fire, with which measurement/metadata shapes?
       -> `capture/2` (time-boxed runtime observation, opt-in)
    3. Which events have handlers, and which handlers ever run?
       -> `capture/2` (handler snapshot + call counting)
    4. Which `Telemetry.Metrics` definitions would be useful?
       -> `recommend_metrics/1`

  Nothing runs at application start. Runtime capture is always explicit,
  bounded and cleaned up.

      catalog = TeleScope.scan()
      catalog = TeleScope.capture(catalog, duration: 10_000)
      TeleScope.diagnose(catalog)
      TeleScope.recommend_metrics(catalog) |> TeleScope.Metrics.to_code() |> IO.puts()
  """

  alias TeleScope.{Catalog, Diagnostics, Metrics}
  alias TeleScope.Discovery.{Rule, Scanner}
  alias TeleScope.Runtime.Capture

  @doc """
  Static discovery.

  Options:
    * `:app_dirs` - `[{app, ebin_dir}]` (default: the current Mix build path,
      or every loaded application's ebin outside of Mix)
    * `:rules` - rule modules (default `TeleScope.Discovery.Rule.default_rules/0`)
    * `:exclude_apps` - applications not to scan (default `[:tele_scope]`)
    * `:project_apps` - the project's own applications (default: the Mix
      project's app, or umbrella children). Consumers (handlers, metrics)
      in other apps are treated as dependencies' optional integrations
    * `:get_env` - `fn app -> keyword end` used by configuration rules
      (default `Application.get_all_env/1`)
  """
  @spec scan(keyword()) :: Catalog.t()
  def scan(opts \\ []) do
    rules = Keyword.get_lazy(opts, :rules, &Rule.default_rules/0)
    # TeleScope does not report on itself unless asked to
    exclude = Keyword.get(opts, :exclude_apps, [:tele_scope])

    app_dirs =
      opts
      |> Keyword.get_lazy(:app_dirs, &default_app_dirs/0)
      |> Enum.reject(fn {app, _} -> app in exclude end)

    get_env = Keyword.get(opts, :get_env, &Application.get_all_env/1)

    result = Scanner.scan(app_dirs, Keyword.put(opts, :rules, rules))

    config_ctx = %{
      apps: Enum.map(app_dirs, &elem(&1, 0)),
      get_env: get_env,
      implementations: fn behaviour -> Map.get(result.implementations, behaviour, []) end
    }

    project_apps =
      Keyword.get_lazy(opts, :project_apps, fn -> default_project_apps(app_dirs) end)

    Catalog.new()
    |> Catalog.add_static(result)
    |> Catalog.add_config_events(Rule.run_config(rules, config_ctx))
    |> Catalog.put_project_apps(project_apps)
  end

  # The Mix project's own application(s), umbrella children included; nil
  # (= treat every app as the project's) outside Mix.
  defp default_project_apps(app_dirs) do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      apps =
        if Mix.Project.umbrella?(),
          do: Mix.Project.apps_paths() |> Map.keys(),
          else: [Mix.Project.config()[:app]]

      scanned = MapSet.new(app_dirs, &elem(&1, 0))
      if Enum.any?(apps, &MapSet.member?(scanned, &1)), do: apps, else: nil
    end
  end

  @doc """
  Runs a blocking, time-boxed runtime capture and merges it into `catalog`.

  Every *literal* event in the catalog gets an observer handler; the tracer
  (if `trace: true`, the default) discovers names that are not in the
  catalog. See `TeleScope.Runtime.Capture` for options (`:duration`,
  `:trace`, `:track_handlers`, `:observer`, `:tracer`).
  """
  @spec capture(Catalog.t() | nil, keyword()) :: Catalog.t()
  def capture(catalog \\ nil, opts \\ []) do
    catalog = catalog || Catalog.new()
    {:ok, pid} = start_capture(catalog, opts)
    result = Capture.await(pid)
    GenServer.stop(pid)
    Catalog.add_capture(catalog, result)
  end

  @doc "Starts a non-blocking capture; finish it with `stop_capture/2`."
  def start_capture(catalog, opts \\ []) do
    events =
      for e <- Catalog.events(catalog || Catalog.new()),
          TeleScope.Event.emitter_known?(e),
          do: e.name

    Capture.start(Keyword.put_new(opts, :events, events))
  end

  @doc "Stops a capture started with `start_capture/2` and merges results."
  def stop_capture(catalog, pid),
    do: Catalog.add_capture(catalog || Catalog.new(), Capture.stop(pid))

  @doc "Runs diagnostics."
  defdelegate diagnose(catalog), to: Diagnostics, as: :run

  @doc "Telemetry.Metrics suggestions (see `TeleScope.Metrics`)."
  defdelegate recommend_metrics(catalog, opts \\ []), to: Metrics, as: :recommend

  @doc "Renders a report: `format: :console | :json`."
  def report(catalog, opts \\ []) do
    case Keyword.get(opts, :format, :console) do
      :json -> TeleScope.Reporters.JSON.render(catalog, opts)
      :console -> TeleScope.Reporters.Console.render(catalog, opts)
    end
  end

  defp default_app_dirs do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      Scanner.mix_app_dirs()
    else
      for {app, _, _} <- Application.loaded_applications(),
          dir = :code.lib_dir(app),
          is_list(dir),
          do: {app, Path.join(to_string(dir), "ebin")}
    end
  end
end
