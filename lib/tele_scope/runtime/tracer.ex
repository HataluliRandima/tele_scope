defmodule TeleScope.Runtime.Tracer do
  @moduledoc """
  Discovers which telemetry event names are emitted at runtime - including
  dynamic names that static analysis cannot resolve - using call tracing on
  `:telemetry.execute/3` and `:telemetry.execute_lazy/3`.

  ## Mechanism (verified in `experiments/`, see SPIKE_RESULTS.md)

    * Process flags `[:call, :arity]`: the trace message carries
      `{telemetry, execute, 3}` instead of the argument list, so measurements
      and metadata are **never copied** to the tracer.
    * Match spec `[{[:"$1", :_, :_], Guards, [{:message, :"$1"}]}]` appends
      only the event name (14-16 words per message regardless of payload).
    * Patterns are installed with the `:local` flag: `telemetry:span/3` and
      `execute/2` reach `execute/3` through *local* calls, which `:global`
      patterns miss.
    * **Adaptive suppression**: once a name is known, the match spec is
      re-installed with guard `not is_map_key('$1', {const, Known})`, so known
      names stop producing messages. `is_map_key` against a constant map is
      O(1); measured cost is flat from 1 to 10,000 known names. Names already
      known from static analysis can be pre-suppressed (`:known`).
    * Names longer than 16 segments or improper lists are filtered in the
      match spec guard (no message, no copy).

  ## Backends

    * `:session` (OTP 27+): `:trace.session_create/3`. Isolated from other
      tracers (dbg, recon, observer); the session is owned by the tracer
      process and is destroyed automatically if the tracer dies.
    * `:legacy` (OTP 26): `:erlang.trace/3` + `:erlang.trace_pattern/3`.
      Processes already traced by another tool are skipped by the VM (one
      tracer per process) and patterns on `telemetry` are global. A janitor
      process removes the patterns if the tracer is killed.

  ## Safety limits

    * explicit start only; time-boxed (`:duration`, default 10s, max 10 min
      unless `allow_long: true`)
    * circuit breaker on the tracer's own mailbox (`:max_mailbox`)
    * caps on total messages (`:max_messages`) and names (`:max_names`)
    * stops when its owner process dies

  Counts reported by the tracer are **lower bounds** (a name stops being
  counted once suppressed). Use the observer for event counts.
  """
  use GenServer

  # :trace exists only on OTP 27+; calls are guarded by capabilities/0.
  @compile {:no_warn_undefined, :trace}

  @defaults [
    duration: 10_000,
    max_duration: 600_000,
    allow_long: false,
    max_names: 1_000,
    max_messages: 200_000,
    max_mailbox: 10_000,
    backend: :auto,
    known: [],
    suppress: true,
    notify: nil,
    suppress_debounce: 20
  ]

  @traced [{:telemetry, :execute, 3}, {:telemetry, :execute_lazy, 3}]
  @max_segments 16

  ## API -----------------------------------------------------------------------

  @doc "Reports which tracing backends this VM supports."
  def capabilities do
    sessions = Code.ensure_loaded?(:trace) and function_exported?(:trace, :session_create, 3)

    %{
      otp_release: System.otp_release(),
      sessions: sessions,
      legacy: true,
      default_backend: if(sessions, do: :session, else: :legacy)
    }
  end

  @doc """
  Starts a time-boxed trace. Returns `{:ok, pid}` or `{:error, reason}`.

  Options: `:duration`, `:backend` (`:auto | :session | :legacy`), `:known`
  (names to pre-suppress), `:suppress`, `:max_names`, `:max_messages`,
  `:max_mailbox`, `:notify` (pid receiving `{:telescope_tracer, :new_names, names}`).
  """
  def start(opts \\ []) do
    opts = Keyword.put_new(opts, :owner, self())

    case GenServer.start(__MODULE__, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Current results (does not stop tracing)."
  def result(server), do: GenServer.call(server, :result, 30_000)

  @doc "Stops tracing, cleans up and returns the final result."
  def stop(server) do
    res = GenServer.call(server, :finish, 30_000)
    GenServer.stop(server)
    res
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Builds the match spec used for tracing (public for tests/benchmarks)."
  def match_spec(known) when is_map(known) do
    guards = [
      {:is_list, :"$1"},
      {:"=<", {:length, :"$1"}, @max_segments}
    ]

    guards =
      if map_size(known) == 0,
        do: guards,
        else: guards ++ [{:not, {:is_map_key, :"$1", {:const, known}}}]

    [{[:"$1", :_, :_], guards, [{:message, :"$1"}]}]
  end

  ## GenServer -------------------------------------------------------------------

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    # trace_pattern silently matches 0 functions for modules that are not
    # loaded yet (verified experimentally), so load telemetry explicitly.
    with :ok <- validate(opts),
         {:ok, backend} <- select_backend(opts[:backend]),
         {:module, :telemetry} <- Code.ensure_loaded(:telemetry) do
      Process.flag(:trap_exit, true)
      owner_ref = Process.monitor(opts[:owner])

      known =
        if opts[:suppress],
          do: Map.new(opts[:known], &{&1, true}),
          else: %{}

      state = %{
        opts: opts,
        backend: backend,
        session: nil,
        janitor: nil,
        known: known,
        names: %{},
        invalid: 0,
        messages: 0,
        pattern_updates: 0,
        pending_update: false,
        pending_notify: [],
        status: :running,
        warnings: [],
        started_at: System.system_time(:millisecond),
        finished_at: nil,
        peak_mailbox: 0,
        owner_ref: owner_ref,
        timer: nil,
        skipped_processes: 0
      }

      case start_tracing(state) do
        {:ok, state} ->
          timer = Process.send_after(self(), :time_limit, opts[:duration])
          {:ok, %{state | timer: timer}}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
      {:stop, reason} -> {:stop, reason}
      _other -> {:stop, :telemetry_not_available}
    end
  end

  defp validate(opts) do
    d = opts[:duration]

    cond do
      not (is_integer(d) and d > 0) ->
        {:error, {:invalid_option, :duration}}

      d > opts[:max_duration] and not opts[:allow_long] ->
        {:error, {:duration_too_long, d, opts[:max_duration]}}

      not Enum.all?(opts[:known], &is_list/1) ->
        {:error, {:invalid_option, :known}}

      true ->
        :ok
    end
  end

  defp select_backend(:auto), do: {:ok, capabilities().default_backend}

  defp select_backend(:session) do
    if capabilities().sessions,
      do: {:ok, :session},
      else: {:error, {:unsupported, :trace_sessions, System.otp_release()}}
  end

  defp select_backend(:legacy), do: {:ok, :legacy}
  defp select_backend(other), do: {:error, {:invalid_option, {:backend, other}}}

  @impl true
  def handle_info({:trace, _pid, :call, {_m, _f, _a}, name} = msg, state) do
    state = %{state | messages: state.messages + 1}
    state = record(msg, name, state)
    {:noreply, check_limits(state)}
  end

  def handle_info(:update_pattern, state) do
    state = %{state | pending_update: false}

    state =
      if state.status == :running do
        install_patterns(state)
        %{state | pattern_updates: state.pattern_updates + 1}
      else
        state
      end

    {:noreply, flush_notify(state)}
  end

  def handle_info(:time_limit, state), do: {:noreply, stop_tracing(state, :completed)}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, stop_tracing(state, :owner_down)}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:result, _from, state), do: {:reply, build_result(state), state}

  def handle_call(:finish, _from, state) do
    state = stop_tracing(state, :stopped)
    {:reply, build_result(state), state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = stop_tracing(state, :terminated)
    :ok
  end

  ## tracing setup / teardown ------------------------------------------------------

  defp start_tracing(%{backend: :session} = state) do
    session = :trace.session_create(:tele_scope, self(), [])
    _ = :trace.process(session, :all, true, [:call, :arity])
    state = %{state | session: session}

    case install_patterns(state) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:trace_setup_failed, Exception.message(e)}}
  end

  defp start_tracing(%{backend: :legacy} = state) do
    me = self()
    janitor = spawn(fn -> legacy_janitor(me) end)
    _ = :erlang.trace(:all, true, [:call, :arity, {:tracer, me}])
    _ = :erlang.trace(me, false, [:call, :arity])

    skipped =
      Enum.count(Process.list(), fn p ->
        p != me and
          match?({:tracer, t} when is_pid(t) and t != me, safe_trace_info(p))
      end)

    warnings =
      if skipped > 0,
        do: ["#{skipped} processes are already traced by another tool and are not observed"],
        else: []

    state = %{
      state
      | janitor: janitor,
        skipped_processes: skipped,
        warnings: warnings ++ state.warnings
    }

    case install_patterns(state) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:trace_setup_failed, Exception.message(e)}}
  end

  defp safe_trace_info(p) do
    :erlang.trace_info(p, :tracer)
  catch
    _, _ -> nil
  end

  defp install_patterns(state) do
    ms = match_spec(state.known)

    results =
      for mfa <- @traced do
        case state.backend do
          :session -> :trace.function(state.session, mfa, ms, [:local])
          :legacy -> :erlang.trace_pattern(mfa, ms, [:local])
        end
      end

    # trace_pattern returns 0 when the function is not loaded/exported
    if Enum.at(results, 0) == 0,
      do: {:error, :telemetry_execute_not_traceable},
      else: :ok
  end

  defp stop_tracing(%{status: :running} = state, status) do
    if state.timer, do: Process.cancel_timer(state.timer)
    teardown(state)
    state = drain(state)
    %{state | status: status, finished_at: System.system_time(:millisecond)} |> flush_notify()
  end

  defp stop_tracing(state, _status), do: state

  defp teardown(%{backend: :session, session: session}) when session != nil do
    :trace.session_destroy(session)
  catch
    _, _ -> :ok
  end

  defp teardown(%{backend: :legacy, janitor: janitor}) do
    legacy_cleanup(self())
    if janitor, do: send(janitor, :done)
    :ok
  end

  defp teardown(_), do: :ok

  @doc false
  def legacy_cleanup(tracer) do
    for mfa <- @traced, do: :erlang.trace_pattern(mfa, false, [:local])

    for p <- Process.list(), safe_trace_info(p) == {:tracer, tracer} do
      try do
        :erlang.trace(p, false, [:call, :arity])
      catch
        _, _ -> :ok
      end
    end

    try do
      :erlang.trace(:new, false, [:call, :arity])
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp legacy_janitor(tracer) do
    ref = Process.monitor(tracer)

    receive do
      :done ->
        :ok

      {:DOWN, ^ref, :process, _, _} ->
        # the VM clears process flags when a tracer dies, but trace patterns
        # stay installed (verified in experiments/trace_session_experiment.exs)
        for mfa <- @traced, do: :erlang.trace_pattern(mfa, false, [:local])
        :ok
    end
  end

  # After tracing is disabled, already-sent messages are still delivered.
  defp drain(state) do
    receive do
      {:trace, _pid, :call, _mfa, name} = msg ->
        drain(record(msg, name, %{state | messages: state.messages + 1}))
    after
      0 -> state
    end
  end

  ## recording ------------------------------------------------------------------------

  defp record({:trace, pid, :call, {_, f, _}, _}, name, state) do
    cond do
      not TeleScope.EventName.valid_name?(name) ->
        %{state | invalid: state.invalid + 1}

      Map.has_key?(state.names, name) ->
        update_in(state.names[name].count, &(&1 + 1))

      map_size(state.names) >= state.opts[:max_names] ->
        state

      true ->
        entry = %{
          name: name,
          count: 1,
          first_seen_at: System.system_time(:millisecond),
          via: f,
          process: process_info(pid),
          pre_known: Map.has_key?(state.known, name)
        }

        state = %{state | names: Map.put(state.names, name, entry)}
        state = %{state | pending_notify: [name | state.pending_notify]}

        if state.opts[:suppress] and state.status == :running do
          state = %{state | known: Map.put(state.known, name, true)}
          schedule_update(state)
        else
          state
        end
    end
  end

  defp schedule_update(%{pending_update: true} = state), do: state

  defp schedule_update(state) do
    Process.send_after(self(), :update_pattern, state.opts[:suppress_debounce])
    %{state | pending_update: true}
  end

  defp flush_notify(%{pending_notify: []} = state), do: state

  defp flush_notify(state) do
    if pid = state.opts[:notify] do
      send(pid, {:telescope_tracer, :new_names, Enum.reverse(state.pending_notify)})
    end

    %{state | pending_notify: []}
  end

  defp process_info(pid) do
    case Process.info(pid, [:registered_name, :initial_call]) do
      nil ->
        nil

      info ->
        # Privacy: never copy another process's whole dictionary (it may hold
        # secrets, e.g. Logger metadata). process_info(Pid, {dictionary, Key})
        # reads a single key (OTP 26.2+); older VMs get the raw initial call.
        # :erlang directly: Elixir < 1.17's Process.info/2 guard rejects the
        # {dictionary, Key} item spec (found by the version matrix)
        initial =
          try do
            case :erlang.process_info(pid, {:dictionary, :"$initial_call"}) do
              {{:dictionary, :"$initial_call"}, {_, _, _} = mfa} -> mfa
              _ -> info[:initial_call]
            end
          catch
            _, _ -> info[:initial_call]
          end

        reg = if info[:registered_name] == [], do: nil, else: info[:registered_name]
        %{registered_name: reg, initial_call: initial}
    end
  end

  defp check_limits(%{status: :running} = state) do
    state =
      if rem(state.messages, 256) == 0 do
        {:message_queue_len, len} = Process.info(self(), :message_queue_len)
        %{state | peak_mailbox: max(state.peak_mailbox, len)}
      else
        state
      end

    cond do
      state.peak_mailbox > state.opts[:max_mailbox] -> stop_tracing(state, :overload)
      state.messages >= state.opts[:max_messages] -> stop_tracing(state, :max_messages)
      map_size(state.names) >= state.opts[:max_names] -> stop_tracing(state, :max_names)
      true -> state
    end
  end

  defp check_limits(state), do: state

  defp build_result(state) do
    %{
      status: state.status,
      backend: state.backend,
      otp_release: System.otp_release(),
      started_at: state.started_at,
      finished_at: state.finished_at,
      names: state.names |> Map.values() |> Enum.sort_by(& &1.name),
      invalid_calls: state.invalid,
      messages: state.messages,
      pattern_updates: state.pattern_updates,
      peak_mailbox: state.peak_mailbox,
      skipped_processes: state.skipped_processes,
      warnings: state.warnings
    }
  end
end
