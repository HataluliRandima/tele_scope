defmodule TeleScope.CaptureLifecycleTest do
  @moduledoc """
  Public capture API contracts: errors, double stop, ownership, tracer
  refusal, concurrent captures and duplicate handler registration.
  """
  use ExUnit.Case, async: false
  @moduletag :tracing

  alias TeleScope.{Catalog, CaptureError, Event}
  alias TeleScope.Runtime.{Observer, Tracer}

  defp own_handlers do
    for h <- :telemetry.list_handlers([]),
        match?({{Observer, _}, _}, h.id),
        do: h
  end

  defp catalog_of(names) do
    Enum.reduce(names, Catalog.new(), fn n, cat ->
      Catalog.add_trace(cat, %{names: [%{name: n, count: 1}]})
    end)
  end

  test "capture/2 raises an actionable CaptureError on invalid options" do
    error = assert_raise CaptureError, fn -> TeleScope.capture(nil, duration: 0) end
    assert error.reason == {:invalid_option, {:duration, 0}}
    assert Exception.message(error) =~ "invalid :duration 0; expected a positive integer"
  end

  test "invalid observer options are reported, not crashed on" do
    assert {:error, {:observer_failed, _} = reason} =
             TeleScope.start_capture(nil, duration: 1_000, observer: [sample_rate: 2])

    assert CaptureError.message(%CaptureError{reason: reason}) =~ ":sample_rate must be in (0, 1]"
  end

  test "stopping a capture twice raises CaptureError :not_running" do
    {:ok, pid} = TeleScope.start_capture(nil, duration: 5_000, trace: false)
    assert %Catalog{} = TeleScope.stop_capture(nil, pid)

    error = assert_raise CaptureError, fn -> TeleScope.stop_capture(nil, pid) end
    assert error.reason == :not_running
  end

  test "a capture stops and cleans up when the process that started it exits" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid} = TeleScope.start_capture(catalog_of([[:lifecycle, :owned]]), duration: 30_000)
        send(parent, {:capture, pid})
        receive do: (:never -> :ok)
      end)

    assert_receive {:capture, pid}, 5_000
    ref = Process.monitor(pid)
    assert own_handlers() != []

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    # the observer's own terminate/janitor detach asynchronously
    wait_until(fn -> own_handlers() == [] end)
  end

  test "when the VM refuses the tracer, the capture continues with the observer only" do
    # legacy tracing is VM-global: a second legacy tracer is refused on every OTP
    {:ok, blocker} = Tracer.start(duration: 10_000, backend: :legacy)

    try do
      catalog = catalog_of([[:lifecycle, :degraded]])
      {:ok, pid} = TeleScope.start_capture(catalog, duration: 5_000, tracer: [backend: :legacy])
      :telemetry.execute([:lifecycle, :degraded], %{n: 1}, %{})
      cat = TeleScope.stop_capture(catalog, pid)

      assert cat.runtime.trace == nil
      assert cat.runtime.trace_error == {:already_tracing, blocker}
      assert Event.status(Catalog.get(cat, [:lifecycle, :degraded])) == :observed

      assert [%{code: "TS011", limitation: true, message: msg}] =
               cat |> TeleScope.diagnose() |> Enum.filter(&(&1.code == "TS011"))

      assert msg =~ "another TeleScope tracer"
    after
      Tracer.stop(blocker)
    end
  end

  test "invalid tracer options still fail the start, leaving nothing attached" do
    assert {:error, {:invalid_option, {:backend, :nope}}} =
             TeleScope.start_capture(catalog_of([[:lifecycle, :bad_opt]]),
               duration: 1_000,
               tracer: [backend: :nope]
             )

    wait_until(fn -> own_handlers() == [] end)
  end

  test "attaching the same names twice registers no duplicate handlers" do
    names = [[:lifecycle, :dup, :a], [:lifecycle, :dup, :b]]
    {:ok, obs} = Observer.start(events: names, duration: 5_000)

    try do
      ids = Observer.handler_ids(obs)
      assert :ok = Observer.attach(obs, names ++ names)
      assert Observer.handler_ids(obs) == ids

      for n <- names do
        assert length(for(h <- :telemetry.list_handlers(n), h.event_name == n, do: h)) == 1
      end

      :telemetry.execute([:lifecycle, :dup, :a], %{}, %{})
      assert Observer.snapshot(obs).events[[:lifecycle, :dup, :a]].count == 1
    after
      Observer.stop(obs)
    end
  end

  test "concurrent captures are independent and count concurrent emitters exactly" do
    name = [:lifecycle, :concurrent]
    catalog = catalog_of([name])
    {:ok, a} = TeleScope.start_capture(catalog, duration: 10_000, trace: false)
    {:ok, b} = TeleScope.start_capture(catalog, duration: 10_000, trace: false)

    1..8
    |> Task.async_stream(fn i -> for _ <- 1..500, do: :telemetry.execute(name, %{v: i}, %{}) end,
      max_concurrency: 8
    )
    |> Stream.run()

    cat_a = TeleScope.stop_capture(catalog, a)
    # stopping one capture must not detach the other's handlers
    :telemetry.execute(name, %{v: 0}, %{})
    cat_b = TeleScope.stop_capture(catalog, b)

    assert Catalog.get(cat_a, name).count == 4_000
    assert Catalog.get(cat_b, name).count == 4_001
    assert own_handlers() == []
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
