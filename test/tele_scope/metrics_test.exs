defmodule TeleScope.MetricsTest do
  use ExUnit.Case, async: true
  alias TeleScope.{Catalog, Event, Metrics}

  defp event(name, attrs) do
    struct(Event.new(name), Keyword.merge([sources: MapSet.new([:static_literal])], attrs))
  end

  defp catalog(events, runtime? \\ true) do
    %Catalog{
      events: Map.new(events, &{&1.name, &1}),
      runtime: if(runtime?, do: %{}, else: nil)
    }
  end

  defp stat(types, presence \\ 1.0), do: %{types: types, presence: presence, seen: 1}

  test "timestamps are never treated as durations" do
    e =
      event([:x, :init],
        observed: true,
        measurements: %{system_time: stat(%{integer: 1})}
      )

    assert [%{metric: :counter, name: "x.init.count"}] = Metrics.recommend(catalog([e]))
  end

  test "ecto-style *_time measurements become summaries in native units" do
    e =
      event([:app, :repo, :query],
        observed: true,
        measurements: %{query_time: stat(%{integer: 3})}
      )

    assert [%{metric: :summary, unit: {:native, :millisecond}, confidence: :low}] =
             Metrics.recommend(catalog([e]))
  end

  test "gauges become last_value" do
    e = event([:vm, :memory], observed: true, measurements: %{total: stat(%{integer: 3})})
    assert [%{metric: :last_value, name: "vm.memory.total"}] = Metrics.recommend(catalog([e]))
  end

  test "with runtime data, unobserved events are skipped but span exceptions are kept" do
    stop = event([:s, :stop], observed: true, measurements: %{duration: stat(%{integer: 1})})
    exc = event([:s, :exception], observed: false)
    never = event([:never, :fired], observed: false)
    names = catalog([stop, exc, never]) |> Metrics.recommend() |> Enum.map(& &1.name)
    assert "s.stop.duration" in names
    assert "s.exception.count" in names
    refute "never.fired.count" in names
  end

  test "static-only catalogs include everything (lower confidence)" do
    stop = event([:s, :stop], [])
    assert [%{confidence: :low}] = Metrics.recommend(catalog([stop], false))
  end

  test "tags: only fully-present low-cardinality metadata" do
    e =
      event([:t, :e],
        observed: true,
        metadata: %{
          kind: stat(%{atom: 1}),
          user_id: stat(%{integer: 1}),
          path: stat(%{binary: 1}),
          sometimes: stat(%{atom: 1}, 0.5)
        }
      )

    [r] = Metrics.recommend(catalog([e]))
    assert r.tags == [:kind]
    assert {:user_id, [:integer]} in r.rejected_tags
    assert {:sometimes, [:atom]} in r.rejected_tags
  end
end
