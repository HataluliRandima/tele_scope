defmodule TeleScope.Runtime.Observer do
  @moduledoc """
  Records the *shape* of telemetry events by attaching a handler to known
  event names.

  ## Hot path (runs inside the emitting process)

    1. read a stop flag (`:atomics.get/2`, read-only: no cache-line bouncing)
    2. increment a `:counters` total created with `:write_concurrency`
       (per-scheduler counters)
    3. optional sampling
    4. compute measurement + metadata shapes (`Shape.of_unsorted/2`)
    5. **one** `:ets.update_counter/3` on a row striped by *scheduler id*:
       `{event, shape_hash, scheduler_id}`; it atomically increments the count
       and sets `last_seen`

  Striping matters: with a single row per shape, 12 processes emitting the
  same event serialized on one ETS lock and the measured cost exploded to
  ~100 us/event (see BENCHMARKS.md, "rejected design"). With striping each
  scheduler updates its own row; rows are summed at snapshot time.

  A missing stripe row takes the slow path: register the shape once
  (`insert_new`, bounded per event by `:max_shapes_per_event` and globally by
  `:max_rows`) and create the stripe. The whole callback is wrapped in
  `try/catch`, so it can never raise into the emitting process and telemetry
  never detaches it. No value is ever stored - only key names and type tags.

  `:max_events` is a *soft* cap: the observer process polls the total every
  `:check_interval` ms and raises the stop flag, so the overshoot is bounded
  by one interval of traffic. This keeps the hot path free of a contended
  global counter.

  ## Lifecycle and safety

    * Started explicitly; nothing is attached until `start/1` is called.
    * Time-boxed (`:duration`, default 60s). On expiry handlers are detached
      and the results remain readable until `stop/1`.
    * Monitors its owner (the caller of `start/1`): if the owner dies, the
      observer stops.
    * A *janitor* process monitors the observer and detaches its handlers if
      the observer is killed (`:kill` skips `terminate/2`). Until then the
      handler silently no-ops because the ETS table is gone.
    * Also attaches to `[:telemetry, :handler, :failure]` to record which
      handlers were detached for failing (handler id + event, no reason or
      stacktrace values).
  """
  use GenServer

  alias TeleScope.Runtime.Shape

  @defaults [
    duration: 60_000,
    max_events: 1_000_000,
    max_shapes_per_event: 32,
    max_keys: 64,
    sample_rate: 1.0,
    max_attached_events: 5_000,
    max_rows: 100_000,
    check_interval: 50
  ]

  @failure_event [:telemetry, :handler, :failure]

  # :counters slots
  @total 1
  @dropped 2
  @errors 3

  ## Public API ---------------------------------------------------------------

  @doc """
  Starts an observer for `events` (list of event names).

  Options: `:duration` (ms or `:infinity`), `:max_events`,
  `:max_shapes_per_event`, `:max_keys`, `:sample_rate` (0.0 < r <= 1.0),
  `:max_attached_events`.
  """
  def start(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start(__MODULE__, opts)
  end

  @doc "Attaches the observer to additional event names (e.g. discovered by the tracer)."
  def attach(server, events), do: GenServer.call(server, {:attach, events})

  @doc "Returns the current aggregated observations without stopping."
  def snapshot(server), do: GenServer.call(server, :snapshot, 30_000)

  @doc "Detaches handlers and returns the final snapshot. Idempotent while alive."
  def stop(server) do
    snap = GenServer.call(server, :finish, 30_000)
    GenServer.stop(server)
    snap
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Handler ids currently attached by `server`."
  def handler_ids(server), do: GenServer.call(server, :handler_ids)

  ## Telemetry callbacks (hot path) ------------------------------------------

  # The handler config passed to :telemetry is only a small key; the real
  # config (ETS tid, :counters/:atomics refs) lives in :persistent_term.
  # :telemetry copies each handler record (config included) out of ETS on
  # every execute; copying magic references costs refcount updates that are
  # contended across schedulers (experiments/handler_config_experiment.exs:
  # +184 ns vs +56 ns per event with 12 emitters).
  @doc false
  def handle_event(event, measurements, metadata, key) do
    case :persistent_term.get(key, nil) do
      nil -> :ok
      cfg -> do_handle_event(event, measurements, metadata, cfg)
    end
  end

  defp do_handle_event(event, measurements, metadata, %{tab: tab, counters: c, stop: stop} = cfg) do
    try do
      if :atomics.get(stop, 1) == 1 do
        :counters.add(c, @dropped, 1)
      else
        :counters.add(c, @total, 1)

        if cfg.sample_rate >= 1.0 or :rand.uniform() <= cfg.sample_rate do
          record(tab, event, measurements, metadata, cfg)
        end
      end
    catch
      _, _ ->
        try do
          :counters.add(c, @errors, 1)
        catch
          _, _ -> :ok
        end
    end

    :ok
  end

  @doc false
  def handle_failure(_event, _measurements, metadata, key) do
    try do
      %{tab: tab} = :persistent_term.get(key)
      key = {:failure, Map.get(metadata, :handler_id), Map.get(metadata, :event_name)}
      :ets.update_counter(tab, key, {2, 1}, {key, 0, Map.get(metadata, :kind)})
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp record(tab, event, measurements, metadata, cfg) do
    ms = Shape.of_unsorted(measurements, cfg.max_keys)
    md = Shape.of_unsorted(metadata, cfg.max_keys)
    hash = :erlang.phash2({ms, md})
    stripe = {:c, event, hash, :erlang.system_info(:scheduler_id)}
    now = :erlang.system_time(:millisecond)

    try do
      # count += 1; last_seen := now   (pos 3: +0, threshold 0 -> set to now)
      :ets.update_counter(tab, stripe, [{2, 1}, {3, 0, 0, now}])
    catch
      :error, :badarg -> new_stripe(tab, stripe, event, hash, ms, md, now, cfg)
    end
  end

  # Slow path: at most once per (shape, scheduler).
  defp new_stripe(tab, stripe, event, hash, ms, md, now, cfg) do
    shape_key = {:shape, event, hash}

    cond do
      :ets.member(tab, shape_key) ->
        :ok

      :ets.info(tab, :size) >= cfg.max_rows ->
        # table full: count without creating rows
        throw(:overflow)

      true ->
        n = :ets.update_counter(tab, {:shapes, event}, {2, 1}, {{:shapes, event}, 0})

        cond do
          n > cfg.max_shapes_per_event ->
            :ok

          :ets.insert_new(tab, {shape_key, ms, md, attribution(), now}) ->
            :ok

          true ->
            # lost a race with another scheduler registering the same shape:
            # don't let the race consume the per-event shape budget
            :ets.update_counter(tab, {:shapes, event}, {2, -1})
        end
    end

    # stripes of overflowed shapes have no registry row; snapshot counts them
    # as overflow. Creating the stripe keeps later events on the fast path.
    :ets.update_counter(tab, stripe, [{2, 1}, {3, 0, 0, now}], {stripe, 0, now})
  catch
    :overflow ->
      :ets.update_counter(tab, {:overflow, event}, {2, 1}, {{:overflow, event}, 0})
  end

  # Only computed for the first occurrence of each shape (slow path).
  defp attribution do
    name =
      case Process.info(self(), :registered_name) do
        {:registered_name, n} when is_atom(n) -> n
        _ -> nil
      end

    %{registered_name: name, initial_call: Process.get(:"$initial_call")}
  end

  ## GenServer -----------------------------------------------------------------

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)
    validate!(opts)
    Process.flag(:trap_exit, true)

    tab = :ets.new(__MODULE__, [:set, :public, {:write_concurrency, true}])
    counters = :counters.new(3, [:write_concurrency])
    stop = :atomics.new(1, signed: false)
    owner_ref = Process.monitor(Keyword.fetch!(opts, :owner))

    cfg = %{
      tab: tab,
      counters: counters,
      stop: stop,
      max_shapes_per_event: opts[:max_shapes_per_event],
      max_rows: opts[:max_rows],
      max_keys: opts[:max_keys],
      sample_rate: opts[:sample_rate] * 1.0
    }

    id_base = {__MODULE__, make_ref()}
    pt_key = {__MODULE__, :erlang.unique_integer([:positive])}
    :persistent_term.put(pt_key, cfg)
    janitor = spawn_janitor(self(), pt_key)

    state = %{
      cfg: cfg,
      pt_key: pt_key,
      opts: opts,
      id_base: id_base,
      handler_ids: [],
      attached: MapSet.new(),
      janitor: janitor,
      owner_ref: owner_ref,
      status: :running,
      started_at: System.system_time(:millisecond),
      finished_at: nil,
      timer: nil
    }

    state = attach_failure(state)
    {:ok, state} = do_attach(state, Keyword.get(opts, :events, []))

    timer =
      case opts[:duration] do
        :infinity -> nil
        ms -> Process.send_after(self(), :time_limit, ms)
      end

    Process.send_after(self(), :check_limits, opts[:check_interval])
    {:ok, %{state | timer: timer}}
  end

  defp validate!(opts) do
    rate = opts[:sample_rate]

    unless is_number(rate) and rate > 0 and rate <= 1,
      do: raise(ArgumentError, ":sample_rate must be in (0, 1], got: #{inspect(rate)}")

    case opts[:duration] do
      :infinity ->
        :ok

      ms when is_integer(ms) and ms > 0 ->
        :ok

      other ->
        raise ArgumentError,
              ":duration must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  @impl true
  def handle_call({:attach, events}, _from, state) do
    {reply, state} =
      case do_attach(state, events) do
        {:ok, state} -> {:ok, state}
        {:error, reason, state} -> {{:error, reason}, state}
      end

    {:reply, reply, state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, build_snapshot(state), state}
  def handle_call(:handler_ids, _from, state), do: {:reply, state.handler_ids, state}

  def handle_call(:finish, _from, state) do
    state = finish(state, :stopped)
    {:reply, build_snapshot(state), state}
  end

  @impl true
  def handle_info(:time_limit, state), do: {:noreply, finish(state, :time_limit)}

  def handle_info(:check_limits, %{status: :running} = state) do
    if :counters.get(state.cfg.counters, @total) >= state.opts[:max_events] do
      :atomics.put(state.cfg.stop, 1, 1)
    end

    Process.send_after(self(), :check_limits, state.opts[:check_interval])
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    detach_all(state)
    erase_config(state.pt_key)
    send(state.janitor, :done)
    :ok
  end

  # Erasing a persistent term schedules a global literal-area check; done
  # once per observer lifetime (documented in LIMITATIONS.md).
  defp erase_config(key) do
    :persistent_term.erase(key)
  catch
    _, _ -> :ok
  end

  ## internals -------------------------------------------------------------------

  defp attach_failure(state) do
    id = {state.id_base, :failure}

    :ok = :telemetry.attach(id, @failure_event, &__MODULE__.handle_failure/4, state.pt_key)

    register_ids(state, [id])
  end

  defp do_attach(%{status: status} = state, _events) when status != :running,
    do: {:error, :not_running, state}

  defp do_attach(state, events) do
    new =
      events
      |> Enum.filter(&TeleScope.EventName.valid_name?/1)
      |> Enum.reject(&MapSet.member?(state.attached, &1))
      |> Enum.reject(&(&1 == @failure_event))
      |> Enum.uniq()

    room = state.opts[:max_attached_events] - MapSet.size(state.attached)
    {take, _skipped} = Enum.split(new, max(room, 0))

    cond do
      take == [] and new != [] ->
        {:error, :max_attached_events, state}

      take == [] ->
        {:ok, state}

      true ->
        id = {state.id_base, length(state.handler_ids)}
        :ok = :telemetry.attach_many(id, take, &__MODULE__.handle_event/4, state.pt_key)
        state = register_ids(state, [id])
        {:ok, %{state | attached: Enum.into(take, state.attached)}}
    end
  end

  defp register_ids(state, ids) do
    send(state.janitor, {:ids, ids})
    %{state | handler_ids: ids ++ state.handler_ids}
  end

  defp finish(%{status: :running} = state, status) do
    if state.timer, do: Process.cancel_timer(state.timer)
    detach_all(state)
    %{state | status: status, finished_at: System.system_time(:millisecond)}
  end

  defp finish(state, _status), do: state

  defp detach_all(state) do
    Enum.each(state.handler_ids, &:telemetry.detach/1)
  end

  defp spawn_janitor(observer, pt_key) do
    spawn(fn ->
      ref = Process.monitor(observer)
      janitor_loop(ref, pt_key, [])
    end)
  end

  defp janitor_loop(ref, pt_key, ids) do
    receive do
      {:ids, new} ->
        janitor_loop(ref, pt_key, new ++ ids)

      :done ->
        :ok

      {:DOWN, ^ref, :process, _, _} ->
        Enum.each(ids, &:telemetry.detach/1)
        erase_config(pt_key)
    end
  end

  ## snapshot ------------------------------------------------------------------

  defp build_snapshot(state) do
    tab = state.cfg.tab
    rows = :ets.tab2list(tab)

    registry =
      for {{:shape, ev, h}, ms, md, proc, first} <- rows,
          into: %{},
          do: {{ev, h}, {ms, md, proc, first}}

    # sum per-scheduler stripes
    stripes =
      Enum.reduce(rows, %{}, fn
        {{:c, ev, h, _sched}, n, last}, acc ->
          Map.update(acc, {ev, h}, {n, last}, fn {n0, l0} -> {n0 + n, max(l0, last)} end)

        _, acc ->
          acc
      end)

    table_overflow = for {{:overflow, ev}, n} <- rows, into: %{}, do: {ev, n}

    {shapes, shape_overflow} =
      Enum.reduce(stripes, {%{}, table_overflow}, fn {{ev, h}, {count, last}}, {shapes, over} ->
        case Map.fetch(registry, {ev, h}) do
          {:ok, {ms, md, proc, first}} ->
            entry = {count, first, last, sort(ms), sort(md), proc}
            {Map.update(shapes, ev, [entry], &[entry | &1]), over}

          :error ->
            {shapes, Map.update(over, ev, count, &(&1 + count))}
        end
      end)

    events =
      Map.new(shapes, fn {ev, list} ->
        {ev, aggregate(list, Map.get(shape_overflow, ev, 0), state)}
      end)

    events =
      Enum.reduce(shape_overflow, events, fn {ev, n}, acc ->
        Map.put_new(acc, ev, aggregate([], n, state))
      end)

    failures =
      for {{:failure, id, ev}, n, kind} <- rows,
          do: %{handler_id: id, event: ev, count: n, kind: kind}

    c = state.cfg.counters

    %{
      status: state.status,
      started_at: state.started_at,
      finished_at: state.finished_at,
      sample_rate: state.cfg.sample_rate,
      attached_events: MapSet.to_list(state.attached),
      total_events: :counters.get(c, @total) + :counters.get(c, @dropped),
      recorded_events: :counters.get(c, @total),
      dropped_events: :counters.get(c, @dropped),
      callback_errors: :counters.get(c, @errors),
      ets_rows: :ets.info(tab, :size),
      ets_memory_bytes: :ets.info(tab, :memory) * :erlang.system_info(:wordsize),
      events: events,
      handler_failures: failures
    }
  end

  defp sort(list) when is_list(list), do: Enum.sort(list)
  defp sort(other), do: other

  defp aggregate(shapes, overflow, state) do
    recorded = shapes |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    count = recorded + overflow
    rate = state.cfg.sample_rate

    %{
      count: if(rate < 1.0, do: round(count / rate), else: count),
      count_estimated: rate < 1.0,
      shape_count: length(shapes),
      shape_overflow: overflow,
      first_seen_at: shapes |> Enum.map(&elem(&1, 1)) |> Enum.min(fn -> nil end),
      last_seen_at: shapes |> Enum.map(&elem(&1, 2)) |> Enum.max(fn -> nil end),
      measurements: key_stats(shapes, 3, recorded),
      metadata: key_stats(shapes, 4, recorded),
      processes: shapes |> Enum.map(&elem(&1, 5)) |> Enum.uniq() |> Enum.take(5)
    }
  end

  # pos: tuple index of the shape inside {count, first, last, ms, md, proc}
  defp key_stats(shapes, pos, recorded) do
    shapes
    |> Enum.reduce(%{}, fn shape, acc ->
      count = elem(shape, 0)

      case elem(shape, pos) do
        list when is_list(list) ->
          Enum.reduce(list, acc, fn {k, t}, acc ->
            Map.update(acc, k, %{seen: count, types: %{t => count}}, fn s ->
              %{s | seen: s.seen + count, types: Map.update(s.types, t, count, &(&1 + count))}
            end)
          end)

        {:too_many_keys, _} ->
          Map.update(
            acc,
            :__too_many_keys__,
            %{seen: count, types: %{}},
            &%{&1 | seen: &1.seen + count}
          )

        _ ->
          acc
      end
    end)
    |> Map.new(fn {k, s} ->
      {k, Map.put(s, :presence, if(recorded > 0, do: s.seen / recorded, else: 0.0))}
    end)
  end
end
