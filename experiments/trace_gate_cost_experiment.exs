# Experiment B7 (pre-release audit): per-call cost of the trace-control-word
# gate guard. Same suppressed name, match spec with vs without the guard,
# interleaved 5 rounds, min-of-7 per measurement.
#   mix run experiments/trace_gate_cost_experiment.exs
Code.ensure_loaded!(:telemetry)

defmodule GateCost do
  def loop(0), do: :ok
  def loop(n), do: (:telemetry.execute([:g, :known], %{}, %{}); loop(n - 1))
  def run(n \\ 200_000) do
    loop(1_000)
    for(_ <- 1..7, do: elem(:timer.tc(fn -> loop(n) end), 0) * 1000 / n) |> Enum.min()
  end
end

known = %{[:g, :known] => true}
base_guards = [{:is_list, :"$1"}, {:"=<", {:length, :"$1"}, 16}]
suppress = [{:not, {:is_map_key, :"$1", {:const, known}}}]
gate = [{:==, {:band, {:get_tcw}, 0x100000}, 0}]
without = [{[:"$1", :_, :_], base_guards ++ suppress, [{:message, :"$1"}]}]
with_gate = [{[:"$1", :_, :_], base_guards ++ gate ++ suppress, [{:message, :"$1"}]}]

tracer = spawn(fn -> receive do: (:never -> :ok) end)
:erlang.trace(self(), true, [:call, :arity, {:tracer, tracer}])

measure = fn ms ->
  :erlang.trace_pattern({:telemetry, :execute, 3}, ms, [:local])
  GateCost.run()
end

IO.puts("OTP #{System.otp_release()}")
:erlang.trace(self(), false, [:all])
base = GateCost.run()
:erlang.trace(self(), true, [:call, :arity, {:tracer, tracer}])

rows =
  for round <- 1..5 do
    a = measure.(without)
    b = measure.(with_gate)
    IO.puts("round #{round}: no-trace #{round(base)} ns | suppressed w/o gate +#{round(a - base)} ns | with gate +#{round(b - base)} ns | gate cost #{round(b - a)} ns")
    b - a
  end

IO.puts("median gate cost: #{rows |> Enum.sort() |> Enum.at(2) |> round()} ns")
:erlang.trace_pattern({:telemetry, :execute, 3}, false, [:local])
:erlang.trace(self(), false, [:all])
