# Experiment B6 (pre-release audit): bounding tracer mailbox growth under a
# burst of ONE new event name.
#
# Q1  Is {get_tcw} (trace control word) allowed in a trace match-spec guard?
# Q2  How long does re-installing a trace pattern take while all schedulers
#     emit telemetry (the window during which a new hot name leaks messages)?
# Q3  Does closing a TCW gate (one atomic write, no thread-progress barrier)
#     stop messages immediately?
#   mix run experiments/trace_gate_experiment.exs
Code.ensure_loaded!(:telemetry)

gated = fn known ->
  [{[:"$1", :_, :_], [{:==, {:get_tcw}, 0}, {:not, {:is_map_key, :"$1", {:const, known}}}], [{:message, :"$1"}]}]
end

IO.puts("OTP #{System.otp_release()}")
orig = :erlang.system_info(:trace_control_word)

# Q1
:erlang.system_flag(:trace_control_word, 0)
open = :erlang.match_spec_test([[:a], %{}, %{}], gated.(%{}), :trace)
:erlang.system_flag(:trace_control_word, 1)
closed = :erlang.match_spec_test([[:a], %{}, %{}], gated.(%{}), :trace)
:erlang.system_flag(:trace_control_word, orig)
IO.puts("Q1 get_tcw in guard: open=#{inspect(open)} closed=#{inspect(closed)}")

# Q2 + Q3 with legacy tracing (same mechanism as sessions for this purpose)
parent = self()
tracer = spawn(fn -> receive do: (:stop -> send(parent, {:len, Process.info(self(), :message_queue_len)})) end)

flood = fn ms ->
  :erlang.system_flag(:trace_control_word, 0)
  :erlang.trace(:all, true, [:call, :arity, {:tracer, tracer}])
  :erlang.trace_pattern({:telemetry, :execute, 3}, ms, [:local])

  emitters =
    for _ <- 1..System.schedulers_online() do
      spawn(fn -> Stream.repeatedly(fn -> :telemetry.execute([:gate, :hot], %{}, %{}) end) |> Stream.run() end)
    end

  emitters
end

stop_all = fn emitters ->
  Enum.each(emitters, &Process.exit(&1, :kill))
  :erlang.trace_pattern({:telemetry, :execute, 3}, false, [:local])
  :erlang.trace(:all, false, [:all])
end

# Q2: latency of re-installing the pattern under full load
emitters = flood.(gated.(%{}))
Process.sleep(20)
{us, _} = :timer.tc(fn -> :erlang.trace_pattern({:telemetry, :execute, 3}, gated.(%{[:gate, :hot] => true}), [:local]) end)
{:message_queue_len, after_install} = Process.info(tracer, :message_queue_len)
Process.sleep(20)
{:message_queue_len, later} = Process.info(tracer, :message_queue_len)
stop_all.(emitters)
IO.puts("Q2 trace_pattern re-install under load: #{div(us, 1000)} ms; tracer mailbox #{after_install} -> #{later} 20 ms after (suppressed)")

# Q3: gate close latency
tracer2 = spawn(fn -> receive do: (:never -> :ok) end)
:erlang.system_flag(:trace_control_word, 0)
:erlang.trace(:all, true, [:call, :arity, {:tracer, tracer2}])
:erlang.trace_pattern({:telemetry, :execute, 3}, gated.(%{}), [:local])
emitters = for _ <- 1..System.schedulers_online(), do: spawn(fn -> Stream.repeatedly(fn -> :telemetry.execute([:gate, :hot2], %{}, %{}) end) |> Stream.run() end)
Process.sleep(5)
{us, _} = :timer.tc(fn -> :erlang.system_flag(:trace_control_word, 1) end)
{:message_queue_len, at_close} = Process.info(tracer2, :message_queue_len)
Process.sleep(20)
{:message_queue_len, after_close} = Process.info(tracer2, :message_queue_len)
Enum.each(emitters, &Process.exit(&1, :kill))
:erlang.trace_pattern({:telemetry, :execute, 3}, false, [:local])
:erlang.trace(:all, false, [:all])
:erlang.system_flag(:trace_control_word, orig)
IO.puts("Q3 gate close took #{us} us; tracer mailbox #{at_close} at close -> #{after_close} 20 ms later (growth #{after_close - at_close})")
Process.exit(tracer, :kill)
Process.exit(tracer2, :kill)
