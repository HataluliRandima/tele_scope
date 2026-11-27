defmodule TeleScope.RealAppValidationRegressionsTest do
  @moduledoc """
  Regressions found by validating TeleScope on real open-source applications
  (VALIDATION.md): hexpm, changelog.com, plausible/analytics.
  """
  use ExUnit.Case, async: false

  import TeleScope.Test.Fixtures
  alias TeleScope.{Catalog, Diagnostics}

  @compile {:no_warn_undefined, [Val.Metrics]}

  describe "Telemetry.Metrics options (hexpm: 21 false metric_measurement_missing)" do
    setup do
      dir = tmp_dir("val_metrics")

      compile_elixir(
        """
        defmodule Val.Metrics do
          def count(_), do: 1
          def metrics do
            [
              Telemetry.Metrics.distribution("val.purge.duration.milliseconds",
                event_name: [:val, :purge, :stop],
                measurement: :duration
              ),
              Telemetry.Metrics.sum("val.user_created.total",
                event_name: [:val, :user_created],
                measurement: &__MODULE__.count/1,
                description: "uses a function measurement"
              ),
              Telemetry.Metrics.summary("val.other.x", event_name: some_runtime_name())
            ]
          end
          defp some_runtime_name, do: Application.get_env(:val, :name)
          def emit do
            :telemetry.execute([:val, :purge, :stop], %{duration: 1}, %{})
            :telemetry.execute([:val, :user_created], %{count: 1}, %{})
          end
        end
        """,
        dir
      )

      %{dir: dir}
    end

    test "measurement: and event_name: are read per key", %{dir: dir} do
      metrics =
        for s <- scan([{:val, dir}]).sites,
            s.kind == :metric,
            do: {s.extra.metric_name, s.patterns, s.extra.measurement}

      assert {"val.purge.duration.milliseconds", [[:val, :purge, :stop]], :duration} in metrics
      # a function in one option no longer discards event_name:
      assert {"val.user_created.total", [[:val, :user_created]], :custom} in metrics
      # unresolvable event_name: -> no guess from the metric name
      refute Enum.any?(metrics, fn {name, _, _} -> name == "val.other.x" end)
    end

    test "no false metric_measurement_missing at runtime", %{dir: dir} do
      cat = catalog([{:val, dir}])
      {:ok, cap} = TeleScope.start_capture(cat, duration: 5_000, trace: false)
      Val.Metrics.emit()
      cat = TeleScope.stop_capture(cat, cap)
      refute Enum.any?(Diagnostics.run(cat), &(&1.check == :metric_measurement_missing))
    end
  end

  test "optional measurements declared by a rule are info, not warnings (hexpm: Ecto idle_time)" do
    event = %{
      TeleScope.Event.new([:app, :repo, :query])
      | sources: MapSet.new([:config_rule]),
        observed: true,
        measurements: %{query_time: %{types: %{integer: 1}, presence: 1.0, seen: 1}},
        optional_measurements: [:idle_time],
        metrics: [
          %{
            metric_type: :summary,
            metric_name: "app.repo.query.idle_time",
            measurement: :idle_time,
            location: "x",
            module: X,
            app: :app
          },
          %{
            metric_type: :summary,
            metric_name: "app.repo.query.bogus",
            measurement: :bogus,
            location: "x",
            module: X,
            app: :app
          }
        ]
    }

    diags = Diagnostics.run(%Catalog{events: %{event.name => event}})

    by_metric =
      Map.new(
        for d <- diags, d.check == :metric_measurement_missing, do: {d.detail.metric, d.severity}
      )

    assert by_metric == %{"app.repo.query.idle_time" => :info, "app.repo.query.bogus" => :warning}
  end

  test "literal defaults of configurable getters are possible names (hexpm: ExAws)" do
    dir = tmp_dir("val_default")

    compile_elixir(
      """
      defmodule Val.Client do
        def request(config) do
          event = Map.get(config, :telemetry_event, [:val_client, :request])
          :telemetry.span(event, %{}, fn -> {:ok, %{}} end)
        end
        def kw(opts), do: :telemetry.execute(Keyword.get(opts, :event, [:val_client, :kw]), %{}, %{})
      end
      """,
      dir
    )

    cat = catalog([{:val, dir}])

    for name <- [[:val_client, :request, :stop], [:val_client, :kw]],
        do: assert(Catalog.get(cat, name))
  end

  describe "consumer_without_emitter severity (plausible, hexpm, changelog.com)" do
    setup do
      app_dir = tmp_dir("val_app")
      dep_dir = tmp_dir("val_dep")

      compile_elixir(
        """
        defmodule Val.App do
          # project code attaches to an event its dependency never emits
          def attach, do: :telemetry.attach("val-errors", [:val_dep, :notifier, :exception], &__MODULE__.h/4, nil)
          def h(_, _, _, _), do: :ok
        end
        """,
        app_dir
      )

      compile_elixir(
        """
        defmodule Val.Dep do
          # generic span helper: prefix unknown -> [**, :start | :stop | :exception]
          def span(prefix, fun), do: :telemetry.span(prefix, %{}, fun)
          def notify(fun), do: :telemetry.span([:val_dep, :notifier, :notify], %{}, fun)
          # optional integration with a library that is not installed
          def setup, do: :telemetry.attach("val-dep-quantum", [:val_quantum, :job, :start], &__MODULE__.h/4, nil)
          def h(_, _, _, _), do: :ok
        end
        defmodule Val.Dep.Caller do
          def go(p), do: Val.Dep.span(p, fn -> {:ok, %{}} end)
        end
        """,
        dep_dir
      )

      cat = catalog([{:val_app, app_dir}, {:val_dep, dep_dir}], project_apps: [:val_app])
      %{diags: Diagnostics.run(cat), cat: cat}
    end

    test "a project handler for a never-emitted event is a warning despite generic patterns", %{
      diags: diags
    } do
      d = Enum.find(diags, &(&1.event == [:val_dep, :notifier, :exception]))
      assert d.severity == :warning
      assert d.detail.project_consumer
      # span-naming slip: suggest the span event that does exist
      assert [:val_dep, :notifier, :notify, :exception] in d.detail.similar
      assert d.suggestion =~ "Did you mean [:val_dep, :notifier, :notify, :exception]"
    end

    test "a dependency's optional integration is info", %{diags: diags} do
      d = Enum.find(diags, &(&1.event == [:val_quantum, :job, :start]))
      assert d.severity == :info
      assert d.message =~ "dependency"
    end

    test "patterns without a known first segment are not specific", %{cat: cat} do
      refute Enum.any?(Catalog.specific_patterns(cat), &match?([{:splice, _} | _], &1.pattern))
    end
  end
end
