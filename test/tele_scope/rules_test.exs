defmodule TeleScope.RulesTest do
  use ExUnit.Case, async: false
  import TeleScope.Test.Fixtures
  alias TeleScope.Catalog

  test "Ecto rule: default prefix from repo module (behaviour) and configured prefix" do
    dir = tmp_dir("ecto")

    compile_elixir(
      """
      defmodule Ecto.Repo do
        @callback config() :: keyword()
      end
      defmodule RuleApp.Repo do
        @behaviour Ecto.Repo
        def config, do: []
      end
      defmodule RuleApp.ReadRepo do
        @behaviour Ecto.Repo
        def config, do: []
      end
      """,
      dir
    )

    env = %{
      rule_app: [
        ecto_repos: [RuleApp.Repo, RuleApp.ReadRepo],
        "Elixir.RuleApp.ReadRepo": [telemetry_prefix: [:rule_app, :replica]]
      ]
    }

    cat = catalog([{:rule_app, dir}], get_env: &Map.get(env, &1, []))
    assert %{sources: sources} = Catalog.get(cat, [:rule_app, :repo, :query])
    assert MapSet.member?(sources, :config_rule)
    assert Catalog.get(cat, [:rule_app, :replica, :query])
    refute Catalog.get(cat, [:rule_app, :read_repo, :query])
  end

  test "Plug.Telemetry rule: runtime and compile init modes" do
    dir = tmp_dir("plug")

    compile_elixir(
      """
      defmodule RuleApp.Endpoint do
        def runtime(conn), do: Plug.Telemetry.call(conn, Plug.Telemetry.init(event_prefix: [:rule_app, :endpoint]))
        def compile(conn), do: Plug.Telemetry.call(conn, {[:rule_app, :api, :start], [:rule_app, :api, :stop], []})
      end
      """,
      dir
    )

    cat = catalog([{:rule_app, dir}])

    for name <- [
          [:rule_app, :endpoint, :start],
          [:rule_app, :endpoint, :stop],
          [:rule_app, :api, :start],
          [:rule_app, :api, :stop]
        ] do
      e = Catalog.get(cat, name)
      assert e, "missing #{inspect(name)}"
      assert MapSet.member?(e.sources, :static_resolved)
    end
  end

  test "telemetry_registry-style declarations (persisted telemetry_event attributes)" do
    dir = tmp_dir("registry")

    compile_elixir(
      """
      defmodule RuleApp.Declared do
        Module.register_attribute(__MODULE__, :telemetry_event, accumulate: true, persist: true)
        @telemetry_event %{event: [:rule_app, :declared, :stop], description: "d", measurements: "m", metadata: "md"}
        @telemetry_event %{event: "not a list", description: "invalid declaration is ignored"}
        def noop, do: :ok
      end
      """,
      dir
    )

    cat = catalog([{:rule_app, dir}])
    e = Catalog.get(cat, [:rule_app, :declared, :stop])
    assert MapSet.member?(e.sources, :declared)
    assert TeleScope.Event.confidence(e) == :declared
    assert e.declaration.description == "d"
    assert map_size(cat.events) == 1
  end

  defmodule BrokenRule do
    @behaviour TeleScope.Discovery.Rule
    def config_events(_), do: raise("rule bug")
    def watched_calls, do: [{Kernel, :inspect, 1}]
    def on_call(_, _, _), do: raise("rule bug")
  end

  test "a failing third-party rule never breaks discovery" do
    dir = tmp_dir("broken")

    compile_elixir(
      "defmodule RuleApp.X do\n def a, do: inspect(:telemetry.execute([:x, :y], %{}, %{}))\nend",
      dir
    )

    cat = catalog([{:x, dir}], rules: [BrokenRule])
    assert Catalog.get(cat, [:x, :y])
    assert [%{rule: BrokenRule, error: "rule bug"}] = cat.config_errors
  end
end
