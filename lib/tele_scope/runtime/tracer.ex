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
      names stop producing messages (O(1), flat from 1 to 10,000 names).
    * Names longer than 16 segments or improper lists are filtered in the
      match spec guard (no message, no copy).

  ## Bounding mailbox growth (pre-release audit, experiment B6)

  Re-installing a trace pattern waits for every scheduler to pass a
  thread-progress point: 53-166 ms with all schedulers emitting. A new *hot*
  name leaks one message per call during that window (128k-226k messages
  measured). Therefore:

    * patterns are re-installed by a short-lived **installer** process, so
      the tracer keeps draining and watching its mailbox;
    * the match spec also requires a **gate bit** of the VM's trace control
      word to be clear. When the mailbox exceeds `:gate_threshold`, the
      tracer sets the bit (one atomic write, ~2 us), which stops all
      *unknown-name* messages immediately; it clears the bit once suppression
      has been installed and the mailbox has drained. Names emitted only while
      the gate is closed are missed; the result reports `gate_closures` and
      `gated_ms` so this is never silent;
    * the hard circuit breaker (`:max_mailbox`) remains as a last resort.

  ## Backends

    * `:session` (OTP 27+): `:trace.session_create/3`. Isolated from other
      tracers; owned by the tracer process and destroyed with it.
    * `:legacy` (OTP 26): `:erlang.trace/3` + global `:erlang.trace_pattern/3`.
      Only **one** legacy tracer may run at a time (a second returns
      `{:error, {:already_tracing, pid}}`): two would share global patterns
      and the first to stop would blind the other (audit R1).

  A janitor process removes patterns (legacy) and clears the gate bit if the
  tracer is killed.

  ## Safety limits

  Explicit start only; time-boxed (`:duration`, default 10 s, max 10 min
  unless `allow_long: true`); gate + mailbox breaker; caps on messages and
  names; stops when its owner dies.

  Counts reported by the tracer are **lower bounds**. Use the observer for counts.
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
    # hard last-resort breaker (~8 MB of 14-16 word messages); the gate keeps
    # the mailbox far below this in practice (BENCHMARKS.md, section 2)
    max_mailbox: 50_000,
    gate_threshold: 1_000,
    backend: :auto,
    known: [],
    suppress: true,
    notify: nil
  ]

  @traced [{:telemetry, :execute, 3}, {:telemetry, :execute_lazy, 3}]
  @max_segments 16
  # An unusual high bit of the trace control word, reserved for TeleScope.
  @gate_bit 0x100000
  @legacy_lock TeleScope.Runtime.Tracer.LegacyLock
  @check_every 32
  @gate_poll 5

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
  `:max_mailbox`, `:gate_threshold`, `:notify` (pid receiving
  `{:telescope_tracer, :new_names, names}`).
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
      {:"=<", {:length, :"$1"}, @max_segments},
      {:==, {:band, {:get_tcw}, @gate_bit}, 0}
    ]

    guards =
      if map_size(known) == 0,
        do: guards,
        else: guards ++ [{:not, {:is_map_key, :"$1", {:const, known}}}]

    [{[:"$1", :_, :_], guards, [{:message, :"$1"}]}]
  end

  @doc false
  def gate_bit, do: @gate_bit

  ## GenServer -------------------------------------------------------------------

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    # trace_pattern silently matches 0 functions for modules that are not
    # loaded yet (verified experimentally), so load telemetry explicitly.
    with :ok <- validate(opts),
         {:ok, backend} <- select_backend(opts[:backend]),
         :ok <- acquire_lock(backend),
         {:module, :telemetry} <- Code.ensure_loaded(:telemetry) do
      Process.flag(:trap_exit, true)
      # keeps reaction time short when emitters saturate every scheduler;
      # per-message work is tiny and bounded by the gate and breaker
      Process.flag(:priority, :high)
      warm_up()
      owner_ref = Process.monitor(opts[:owner])

      known =
        if opts[:suppress],
          do: Map.new(opts[:known], &{&1, true}),
          else: %{}

      state = %{
        opts: opts,
        backend: backend,
        session: nil,
        janitor: spawn_janitor(self(), backend),
        known: known,
        names: %{},
        invalid: 0,
        messages: 0,
        pattern_updates: 0,
        installer: nil,
        install_dirty: false,
        pending_notify: [],
        gate_closed_at: nil,
        gate_closures: 0,
        gated_ms: 0,
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

  # In interactive code loading mode (mix run, iex -S mix, tests) modules are
  # loaded on first use. Loading them while handling the first message of a
  # burst delayed the gate by up to ~250 ms (audit: 7k-87k queued messages on
  # the first burst in a fresh VM vs 1-2k afterwards). Load and exercise the
  # message path up front.
  defp warm_up do
    for mod <- [TeleScope.EventName, Process, Map, System, Bitwise, :proc_lib],
        do: Code.ensure_loaded(mod)

    _ = TeleScope.EventName.valid_name?([:warm, :up])
    _ = process_info(self())
    _ = Process.info(self(), :message_queue_len)
    _ = :erlang.system_info(:trace_control_word)
    :ok
  end

  defp validate(opts) do
    d = opts[:duration]

    cond do
      not (is_integer(d) and d > 0) ->
        {:error, {:invalid_option, :duration}}

      d > opts[:max_duration] and not opts[:allow_long] ->
        {:error, {:duration_too_long, d, opts[:max_duration]}}

      not is_list(opts[:known]) or not Enum.all?(opts[:known], &is_list/1) ->
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

  # Legacy patterns and the `:all` tracer flag are VM-global: one at a time.
  defp acquire_lock(:legacy) do
    Process.register(self(), @legacy_lock)
    :ok
  rescue
    ArgumentError -> {:error, {:already_tracing, Process.whereis(@legacy_lock)}}
  end

  defp acquire_lock(_), do: :ok

  @impl true
  def handle_info({:trace, _pid, :call, {_m, _f, _a}, name} = msg, state) do
    state = %{state | messages: state.messages + 1}
    state = record(msg, name, state)
    {:noreply, check_limits(state)}
  end

  def handle_info({:installed, pid, result}, %{installer: pid} = state) do
    state = %{state | installer: nil, pattern_updates: state.pattern_updates + 1}

    state =
      case result do
        :ok ->
          state

        {:error, reason} ->
          %{state | warnings: ["pattern update failed: #{inspect(reason)}" | state.warnings]}
      end

    state =
      if state.install_dirty, do: start_install(%{state | install_dirty: false}), else: state

    {:noreply, state |> maybe_open_gate() |> flush_notify()}
  end

  def handle_info({:EXIT, pid, reason}, %{installer: pid} = state) when reason != :normal do
    state = %{
      state
      | installer: nil,
        warnings: ["installer crashed: #{inspect(reason)}" | state.warnings]
    }

    {:noreply, maybe_open_gate(state)}
  end

  def handle_info(:gate_poll, state) do
    state = maybe_open_gate(state)
    if state.gate_closed_at, do: Process.send_after(self(), :gate_poll, @gate_poll)
    {:noreply, state}
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

    case install_patterns(state.backend, session, state.known) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:trace_setup_failed, Exception.message(e)}}
  end

  defp start_tracing(%{backend: :legacy} = state) do
    me = self()
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

    state = %{state | skipped_processes: skipped, warnings: warnings ++ state.warnings}

    case install_patterns(:legacy, nil, state.known) do
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

  defp install_patterns(backend, session, known) do
    ms = match_spec(known)

    results =
      for mfa <- @traced do
        case backend do
          :session -> :trace.function(session, mfa, ms, [:local])
          :legacy -> :erlang.trace_pattern(mfa, ms, [:local])
        end
      end

    # trace_pattern returns 0 when the function is not loaded/exported
    if Enum.at(results, 0) == 0,
      do: {:error, :telemetry_execute_not_traceable},
      else: :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp stop_tracing(%{status: :running} = state, status) do
    if state.timer, do: Process.cancel_timer(state.timer)
    state = await_installer(state)
    teardown(state)
    state = state |> open_gate() |> drain()
    send(state.janitor, :done)
    %{state | status: status, finished_at: System.system_time(:millisecond)} |> flush_notify()
  end

  defp stop_tracing(state, _status), do: state

  # An installer finishing *after* teardown would re-install patterns.
  defp await_installer(%{installer: nil} = state), do: state

  defp await_installer(%{installer: pid} = state) do
    receive do
      {:installed, ^pid, _} -> :ok
      {:EXIT, ^pid, _} -> :ok
    after
      5_000 -> Process.exit(pid, :kill)
    end

    %{state | installer: nil}
  end

  defp teardown(%{backend: :session, session: session}) when session != nil do
    :trace.session_destroy(session)
  catch
    _, _ -> :ok
  end

  defp teardown(%{backend: :legacy}) do
    legacy_cleanup(self())
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

  defp spawn_janitor(tracer, backend) do
    spawn(fn ->
      ref = Process.monitor(tracer)

      receive do
        :done ->
          :ok

        {:DOWN, ^ref, :process, _, _} ->
          # the VM clears process flags when a tracer dies, but legacy trace
          # patterns stay installed (experiments/trace_session_experiment.exs).
          # Run twice: an installer killed with the tracer may finish its
          # BIF call after the first cleanup.
          for _ <- 1..2 do
            if backend == :legacy,
              do: for(mfa <- @traced, do: :erlang.trace_pattern(mfa, false, [:local]))

            clear_gate_bit()
            Process.sleep(200)
          end
      end
    end)
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

  ## suppression installs -------------------------------------------------------------

  # Leading edge: a new name triggers an install immediately unless one is in
  # flight; names discovered meanwhile are batched into the next install.
  defp schedule_install(%{installer: nil} = state), do: start_install(state)
  defp schedule_install(state), do: %{state | install_dirty: true}

  defp start_install(%{status: :running} = state) do
    tracer = self()
    {backend, session, known} = {state.backend, state.session, state.known}

    pid =
      spawn_link(fn ->
        send(tracer, {:installed, self(), install_patterns(backend, session, known)})
      end)

    %{state | installer: pid}
  end

  defp start_install(state), do: state

  ## gate --------------------------------------------------------------------------

  defp close_gate(%{gate_closed_at: nil} = state) do
    set_gate_bit()
    Process.send_after(self(), :gate_poll, @gate_poll)

    %{
      state
      | gate_closed_at: System.monotonic_time(:millisecond),
        gate_closures: state.gate_closures + 1
    }
  end

  defp close_gate(state), do: state

  defp maybe_open_gate(%{gate_closed_at: nil} = state), do: state

  defp maybe_open_gate(state) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)

    if state.installer == nil and not state.install_dirty and
         len < div(state.opts[:gate_threshold], 4),
       do: open_gate(state),
       else: state
  end

  defp open_gate(%{gate_closed_at: nil} = state), do: state

  defp open_gate(state) do
    clear_gate_bit()
    elapsed = System.monotonic_time(:millisecond) - state.gate_closed_at
    %{state | gate_closed_at: nil, gated_ms: state.gated_ms + elapsed}
  end

  defp set_gate_bit do
    old = :erlang.system_info(:trace_control_word)
    :erlang.system_flag(:trace_control_word, Bitwise.bor(old, @gate_bit))
  end

  defp clear_gate_bit do
    old = :erlang.system_info(:trace_control_word)
    :erlang.system_flag(:trace_control_word, Bitwise.band(old, Bitwise.bnot(@gate_bit)))
  catch
    _, _ -> :ok
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
          schedule_install(%{state | known: Map.put(state.known, name, true)})
        else
          state
        end
    end
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
      if rem(state.messages, @check_every) == 0 do
        {:message_queue_len, len} = Process.info(self(), :message_queue_len)
        state = %{state | peak_mailbox: max(state.peak_mailbox, len)}
        if len > state.opts[:gate_threshold], do: close_gate(state), else: state
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
    gated_now =
      if state.gate_closed_at,
        do: System.monotonic_time(:millisecond) - state.gate_closed_at,
        else: 0

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
      gate_closures: state.gate_closures,
      gated_ms: state.gated_ms + gated_now,
      skipped_processes: state.skipped_processes,
      warnings: state.warnings
    }
  end
end
