defmodule TeleScope.Runtime.ObserverTest do
  use ExUnit.Case, async: false
  alias TeleScope.Runtime.Observer

  defmodule Crasher do
    def handle(_, _, _, _), do: raise("handler bug")
  end

  defp start(events, opts \\ []) do
    {:ok, pid} = Observer.start(Keyword.merge([events: events, duration: 30_000], opts))
    on_exit(fn -> if Process.alive?(pid), do: Observer.stop(pid) end)
    pid
  end

  defp attached?(pid) do
    ids = MapSet.new(:telemetry.list_handlers([]), & &1.id)
    pid |> Observer.handler_ids() |> Enum.any?(&MapSet.member?(ids, &1))
  end

  test "records counts, shapes, presence and types; never values" do
    pid = start([[:obs, :a]])

    for i <- 1..10 do
      md = if rem(i, 2) == 0, do: %{user: "secret-#{i}", opt: nil}, else: %{user: "secret-#{i}"}
      :telemetry.execute([:obs, :a], %{duration: i}, md)
    end

    snap = Observer.snapshot(pid)
    ev = snap.events[[:obs, :a]]
    assert ev.count == 10
    assert ev.measurements.duration.types == %{integer: 10}
    assert ev.metadata.user.presence == 1.0
    assert ev.metadata.opt.presence == 0.5
    assert ev.metadata.opt.types == %{nil => 5}
    assert ev.shape_count == 2
    assert is_integer(ev.first_seen_at) and ev.last_seen_at >= ev.first_seen_at

    # no raw value anywhere in the snapshot
    refute inspect(snap, limit: :infinity) =~ "secret-"
  end

  test "empty measurements and metadata" do
    pid = start([[:obs, :empty]])
    :telemetry.execute([:obs, :empty], %{}, %{})
    ev = Observer.snapshot(pid).events[[:obs, :empty]]
    assert ev.count == 1 and ev.measurements == %{} and ev.metadata == %{}
  end

  test "process attribution is recorded for the first occurrence of a shape" do
    pid = start([[:obs, :proc]])
    task = Task.async(fn -> :telemetry.execute([:obs, :proc], %{}, %{}) end)
    Task.await(task)
    [p] = Observer.snapshot(pid).events[[:obs, :proc]].processes
    assert Map.has_key?(p, :initial_call)
  end

  test "concurrent emission from many processes is counted exactly" do
    pid = start([[:obs, :conc]])

    1..50
    |> Enum.map(fn i ->
      Task.async(fn ->
        for j <- 1..2_000,
            do: :telemetry.execute([:obs, :conc], %{n: j}, %{w: rem(i, 3), flag: rem(j, 2) == 0})
      end)
    end)
    |> Enum.each(&Task.await(&1, 30_000))

    ev = Observer.snapshot(pid).events[[:obs, :conc]]
    assert ev.count == 100_000
    assert ev.shape_count == 1
  end

  test "very high volume: max_events is a soft cap enforced within one check interval" do
    pid = start([[:obs, :flood]], max_events: 1_000, check_interval: 10)
    for i <- 1..1_000, do: :telemetry.execute([:obs, :flood], %{i: i}, %{})
    Process.sleep(50)
    for i <- 1..4_000, do: :telemetry.execute([:obs, :flood], %{i: i}, %{})
    snap = Observer.snapshot(pid)
    assert snap.events[[:obs, :flood]].count == 1_000
    assert snap.dropped_events == 4_000
    assert snap.total_events == 5_000
  end

  test "max_rows bounds table growth under shape explosion" do
    pid = start([[:obs, :explode]], max_rows: 20, max_shapes_per_event: 1_000)
    for i <- 1..200, do: :telemetry.execute([:obs, :explode], %{:"k#{i}" => 1}, %{})
    snap = Observer.snapshot(pid)
    # max_rows + small per-event bookkeeping (registry+stripe pair, :shapes, :overflow)
    assert snap.ets_rows <= 20 + 3
    assert snap.events[[:obs, :explode]].count == 200
    assert snap.events[[:obs, :explode]].shape_overflow > 0
  end

  test "number of distinct shapes per event is bounded" do
    pid = start([[:obs, :shapes]], max_shapes_per_event: 3)
    for i <- 1..10, do: :telemetry.execute([:obs, :shapes], %{:"k#{i}" => 1}, %{})
    ev = Observer.snapshot(pid).events[[:obs, :shapes]]
    assert ev.shape_count == 3
    assert ev.shape_overflow == 7
    assert ev.count == 10
  end

  test "sampling records a fraction and estimates the count" do
    pid = start([[:obs, :sampled]], sample_rate: 0.1)
    for _ <- 1..20_000, do: :telemetry.execute([:obs, :sampled], %{}, %{})
    ev = Observer.snapshot(pid).events[[:obs, :sampled]]
    assert ev.count_estimated
    assert ev.count in 14_000..26_000
  end

  test "invalid options are rejected" do
    assert {:error, {%ArgumentError{}, _}} = Observer.start(events: [], sample_rate: 0)
    assert {:error, {%ArgumentError{}, _}} = Observer.start(events: [], duration: -1)
  end

  test "invalid event names are ignored when attaching" do
    pid = start([[:ok, :name], "bad", [], [:a | :b], [1, 2]])
    assert Observer.snapshot(pid).attached_events == [[:ok, :name]]
  end

  # [:telemetry, :handler, :failure] exists since telemetry 1.1.0
  _ = Application.load(:telemetry)
  @failure_event? Version.match?(to_string(Application.spec(:telemetry, :vsn)), ">= 1.1.0")

  @tag capture_log: true
  @tag skip:
         if(@failure_event?, do: false, else: "telemetry < 1.1 emits no handler failure event")
  test "records handlers that fail and get detached by telemetry" do
    pid = start([[:obs, :crash]])
    :ok = :telemetry.attach("obs-crasher", [:obs, :crash], &Crasher.handle/4, nil)
    :telemetry.execute([:obs, :crash], %{}, %{})
    [failure] = Observer.snapshot(pid).handler_failures
    assert failure.handler_id == "obs-crasher" and failure.event == [:obs, :crash]
    refute Enum.any?(:telemetry.list_handlers([:obs, :crash]), &(&1.id == "obs-crasher"))
    # the observer itself is never detached by its own failures
    assert attached?(pid)
  end

  test "time limit detaches handlers but keeps results" do
    pid = start([[:obs, :timed]], duration: 100)
    :telemetry.execute([:obs, :timed], %{}, %{})
    Process.sleep(200)
    :telemetry.execute([:obs, :timed], %{}, %{})
    snap = Observer.snapshot(pid)
    assert snap.status == :time_limit
    assert snap.events[[:obs, :timed]].count == 1
    refute attached?(pid)
  end

  test "dynamic attachment of newly discovered names" do
    pid = start([])
    :ok = Observer.attach(pid, [[:obs, :late]])
    :telemetry.execute([:obs, :late], %{}, %{})
    assert Observer.snapshot(pid).events[[:obs, :late]].count == 1
  end

  test "observer killed during capture: emitter never crashes, janitor detaches" do
    pid = start([[:obs, :killed]])
    ids = Observer.handler_ids(pid)
    Process.exit(pid, :kill)

    # until the janitor runs the handler may still be attached; it must no-op
    for _ <- 1..100, do: assert(:ok == :telemetry.execute([:obs, :killed], %{}, %{}))

    wait_until(fn ->
      current = MapSet.new(:telemetry.list_handlers([]), & &1.id)
      not Enum.any?(ids, &MapSet.member?(current, &1))
    end)
  end

  test "owner death stops the observer and detaches" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid} = Observer.start(events: [[:obs, :owner]], duration: 30_000)
        send(parent, {:observer, pid, Observer.handler_ids(pid)})
        receive do: (:never -> :ok)
      end)

    assert_receive {:observer, pid, ids}
    ref = Process.monitor(pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    current = MapSet.new(:telemetry.list_handlers([]), & &1.id)
    refute Enum.any?(ids, &MapSet.member?(current, &1))
  end

  test "no persistent_term config leaks after stop or kill" do
    count = fn -> Enum.count(:persistent_term.get(), &match?({{Observer, _}, _}, &1)) end
    before = count.()
    pid = start([[:obs, :pt]])
    assert count.() == before + 1
    Observer.stop(pid)
    assert count.() == before

    pid2 = start([[:obs, :pt]])
    Process.exit(pid2, :kill)
    wait_until(fn -> count.() == before end)
  end

  test "stop is idempotent-safe" do
    pid = start([[:obs, :stop]])
    assert %{status: :stopped} = Observer.stop(pid)
    assert {:error, :not_running} = Observer.stop(pid)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
