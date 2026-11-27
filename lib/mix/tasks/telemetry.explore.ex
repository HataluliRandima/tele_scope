defmodule Mix.Tasks.Telemetry.Explore do
  @shortdoc "Discovers telemetry events (static, optionally runtime)"
  @moduledoc """
  Discovers telemetry events emitted by the project and its dependencies.

      mix telemetry.explore                      # static discovery
      mix telemetry.explore --verbose            # call sites, shapes, handlers
      mix telemetry.explore --app my_app         # only events of these apps (repeatable)
      mix telemetry.explore --metrics            # + Telemetry.Metrics suggestions
      mix telemetry.explore --format json --output telescope.json
      mix telemetry.explore --runtime            # + start the app and capture
      mix telemetry.explore --runtime --duration 15000
      mix telemetry.explore --runtime --serve    # Phoenix: start endpoints (like phx.server)

  `--runtime` starts the application *after* the capture begins, so startup
  events (`[:phoenix, :endpoint, :init]`, `[:ecto, :repo, :init]`, ...) are
  observed. Exercise the application during the capture window to observe
  request-driven events; for Phoenix pass `--serve`, otherwise endpoints do
  not listen. Use `--no-trace` to skip call tracing (observer only; no
  dynamic name discovery). For long sessions prefer `iex -S mix phx.server`
  and `TeleScope.capture/2`.

  ## Options

    * `--format console|json` - output format (default `console`). JSON is
      written to stdout (compilation output is suppressed) unless `--output`
      is given. With `--runtime`, prefer `--output`: the application's own
      logs also go to stdout.
    * `--output PATH` - write the report to a file.
    * `--app APP` - only report events of these applications (repeatable);
      also narrows `--metrics`.
    * `--metrics` - include `Telemetry.Metrics` suggestions.
    * `--verbose` - call sites, rules, shapes, handlers and all diagnostics.
    * `--runtime`, `--duration MS`, `--serve`, `--no-trace` - see above.

  ## Exit status

    * `0` - report produced (diagnostics never fail this task; use
      `mix telemetry.check` in CI)
    * `2` - invalid usage, or the runtime capture could not start
  """
  use Mix.Task

  alias TeleScope.Mix.Helpers

  @switches [
    runtime: :boolean,
    duration: :integer,
    metrics: :boolean,
    format: :string,
    output: :string,
    verbose: :boolean,
    trace: :boolean,
    serve: :boolean,
    app: :keep
  ]

  @impl true
  def run(argv) do
    opts = Helpers.parse!("telemetry.explore", argv, @switches)
    catalog = Helpers.build("telemetry.explore", opts)

    apps = TeleScope.Mix.Apps.parse(opts)
    metrics = if opts[:metrics], do: TeleScope.recommend_metrics(catalog, apps: apps)

    output =
      case opts[:format] || "console" do
        "json" ->
          TeleScope.report(catalog, format: :json, metrics: metrics, apps: apps)

        "console" ->
          TeleScope.report(catalog,
            format: :console,
            metrics: metrics,
            verbose: opts[:verbose],
            apps: apps
          )
      end

    Helpers.emit(output, opts)
  end
end
