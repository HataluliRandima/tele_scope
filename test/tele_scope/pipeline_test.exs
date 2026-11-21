defmodule TeleScope.PipelineTest do
  @moduledoc "End-to-end: static scan -> capture -> catalog -> diagnostics/metrics/reports."
  use ExUnit.Case, async: false
  @moduletag :tracing
  # fixture modules are compiled at test time; :json exists on OTP 27+ only
  @compile {:no_warn_undefined, [Pipe.App, Pipe.Handlers, :json]}

  import TeleScope.Test.Fixtures
  alias TeleScope.{Catalog, Event, Metrics}

  @source """
  defmodule Pipe.App do
    def literal(i), do: :telemetry.execute([:pipe, :order], %{amount: i}, %{kind: :web, id: i, note: nil})
    def unused, do: :telemetry.execute([:pipe, :never], %{}, %{})
    def dynamic(x), do: :telemetry.execute([:pipe, :dyn, x], %{}, %{})
    def span(fail?) do
      :telemetry.span([:pipe, :job], %{queue: :default}, fn ->
        if fail?, do: raise("x")
        {:ok, %{queue: :default}}
      end)
    end
    def secret, do: :telemetry.execute([:pipe, :login], %{}, %{password: "p"})
  end

  defmodule Pipe.Handlers do
    def attach do
      :telemetry.attach("pipe-order", [:pipe, :order], &__MODULE__.h/4, nil)
      :telemetry.attach("pipe-never", [:pipe, :never], &__MODULE__.h2/4, nil)
      :telemetry.attach("pipe-typo", [:pipe, :ordr], &__MODULE__.h3/4, nil)
    end
    def h(_, _, _, _), do: :ok
    def h2(_, _, _, _), do: :ok
    def h3(_, _, _, _), do: :ok
    def metrics do
      [
        Telemetry.Metrics.summary("pipe.job.stop.duration", unit: {:native, :millisecond}),
        Telemetry.Metrics.summary("pipe.order.total")
      ]
    end
  end
  """

  setup_all do
    dir = tmp_dir("pipe")
    compile_elixir(@source, dir)
    %{static: catalog([{:pipe, dir}])}
  end

  setup do
    on_exit(fn -> Enum.each(["pipe-order", "pipe-never", "pipe-typo"], &:telemetry.detach/1) end)
  end

  test "full pipeline", %{static: static} do
    {:ok, pid} = TeleScope.start_capture(static, duration: 5_000)
    Pipe.Handlers.attach()
    # handlers attached after start are picked up by the periodic refresh
    Process.sleep(400)
    for i <- 1..5, do: Pipe.App.literal(i)
    dyn = Enum.random([:one, :two])
    Pipe.App.dynamic(dyn)
    Pipe.App.span(false)

    try do
      Pipe.App.span(true)
    rescue
      _ -> :ok
    end

    Pipe.App.secret()
    Process.sleep(100)
    cat = TeleScope.stop_capture(static, pid)

    # statuses
    assert Event.status(Catalog.get(cat, [:pipe, :order])) == :observed
    assert Event.status(Catalog.get(cat, [:pipe, :never])) == :not_observed
    assert Event.status(Catalog.get(cat, [:pipe, :ordr])) == :referenced_only

    # dynamic name discovered by the tracer and linked to the partial pattern
    dyn_event = Catalog.get(cat, [:pipe, :dyn, dyn])
    assert dyn_event.observed
    assert MapSet.member?(dyn_event.sources, :runtime_trace)
    assert [:pipe, :dyn, dyn] in cat.patterns[[:pipe, :dyn, {:var, :unknown}]].matched

    # no duplicates: one event per name, evidence merged
    order = Catalog.get(cat, [:pipe, :order])

    assert MapSet.subset?(
             MapSet.new([:static_literal, :runtime_observed, :runtime_handler]),
             order.sources
           )

    assert order.count == 5
    assert order.metadata.note.types == %{nil => 5}
    assert [%{id: "pipe-order", invocations: 5}] = order.handlers

    # diagnostics
    diags = TeleScope.diagnose(cat)
    checks = Enum.map(diags, &{&1.check, &1.severity, &1.event})
    assert {:consumer_without_emitter, :warning, [:pipe, :ordr]} in checks
    assert {:sensitive_key, :warning, [:pipe, :login]} in checks
    assert {:inactive_handler, :info, [:pipe, :never]} in checks
    assert {:metric_measurement_missing, :warning, [:pipe, :order]} in checks
    typo = Enum.find(diags, &(&1.event == [:pipe, :ordr]))
    assert typo.message =~ "did you mean [:pipe, :order]"
    # an event without handlers is never an error
    refute Enum.any?(diags, &(&1.check == :no_runtime_handler and &1.severity != :info))

    # metrics
    recs = Metrics.recommend(cat)
    names = Enum.map(recs, &{&1.metric, &1.name})
    # already defined in Pipe.Handlers.metrics/0 -> not suggested again
    refute {:summary, "pipe.job.stop.duration"} in names
    assert {:counter, "pipe.job.exception.count"} in names
    refute Enum.any?(recs, &(&1.name =~ "pipe.job.start"))
    order_rec = Enum.find(recs, &(&1.event == [:pipe, :order]))
    assert order_rec.tags == [:kind]
    assert {:id, [:integer]} in order_rec.rejected_tags
    code = Metrics.to_code(recs)
    assert code =~ "SUGGESTIONS"
    assert code =~ "Review every entry"

    # reports
    json = TeleScope.report(cat, format: :json, metrics: recs)
    assert String.starts_with?(json, "{")

    if Code.ensure_loaded?(:json) and function_exported?(:json, :decode, 1) do
      decoded = :json.decode(json)
      assert is_list(decoded["events"])

      assert Enum.any?(
               decoded["events"],
               &(&1["id"] == "pipe.order" and &1["status"] == "observed")
             )
    end

    text = TeleScope.report(cat, verbose: true)
    assert text =~ "pipe.order"
    assert text =~ "consumer_without_emitter"
  end
end
