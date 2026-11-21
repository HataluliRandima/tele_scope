defmodule TeleScope.MixProject do
  use Mix.Project

  @version "0.1.0-spike"

  def project do
    [
      app: :tele_scope,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Telemetry discovery, observation and diagnostics for Elixir/Erlang applications (spike)",
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  # TeleScope has no application callback: nothing starts unless the
  # developer explicitly asks for it.
  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"}
    ]
  end
end
