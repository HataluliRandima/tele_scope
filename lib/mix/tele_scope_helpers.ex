defmodule TeleScope.Mix.Helpers do
  @moduledoc false

  # Shared by the mix tasks: compile, load config, static scan, optional capture.
  def build(opts) do
    Mix.Task.run("compile")
    # loads config/*.exs and runtime.exs without starting applications,
    # so configuration rules (e.g. Ecto repos) can read the app env
    Mix.Task.run("app.config")

    catalog = TeleScope.scan()

    if opts[:runtime] do
      duration = opts[:duration] || 5_000
      {:ok, _} = Application.ensure_all_started(:telemetry)

      Mix.shell().info(
        "TeleScope: capturing runtime telemetry for #{duration}ms (tracing #{if opts[:trace] == false, do: "off", else: "on"})..."
      )

      {:ok, pid} =
        TeleScope.start_capture(catalog, duration: duration, trace: opts[:trace] != false)

      Mix.Task.run("app.start")
      result = TeleScope.Runtime.Capture.await(pid)
      GenServer.stop(pid)
      {TeleScope.Catalog.add_capture(catalog, result), result}
    else
      {catalog, nil}
    end
  end
end
