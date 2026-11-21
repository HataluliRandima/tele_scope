defmodule Mix.Tasks.Telemetry.Explore do
  @shortdoc "Discovers telemetry events (static, optionally runtime)"
  @moduledoc """
  Discovers telemetry events emitted by the project and its dependencies.

      mix telemetry.explore                      # static discovery
      mix telemetry.explore --runtime            # + start the app and capture
      mix telemetry.explore --runtime --duration 15000
      mix telemetry.explore --metrics            # + Telemetry.Metrics suggestions
      mix telemetry.explore --format json --output telescope.json
      mix telemetry.explore --verbose            # call sites, shapes, handlers
      mix telemetry.explore --app my_app         # only events of these apps (repeatable)
      mix telemetry.explore --runtime --serve    # Phoenix: start endpoints (like phx.server)

  `--runtime` starts the application *after* the capture begins, so startup
  events (`[:phoenix, :endpoint, :init]`, `[:ecto, :repo, :init]`, ...) are
  observed. Exercise the application during the capture window to observe
  request-driven events; for Phoenix pass `--serve`, otherwise endpoints do
  not listen. Use `--no-trace` to skip call tracing (observer only; no
  dynamic name discovery). For long sessions prefer `iex -S mix phx.server`
  and `TeleScope.capture/2`.
  """
  use Mix.Task

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
    {opts, _} = OptionParser.parse!(argv, strict: @switches)
    {catalog, _} = TeleScope.Mix.Helpers.build(opts)

    apps = TeleScope.Mix.Apps.parse(opts)
    metrics = if opts[:metrics], do: TeleScope.recommend_metrics(catalog, apps: apps)

    output =
      case opts[:format] || "console" do
        "json" ->
          TeleScope.report(catalog, format: :json, metrics: metrics)

        "console" ->
          TeleScope.report(catalog,
            format: :console,
            metrics: metrics,
            verbose: opts[:verbose],
            apps: apps
          )

        other ->
          Mix.raise("unknown --format #{other} (expected console or json)")
      end

    case opts[:output] do
      nil ->
        IO.puts(output)

      path ->
        File.write!(path, output)
        Mix.shell().info("TeleScope report written to #{path}")
    end
  end
end
