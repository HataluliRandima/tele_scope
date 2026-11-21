# Experiment D1: handler enumeration and invocation tracking.
#
# Q1  Does :telemetry.list_handlers([]) return every handler (global enumeration)?
# Q2  Can call_count tracing count invocations of handler functions without a
#     tracer process / message traffic? For external captures (&M.f/4) and
#     anonymous funs (fn ... end, which compile to local functions)?
# Q3  Does it work inside an OTP 27+ trace session (isolated)?
# Q4  What happens to a failing handler (auto-detach + [:telemetry, :handler, :failure])?
Mix.install([{:telemetry, "~> 1.3"}])
Code.ensure_loaded!(:telemetry)

defmodule MyHandlers do
  def handle(_e, _m, _md, _c), do: :ok
  def anon_handler, do: fn _e, _m, _md, _c -> :ok end
  def closure_handler(x), do: fn _e, _m, _md, _c -> x end
  def crash(_e, _m, _md, _c), do: raise("boom")
end

IO.puts("OTP #{System.otp_release()}")
:ok = :telemetry.attach("ext", [:a, :b], &MyHandlers.handle/4, nil)
:ok = :telemetry.attach_many("many", [[:a, :b], [:c, :d]], &MyHandlers.handle/4, nil)
:ok = :telemetry.attach("anon", [:c, :d], MyHandlers.anon_handler(), nil)
:ok = :telemetry.attach("closure", [:x, :y, :z], MyHandlers.closure_handler(42), nil)

all = :telemetry.list_handlers([])
IO.puts("\nQ1 list_handlers([]) -> #{length(all)} entries: #{inspect(Enum.map(all, &{&1.id, &1.event_name}))}")
IO.puts("   list_handlers([:a]) -> #{inspect(Enum.map(:telemetry.list_handlers([:a]), & &1.id))}")
IO.puts("   list_handlers([:a, :b, :c]) (longer than event) -> #{inspect(:telemetry.list_handlers([:a, :b, :c]))}")

mfa_of = fn fun ->
  info = Function.info(fun)
  case info[:type] do
    :external -> {info[:module], info[:name], info[:arity]}
    :local -> {info[:module], info[:name], info[:arity] + length(info[:env])}
  end
end

mfas = all |> Enum.map(& &1.function) |> Enum.uniq() |> Enum.map(mfa_of)
IO.puts("\n   handler MFAs (local funs resolved to underlying function): #{inspect(mfas)}")

emit = fn ->
  for _ <- 1..3, do: :telemetry.execute([:a, :b], %{}, %{})
  for _ <- 1..2, do: :telemetry.execute([:c, :d], %{}, %{})
  :ok
end

IO.puts("\nQ2 legacy call_count:")
for mfa <- mfas, do: IO.puts("   trace_pattern #{inspect(mfa)} -> #{:erlang.trace_pattern(mfa, true, [:local, :call_count])}")
emit.()
for mfa <- mfas, do: IO.puts("   #{inspect(mfa)} -> #{inspect(:erlang.trace_info(mfa, :call_count))}")
for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:local, :call_count])

if Code.ensure_loaded?(:trace) do
  IO.puts("\nQ3 session call_count (tracer = self, but no process flags set):")
  s = :trace.session_create(:telescope_cc, self(), [])
  for mfa <- mfas, do: :trace.function(s, mfa, true, [:local, :call_count])
  emit.()
  for mfa <- mfas, do: IO.puts("   #{inspect(mfa)} -> #{inspect(:trace.info(s, mfa, :call_count))}")
  IO.puts("   legacy view of same mfa (isolation): #{inspect(:erlang.trace_info(hd(mfas), :call_count))}")
  receive do
    m -> IO.puts("   unexpected message: #{inspect(m)}")
  after
    100 -> IO.puts("   no messages delivered to session tracer (as expected for call_count)")
  end
  :trace.session_destroy(s)
end

IO.puts("\nQ4 failing handler:")
parent = self()
:telemetry.attach("failure-watch", [:telemetry, :handler, :failure], fn _e, _m, md, _ ->
  send(parent, {:failure, md.handler_id, md.kind})
end, nil)
:telemetry.attach("crasher", [:boom], &MyHandlers.crash/4, nil)
Logger.configure(level: :none)
:telemetry.execute([:boom], %{}, %{})
receive do
  {:failure, id, kind} -> IO.puts("   failure event: handler_id=#{inspect(id)} kind=#{inspect(kind)}")
after
  500 -> IO.puts("   no failure event")
end
IO.puts("   crasher still attached? #{Enum.any?(:telemetry.list_handlers([:boom]), &(&1.id == "crasher"))}")
