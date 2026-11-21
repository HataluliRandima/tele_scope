defmodule TeleScope.Runtime.CaptureTest do
  use ExUnit.Case, async: false
  @moduletag :tracing
  alias TeleScope.Runtime.Capture

  test "a tracer crash mid-capture does not lose observer results" do
    {:ok, pid} = Capture.start(duration: 5_000, events: [[:cap, :known]])
    %{tracer: tracer} = :sys.get_state(pid)
    Process.exit(tracer, :kill)
    :telemetry.execute([:cap, :known], %{n: 1}, %{})
    result = Capture.stop(pid)

    assert result.trace == nil
    assert result.trace_error != nil
    assert result.observations.events[[:cap, :known]].count == 1

    cat = TeleScope.Catalog.add_capture(TeleScope.Catalog.new(), result)
    assert Enum.any?(TeleScope.diagnose(cat), &(&1.check == :capture_limited))
  end

  test "capture without tracing (observer only)" do
    {:ok, pid} = Capture.start(duration: 5_000, events: [[:cap, :obs]], trace: false)
    :telemetry.execute([:cap, :obs], %{}, %{})
    :telemetry.execute([:cap, :unknown], %{}, %{})
    result = Capture.stop(pid)
    assert result.trace == nil and result.trace_error == nil
    assert Map.keys(result.observations.events) == [[:cap, :obs]]
  end

  test "await returns when the time box expires" do
    {:ok, pid} = Capture.start(duration: 100, events: [])
    assert %{duration_ms: 100} = Capture.await(pid, 2_000)
    GenServer.stop(pid)
  end
end
