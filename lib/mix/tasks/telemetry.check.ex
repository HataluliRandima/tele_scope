defmodule Mix.Tasks.Telemetry.Check do
  @shortdoc "Runs telemetry diagnostics (CI-friendly)"
  @moduledoc """
  Runs TeleScope diagnostics and exits non-zero when problems are found.

      mix telemetry.check                       # fail on errors
      mix telemetry.check --strict              # fail on errors and warnings (CI)
      mix telemetry.check --format json         # machine-readable result on stdout
      mix telemetry.check --runtime --duration 5000

  Without `--runtime` the check is purely static: the application is
  compiled but not started. Static checks catch metrics and handlers that
  reference event names nothing emits (typos, `TS002`), modules without
  debug info (`TS006`), incomplete spans and unresolved dynamic call sites.
  With `--runtime` the application is started and observed for `--duration`
  milliseconds, which adds checks that need runtime evidence: crashed
  handlers (`TS001`), metrics reading missing measurements (`TS003`),
  sensitive metadata keys (`TS005`), and more.

  Every diagnostic has a stable code; see the DIAGNOSTICS guide.

  ## Options

    * `--strict` - warnings fail the check too. Limitations (things
      TeleScope could not see, such as unreadable modules) never fail it.
    * `--format console|json` - output format (default `console`). JSON is
      written to stdout (compilation output is suppressed) unless `--output`
      is given.
    * `--output PATH` - write the result to a file.
    * `--verbose` - also print informational diagnostics.
    * `--runtime` - start the application and capture runtime telemetry.
    * `--duration MS` - capture window with `--runtime` (default 5000).
    * `--serve` - with `--runtime`, start Phoenix endpoints (like `phx.server`).
    * `--no-trace` - with `--runtime`, observe known events only (no
      dynamic name discovery).

  ## Exit status

    * `0` - the check passed
    * `1` - failing diagnostics were found (errors; warnings too with `--strict`)
    * `2` - invalid usage, or the runtime capture could not start

  A compilation failure of the project exits non-zero as reported by
  `mix compile`.
  """
  use Mix.Task

  alias TeleScope.Diagnostics
  alias TeleScope.Mix.Helpers
  alias TeleScope.Reporters.{Console, JSON}

  @switches [
    runtime: :boolean,
    duration: :integer,
    strict: :boolean,
    trace: :boolean,
    verbose: :boolean,
    serve: :boolean,
    format: :string,
    output: :string
  ]

  @impl true
  def run(argv) do
    opts = Helpers.parse!("telemetry.check", argv, @switches)
    catalog = Helpers.build("telemetry.check", opts)
    diagnostics = Diagnostics.run(catalog)
    verdict = Diagnostics.evaluate(diagnostics, strict: opts[:strict] || false)

    output =
      case opts[:format] || "console" do
        "json" ->
          JSON.render_check(catalog, diagnostics, verdict)

        "console" ->
          Console.render_check(diagnostics, verdict, verbose: opts[:verbose], catalog: catalog)
      end

    Helpers.emit(output, opts)

    if verdict.status == :failed, do: exit({:shutdown, 1})
    :ok
  end
end
