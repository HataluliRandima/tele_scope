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

  @doc "Stops early and returns the result."
  def stop(pid) do
    res = GenServer.call(pid, :stop, 60_000)
    GenServer.stop(pid)
    res
  end

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)
    Process.flag(:trap_exit, true)
    duration = opts[:duration]
    owner_ref = Process.monitor(opts[:owner])
    events = Enum.filter(opts[:events], &TeleScope.EventName.valid_name?/1)

    with {:ok, observer} <-
           Observer.start(Keyword.merge([events: events, duration: :infinity], opts[:observer])),
         {:ok, tracer} <- maybe_tracer(opts, events, duration) do
      handlers = Handlers.list()
      tracker = if opts[:track_handlers], do: Handlers.track(handlers)

      timer = Process.send_after(self(), :finish, duration)
      if tracker, do: Process.send_after(self(), :refresh_handlers, @refresh)

      {:ok,
       %{
         opts: opts,
         observer: observer,
         tracer: tracer,
         tracker: tracker,
         handlers_before: handlers,
         waiters: [],
         result: nil,
         timer: timer,
         owner_ref: owner_ref,
         started_at: System.system_time(:millisecond)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp maybe_tracer(opts, events, duration) do
    if opts[:trace] do
      Tracer.start(
        Keyword.merge(
          [known: events, notify: self(), duration: duration + 1_000],
          opts[:tracer]
        )
      )
    else
      {:ok, nil}
    end
  end

  @impl true
  def handle_info({:telescope_tracer, :new_names, names}, state) do
    if state.result == nil, do: Observer.attach(state.observer, names)
    {:noreply, state}
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
        nil -> {nil, nil}
        %{} = res -> {res, nil}
        error -> {nil, error}
      end

    handlers_after = Handlers.list()
    tracker = if state.tracker, do: Handlers.track_more(state.tracker, handlers_after)
    state = %{state | tracker: tracker}
    invocations = if state.tracker, do: Handlers.invocation_counts(state.tracker)
    if state.tracker, do: Handlers.stop_tracking(state.tracker)
    observations = Observer.stop(state.observer)

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
end
