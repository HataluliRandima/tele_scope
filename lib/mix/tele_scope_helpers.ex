defmodule TeleScope.Mix.Helpers do
  @moduledoc false

  # Shared by the mix tasks: option parsing, compile, load config, static
  # scan, optional capture, output.
  #
  # Exit codes (documented in both tasks):
  #   0 - success (telemetry.check: no failing diagnostics)
  #   1 - telemetry.check found failing diagnostics
  #   2 - invalid usage, or TeleScope could not run (e.g. capture refused)

  @usage_exit 2

  @doc "Parses argv strictly; any problem is a usage error (exit 2)."
  def parse!(task, argv, switches) do
    case OptionParser.parse(argv, strict: switches) do
      {opts, [], []} ->
        validate_common!(task, opts)
        opts

      {_opts, [arg | _], _} ->
        usage_error!(task, "unexpected argument #{inspect(arg)}")

      {_opts, _, [{switch, nil} | _]} ->
        usage_error!(task, "unknown option #{switch}")

      {_opts, _, [{switch, value} | _]} ->
        usage_error!(task, "invalid value #{inspect(value)} for #{switch}")
    end
  end

  defp validate_common!(task, opts) do
    if Keyword.has_key?(opts, :duration) and opts[:duration] <= 0,
      do: usage_error!(task, "--duration must be a positive number of milliseconds")

    if Keyword.has_key?(opts, :format) and opts[:format] not in ["console", "json"],
      do: usage_error!(task, "unknown --format #{opts[:format]} (expected console or json)")

    for flag <- [:duration, :serve, :trace], Keyword.has_key?(opts, flag), !opts[:runtime] do
      note(opts, "#{task}: --#{flag} has no effect without --runtime")
    end

    :ok
  end

  @doc "Prints a usage error to stderr and exits with status 2."
  def usage_error!(task, message) do
    Mix.shell().error("#{task}: #{message}\nRun `mix help #{task}` for usage.")
    exit({:shutdown, @usage_exit})
  end

  # JSON on stdout must stay parseable: progress output goes to stderr and
  # compilation runs with a quiet shell.
  defp json_to_stdout?(opts), do: opts[:format] == "json" and opts[:output] == nil

  @doc "Status message: stdout normally, stderr when stdout carries JSON."
  def note(opts, message) do
    if json_to_stdout?(opts), do: IO.puts(:stderr, message), else: Mix.shell().info(message)
  end

  @doc """
  Compiles, loads the configuration, runs the static scan and, with
  `--runtime`, a capture. Returns the catalog.
  """
  def build(task, opts) do
    with_quiet_shell(json_to_stdout?(opts), fn ->
      Mix.Task.run("compile")
      # loads config/*.exs and runtime.exs without starting applications,
      # so configuration rules (e.g. Ecto repos) can read the app env
      Mix.Task.run("app.config")
    end)

    catalog = TeleScope.scan()

    if opts[:runtime], do: capture(task, catalog, opts), else: catalog
  end

  defp capture(task, catalog, opts) do
    duration = opts[:duration] || 5_000
    trace? = opts[:trace] != false
    {:ok, _} = Application.ensure_all_started(:telemetry)

    note(
      opts,
      "TeleScope: capturing runtime telemetry for #{duration} ms (tracing #{if trace?, do: "on", else: "off"})..."
    )

    pid =
      case TeleScope.start_capture(catalog, duration: duration, trace: trace?) do
        {:ok, pid} ->
          pid

        {:error, reason} ->
          Mix.shell().error("#{task}: " <> TeleScope.CaptureError.message(%{reason: reason}))
          exit({:shutdown, @usage_exit})
      end

    # same switch `mix phx.server` flips; without it Phoenix endpoints do
    # not listen and no request events can be observed
    if opts[:serve], do: Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)

    with_quiet_shell(json_to_stdout?(opts), fn -> Mix.Task.run("app.start") end)
    result = TeleScope.Runtime.Capture.await(pid)
    GenServer.stop(pid)
    TeleScope.Catalog.add_capture(catalog, result)
  end

  defp with_quiet_shell(false, fun), do: fun.()

  defp with_quiet_shell(true, fun) do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)

    try do
      fun.()
    after
      Mix.shell(previous)
    end
  end

  @doc "Writes `output` to `--output` or stdout."
  def emit(output, opts) do
    case opts[:output] do
      nil ->
        IO.puts(output)

      path ->
        case File.write(path, output) do
          :ok ->
            note(opts, "TeleScope report written to #{path}")

          {:error, reason} ->
            Mix.shell().error("cannot write #{path}: #{:file.format_error(reason)}")
            exit({:shutdown, @usage_exit})
        end
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
