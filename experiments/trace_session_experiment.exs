# Experiment B2: tracer isolation, cleanup and lifecycle.
#
# S1  (all OTP) Legacy erlang:trace: what happens when another tool (dbg-like)
#     already traces the process? Can two tracers coexist?
# S2  (all OTP) Legacy: after the tracer process dies, do trace patterns and
#     process flags remain installed? (stale-breakpoint risk)
# S3  (OTP 27+) trace sessions: a dbg-like legacy tracer and a TeleScope session
#     trace the same function concurrently with different flags. Do both work?
# S4  (OTP 27+) session_destroy removes our patterns but leaves legacy intact?
# S5  (OTP 27+) Is a session destroyed automatically when its handle is GC'd /
#     owner process dies?
Mix.install([{:telemetry, "~> 1.3"}])
Code.ensure_loaded!(:telemetry)

defmodule H do
  def drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  def collector do
    parent = self()
    spawn(fn -> loop(parent, []) end)
  end

  defp loop(parent, acc) do
    receive do
      {:get, from} -> send(from, {:msgs, Enum.reverse(acc)}); loop(parent, [])
      :stop -> :ok
      m -> loop(parent, [m | acc])
    end
  end

  def get(pid) do
    send(pid, {:get, self()})
    receive do {:msgs, m} -> m after 1000 -> :timeout end
  end

  def summarize(msgs) do
    Enum.map(msgs, fn
      {:trace, _, :call, {_, _, args}, extra} when is_list(args) -> {:args, extra}
      {:trace, _, :call, {_, _, args}} when is_list(args) -> {:args, hd(args)}
      {:trace, _, :call, {_, _, a}, extra} when is_integer(a) -> {:arity, extra}
      other -> other
    end)
  end

  def emit(name), do: :telemetry.execute(name, %{v: 1}, %{big: String.duplicate("y", 1000)})
end

ms = [{[:"$1", :_, :_], [], [{:message, :"$1"}]}]
IO.puts("OTP #{System.otp_release()}")

# ---- S1: two legacy tracers on the same process
IO.puts("\n== S1: second legacy tracer on an already-traced process ==")
dbg_like = H.collector()
ours = H.collector()
worker = spawn(fn -> receive do :never -> :ok end end)
:erlang.trace(worker, true, [:call, {:tracer, dbg_like}])
r =
  try do
    :erlang.trace(worker, true, [:call, :arity, {:tracer, ours}])
  rescue
    e -> {:raised, e}
  end
IO.puts("  second erlang:trace on same pid => #{inspect(r)}")
IO.puts("  tracer now: #{inspect(:erlang.trace_info(worker, :tracer))} (dbg_like=#{inspect(dbg_like)} ours=#{inspect(ours)})")
r_all = try do :erlang.trace(:all, true, [:call, {:tracer, ours}]) rescue e -> {:raised, e} end
IO.puts("  erlang:trace(:all) with another tracer active => #{inspect(r_all)}")
IO.puts("  worker tracer after :all => #{inspect(:erlang.trace_info(worker, :tracer))}")
:erlang.trace(:all, false, [:all])

# ---- S2: legacy tracer dies; what is left behind?
IO.puts("\n== S2: legacy tracer death cleanup ==")
t = H.collector()
:erlang.trace(:all, true, [:call, :arity, {:tracer, t}])
:erlang.trace_pattern({:telemetry, :execute, 3}, ms, [:local])
H.emit([:s2, :before])
IO.puts("  before death: #{inspect(H.summarize(H.get(t)))}")
send(t, :stop)
Process.sleep(50)
H.emit([:s2, :after])
IO.puts("  trace_info(execute/3, :match_spec) after tracer death => #{inspect(:erlang.trace_info({:telemetry, :execute, 3}, :match_spec))}")
IO.puts("  self() flags after tracer death => #{inspect(:erlang.trace_info(self(), :flags))}")
:erlang.trace_pattern({:telemetry, :_, :_}, false, [:local])
:erlang.trace(:all, false, [:all])

if Code.ensure_loaded?(:trace) do
  # ---- S3: session + legacy concurrently
  IO.puts("\n== S3: legacy dbg-like tracer + TeleScope session, same function ==")
  legacy = H.collector()
  :erlang.trace(:all, true, [:call, {:tracer, legacy}])
  :erlang.trace_pattern({:telemetry, :execute, 3}, true, [:global])

  ts = H.collector()
  session = :trace.session_create(:telescope, ts, [])
  n_procs = :trace.process(session, :all, true, [:call, :arity])
  n_funs = :trace.function(session, {:telemetry, :execute, 3}, ms, [:local])
  IO.puts("  session procs=#{n_procs} funs=#{n_funs}")
  H.emit([:s3, :both])
  IO.puts("  legacy got:  #{inspect(H.summarize(H.get(legacy)) |> Enum.take(3))}")
  IO.puts("  session got: #{inspect(H.summarize(H.get(ts)) |> Enum.take(3))}")

  # ---- S4: destroy session; legacy unaffected
  IO.puts("\n== S4: destroy session ==")
  :trace.session_destroy(session)
  H.emit([:s4, :after_destroy])
  IO.puts("  legacy got:  #{inspect(H.summarize(H.get(legacy)) |> Enum.take(3))}")
  IO.puts("  session got: #{inspect(H.summarize(H.get(ts)))}")
  IO.puts("  legacy pattern still: #{inspect(:erlang.trace_info({:telemetry, :execute, 3}, :traced))}")
  :erlang.trace_pattern({:telemetry, :_, :_}, false, [:global])
  :erlang.trace(:all, false, [:all])

  # ---- S5: session lifecycle when owner dies / handle GC'd
  IO.puts("\n== S5: session lifetime ==")
  ts2 = H.collector()
  owner =
    spawn(fn ->
      s = :trace.session_create(:telescope_gc, ts2, [])
      :trace.process(s, :all, true, [:call, :arity])
      :trace.function(s, {:telemetry, :execute, 3}, ms, [:local])
      receive do :exit -> :ok end
    end)
  Process.sleep(50)
  H.emit([:s5, :owner_alive])
  IO.puts("  owner alive -> session got: #{inspect(H.summarize(H.get(ts2)))}")
  IO.puts("  sessions: #{inspect(:trace.session_info(:all))}")
  send(owner, :exit)
  Process.sleep(50)
  :erlang.garbage_collect()
  Process.sleep(50)
  H.emit([:s5, :owner_dead])
  IO.puts("  owner dead -> session got: #{inspect(H.summarize(H.get(ts2)))}")
  IO.puts("  sessions: #{inspect(:trace.session_info(:all))}")

  # tracer (not owner) dies while session handle is alive
  ts3 = H.collector()
  s3 = :trace.session_create(:telescope_tdead, ts3, [])
  :trace.process(s3, :all, true, [:call, :arity])
  :trace.function(s3, {:telemetry, :execute, 3}, ms, [:local])
  send(ts3, :stop)
  Process.sleep(50)
  H.emit([:s5, :tracer_dead])
  IO.puts("  tracer dead, handle alive -> sessions: #{inspect(:trace.session_info(:all))}")
  IO.puts("  tracer dead -> session_info(execute/3): #{inspect(:trace.info(s3, {:telemetry, :execute, 3}, :all))}")
  :trace.session_destroy(s3)
else
  IO.puts("\n(S3-S5 skipped: :trace module not available on this OTP)")
end
