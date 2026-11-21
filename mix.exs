defmodule TeleScope.MixProject do
  use Mix.Project

  @version "0.1.0-rc.1"
  @source_url "https://github.com/HataluliRandima/tele_scope"

  def project do
    [
      app: :tele_scope,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Discover, observe and diagnose :telemetry events in Elixir and Erlang applications: " <>
          "static BEAM analysis, time-boxed runtime capture, CI checks and metric suggestions.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
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
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      # explicit allowlist: spike/, experiments/, bench/ and their results are
      # repository evidence, not part of the package
      files:
        ~w(lib mix.exs README.md LICENSE CHANGELOG.md LIMITATIONS.md ARCHITECTURE.md BENCHMARKS.md SPIKE_RESULTS.md ROADMAP.md VALIDATION.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "ARCHITECTURE.md",
        "LIMITATIONS.md",
        "BENCHMARKS.md",
        "SPIKE_RESULTS.md",
        "ROADMAP.md",
        "VALIDATION.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        API: [TeleScope, TeleScope.Catalog, TeleScope.Event, TeleScope.EventName],
        "Diagnostics & metrics": [TeleScope.Diagnostics, TeleScope.Metrics],
        Reporters: [TeleScope.Reporters.Console, TeleScope.Reporters.JSON],
        "Discovery rules": [
          TeleScope.Discovery.Rule,
          TeleScope.Discovery.Rules.Ecto,
          TeleScope.Discovery.Rules.PlugTelemetry
        ],
        "Runtime (advanced)": [
          TeleScope.Runtime.Capture,
          TeleScope.Runtime.Tracer,
          TeleScope.Runtime.Observer,
          TeleScope.Runtime.Handlers,
          TeleScope.Runtime.Shape
        ],
        "Internals (unstable)": [
          TeleScope.Discovery.Scanner,
          TeleScope.Discovery.Analyzer,
          TeleScope.Discovery.Eval,
          TeleScope.Discovery.Beam,
          TeleScope.Discovery.CallSite
        ]
      ]
    ]
  end
end
