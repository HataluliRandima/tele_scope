# Experiment B1: what does a call-trace message on :telemetry.execute/3 actually contain?
#
# Hypotheses under test:
#   H1  Without the `arity` process flag, the trace message carries the full
#       argument list (measurements + metadata are copied to the tracer).
#   H2  With the `arity` process flag, the message carries {M, F, Arity} instead
#       of args, and a match spec `{message, '$1'}` appends ONLY the event name.
#   H3  `global` trace patterns miss telemetry's internal local calls
#       (span/3 -> execute/3); `local` patterns catch them.
#   H4  execute_lazy/3 never goes through execute/3 and must be traced separately.
#   H5  A match-spec clause with {message, false} suppresses messages for known names.
#
# Run: elixir experiments/trace_shape_experiment.exs
Mix.install([{:telemetry, "~> 1.3"}])

defmodule Collect do
  def drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end

defmodule Emit do
  def run do
    big = %{payload: String.duplicate("x", 10_000), list: Enum.to_list(1..1000)}
    :telemetry.execute([:exp, :plain], %{count: 1}, big)
    :telemetry.span([:exp, :span], %{}, fn -> {:ok, %{}} end)
    if function_exported?(:telemetry, :execute_lazy, 3) do
      :telemetry.execute_lazy([:exp, :lazy], :fallback, fn -> {:ok, {%{a: 1}, %{}}} end)
    end
    :ok
  end
end

legacy = fn label, proc_flags, ms, pattern_flags ->
  parent = self()
  target = spawn(fn -> receive do :go -> Emit.run(); send(parent, :done) end end)
  :erlang.trace(target, true, [:call, {:tracer, self()} | proc_flags])
  n =
    for {f, a} <- [{:execute, 3}, {:execute_lazy, 3}] do
      :erlang.trace_pattern({:telemetry, f, a}, ms, pattern_flags)
    end
  IO.puts("\n[#{label}] telemetry loaded?=#{:erlang.module_loaded(:telemetry)} trace_pattern matched=#{inspect(n)}")
  send(target, :go)
  receive do :done -> :ok end
  msgs = Collect.drain() |> Enum.reject(&(&1 == :done))
  :erlang.trace_pattern({:telemetry, :_, :_}, false, [:local])
  :erlang.trace_pattern({:telemetry, :_, :_}, false, [:global])

  IO.puts("\n== #{label} ==")
  for m <- msgs do
    shape =
      case m do
        {:trace, _pid, :call, {mod, fun, args}, extra} when is_list(args) ->
          "call #{mod}.#{fun} ARGS(len=#{length(args)}) extra=#{inspect(extra)}"
        {:trace, _pid, :call, {mod, fun, arity}, extra} ->
          "call #{mod}.#{fun}/#{arity} extra=#{inspect(extra)}"
        {:trace, _pid, :call, {mod, fun, args}} when is_list(args) ->
          "call #{mod}.#{fun} ARGS(len=#{length(args)}) (no extra)"
        {:trace, _pid, :call, {mod, fun, arity}} ->
          "call #{mod}.#{fun}/#{arity} (no extra)"
        other -> inspect(other, limit: 5)
      end
    IO.puts("  #{shape}  [flat_size=#{:erts_debug.flat_size(m)} words]")
  end
  msgs
end

ms_name = [{[:"$1", :_, :_], [], [{:message, :"$1"}]}]

IO.puts("OTP #{System.otp_release()} / Elixir #{System.version()}")
if System.get_env("PRELOAD") == "1", do: Code.ensure_loaded!(:telemetry)
legacy.("H1: no arity flag, ms {message,'$1'}, global", [], ms_name, [:global])
legacy.("H2: arity flag, ms {message,'$1'}, global", [:arity], ms_name, [:global])
legacy.("H3: arity flag, ms {message,'$1'}, local", [:arity], ms_name, [:local])

known = [[:exp, :plain]]
suppress = Enum.map(known, fn n -> {[n, :_, :_], [], [{:message, false}]} end) ++ ms_name
legacy.("H5: arity + suppression of [:exp, :plain], local", [:arity], suppress, [:local])
