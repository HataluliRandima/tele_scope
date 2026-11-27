defmodule TeleScope.Runtime.Capture do
  @moduledoc """
  Coordinates one time-boxed runtime capture:

    * an `Observer` attached to every known event name (shapes + counts)
    * optionally a `Tracer` that discovers *additional* names (known names are
      pre-suppressed); each newly discovered name is attached to the observer
    * a handler snapshot at start and end, with optional invocation counting

  Observer counts for names discovered by the tracer start at the moment of
  discovery; the first occurrence(s) are only seen by the tracer.
  """
  use GenServer

  alias TeleScope.Runtime.{Handlers, Observer, Tracer}

  # how often handlers attached after the capture started are picked up
  @refresh 250

  @defaults [
    duration: 10_000,
    events: [],
    trace: true,
    track_handlers: true,
    observer: [],
    tracer: []
  ]

  def start(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start(__MODULE__, opts)
  end

  @doc "Blocks until the capture finishes (or is stopped) and returns the result."
  def await(pid, timeout \\ :infinity), do: GenServer.call(pid, :await, timeout)

  @doc """
  Stops early and returns the result, or `{:error, :not_running}` when the
  capture process no longer exists (already stopped, or its owner died).
  """
  def stop(pid) do
    res = GenServer.call(pid, :stop, 60_000)
    GenServer.stop(pid)
    res
  catch
    :exit, _ -> {:error, :not_running}
  end

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    with :ok <- validate(opts) do
      do_init(opts)
    end
  end

  defp validate(opts) do
    case opts[:duration] do
      d when is_integer(d) and d > 0 -> :ok
      other -> {:stop, {:invalid_option, {:duration, other}}}
    end
  end

  defp do_init(opts) do
    Process.flag(:trap_exit, true)
    duration = opts[:duration]
    owner_ref = Process.monitor(opts[:owner])
    events = Enum.filter(opts[:events], &TeleScope.EventName.valid_name?/1)

    with {:ok, observer} <-
           Observer.start(Keyword.merge([events: events, duration: :infinity], opts[:observer])) do
      # The tracer is optional: when the VM refuses it (another legacy
      # tracer on OTP 26, no trace sessions) the capture continues with the
      # observer only and reports why (diagnostic TS011). Invalid tracer
      # options are a caller error and still fail the start.
      {tracer, tracer_error} =
        case maybe_tracer(opts, events, duration) do
          {:ok, tracer} ->
            {tracer, nil}

          {:error, reason} when elem(reason, 0) in [:invalid_option, :duration_too_long] ->
            GenServer.stop(observer)
            throw({:invalid_tracer_option, reason})

          {:error, reason} ->
            {nil, reason}
        end

      tracer_ref = tracer && Process.monitor(tracer)
      handlers = Handlers.list()
      tracker = if opts[:track_handlers], do: Handlers.track(handlers)

      timer = Process.send_after(self(), :finish, duration)
      if tracker, do: Process.send_after(self(), :refresh_handlers, @refresh)

      {:ok,
       %{
         opts: opts,
         observer: observer,
         observer_ref: Process.monitor(observer),
         observer_error: nil,
         tracer: tracer,
         tracer_ref: tracer_ref,
         tracer_error: tracer_error,
         tracker: tracker,
         handlers_before: handlers,
         waiters: [],
         result: nil,
         timer: timer,
         owner_ref: owner_ref,
         started_at: System.system_time(:millisecond)
       }}
    else
      {:error, reason} -> {:stop, {:observer_failed, reason}}
    end
  catch
    {:invalid_tracer_option, reason} -> {:stop, reason}
  end

  defp maybe_tracer(opts, events, duration) do
    if opts[:trace] do
      # the capture stops the tracer itself; the tracer's own time box is a
      # safety net slightly longer than the capture, never above its maximum
      # unless the caller explicitly allows long traces
      tracer_opts = opts[:tracer]
      max = Keyword.get(tracer_opts, :max_duration, 600_000)

      safety_net =
        if Keyword.get(tracer_opts, :allow_long, false),
          do: duration + 1_000,
          else: min(duration + 1_000, max(duration, max))

      Tracer.start(
        Keyword.merge([known: events, notify: self(), duration: safety_net], tracer_opts)
      )
    else
      {:ok, nil}
    end
  end

  @impl true
  def handle_info({:telescope_tracer, :new_names, names}, state) do
    if state.result == nil and state.observer_error == nil do
      # never let an observer failure take the capture down (audit R4)
      try do
        Observer.attach(state.observer, names)
      catch
        :exit, _ -> :ok
      end
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{observer_ref: ref, result: nil} = state) do
    {:noreply, %{state | observer_error: reason}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{tracer_ref: ref, result: nil} = state)
      when reason != :normal do
    {:noreply, %{state | tracer_error: {:tracer_crashed, reason}}}
  end

  def handle_info(:finish, state), do: {:noreply, finish(state)}

  def handle_info(:refresh_handlers, %{result: nil, tracker: tracker} = state) do
    tracker = Handlers.track_more(tracker, Handlers.list())
    Process.send_after(self(), :refresh_handlers, @refresh)
    {:noreply, %{state | tracker: tracker}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, finish(state)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:await, _from, %{result: result} = state) when result != nil,
    do: {:reply, result, state}

  def handle_call(:await, from, state), do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:stop, _from, state) do
    state = finish(state)
    {:reply, state.result, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = finish(state)
    :ok
  end

  defp finish(%{result: nil} = state) do
    Process.cancel_timer(state.timer)

    # a failed tracer must not lose the observer's results
    {trace, trace_error} =
      case state.tracer && Tracer.stop(state.tracer) do
        nil -> {nil, state.tracer_error}
        %{} = res -> {res, nil}
        {:error, :not_running} -> {nil, state.tracer_error || :tracer_stopped_unexpectedly}
        error -> {nil, error}
      end

    handlers_after = Handlers.list()
    tracker = if state.tracker, do: Handlers.track_more(state.tracker, handlers_after)
    state = %{state | tracker: tracker}
    invocations = if state.tracker, do: Handlers.invocation_counts(state.tracker)
    if state.tracker, do: Handlers.stop_tracking(state.tracker)

    observations =
      case state.observer_error == nil && Observer.stop(state.observer) do
        %{} = obs -> obs
        _ -> crashed_observations(state.observer_error || :not_running, state.started_at)
      end

    result = %{
      started_at: state.started_at,
      finished_at: System.system_time(:millisecond),
      duration_ms: state.opts[:duration],
      observations: observations,
      trace: trace,
      trace_error: trace_error,
      handlers_before: state.handlers_before,
      handlers_after: handlers_after,
      invocations: invocations,
      invocation_tracking_started_at: if(state.tracker, do: state.tracker.tracked_at, else: %{}),
      shared_handler_functions: Handlers.shared_functions(handlers_after)
    }

    Enum.each(state.waiters, &GenServer.reply(&1, result))
    %{state | result: result, waiters: []}
  end

  defp finish(state), do: state

  # Same shape as Observer.snapshot/1, so downstream code never has to
  # special-case a crashed observer (audit R3).
  defp crashed_observations(reason, started_at) do
    %{
      status: :crashed,
      error: inspect(reason),
      started_at: started_at,
      finished_at: System.system_time(:millisecond),
      sample_rate: 1.0,
      attached_events: [],
      total_events: 0,
      recorded_events: 0,
      dropped_events: 0,
      callback_errors: 0,
      ets_rows: 0,
      ets_memory_bytes: 0,
      events: %{},
      handler_failures: []
    }
  end
end
