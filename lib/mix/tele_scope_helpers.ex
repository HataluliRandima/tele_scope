defmodule TeleScope.Mix.Helpers do
  @moduledoc false

  # Shared by the mix tasks: compile, load config, static scan, optional capture.
  def build(opts) do
    if opts[:duration] && opts[:duration] <= 0,
      do: Mix.raise("--duration must be a positive number of milliseconds")

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

      # same switch `mix phx.server` flips; without it Phoenix endpoints do
      # not listen and no request events can be observed
      if opts[:serve], do: Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)

      Mix.Task.run("app.start")
      result = TeleScope.Runtime.Capture.await(pid)
      GenServer.stop(pid)
      {TeleScope.Catalog.add_capture(catalog, result), result}
    else
      {catalog, nil}
    end
  end
end

defmodule TeleScope.Mix.Apps do
  @moduledoc false

  # `--app a --app b` -> [:a, :b]; nil when not given (report everything).
  def parse(opts) do
    case Keyword.get_values(opts, :app) do
      [] -> nil
      apps -> Enum.map(apps, &String.to_atom/1)
    end
  end
end
