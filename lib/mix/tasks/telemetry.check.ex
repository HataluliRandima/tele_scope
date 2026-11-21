defmodule Mix.Tasks.Telemetry.Check do
  @shortdoc "Runs telemetry diagnostics (CI-friendly)"
  @moduledoc """
  Runs TeleScope diagnostics and exits non-zero when problems are found.

      mix telemetry.check                 # fail on :error diagnostics
      mix telemetry.check --strict        # fail on :warning too
      mix telemetry.check --runtime --duration 5000

  Static-only checks (no app start) catch: metrics/handlers referencing event
  names nothing emits (typos), modules without debug info, incomplete spans
  and unresolved dynamic call sites.
  """
  use Mix.Task

  @switches [
    runtime: :boolean,
    duration: :integer,
    strict: :boolean,
    trace: :boolean,
    verbose: :boolean,
    serve: :boolean
  ]

  @impl true
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)
    {catalog, _} = TeleScope.Mix.Helpers.build(opts)
    diags = TeleScope.diagnose(catalog)

    for d <- diags, opts[:verbose] || d.severity != :info do
      Mix.shell().info("[#{d.severity}] #{d.check}: #{d.message}")
    end

    counts = Enum.frequencies_by(diags, & &1.severity)

    Mix.shell().info(
      "\n#{counts[:error] || 0} error(s), #{counts[:warning] || 0} warning(s), #{counts[:info] || 0} info"
    )

    failing = if opts[:strict], do: [:error, :warning], else: [:error]

    if Enum.any?(diags, &(&1.severity in failing)) do
      Mix.raise("telemetry.check failed")
    end
  end
end
