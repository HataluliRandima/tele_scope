# Experiment C2: does the size/content of a handler's *config* term cost time on
# every :telemetry.execute? (telemetry copies the handler record out of ETS)
#   mix run experiments/handler_config_experiment.exs
defmodule CfgBench do
  def loop(_e, 0), do: :ok
  def loop(e, n), do: (:telemetry.execute(e, %{}, %{}); loop(e, n - 1))
  def run(n \\ 200_000) do
    loop([:cfg], 1_000)
    runs = for _ <- 1..7, do: elem(:timer.tc(fn -> loop([:cfg], n) end), 0) * 1000 / n
    Enum.min(runs)
  end

  def concurrent(procs, n \\ 50_000) do
    runs =
      for _ <- 1..5 do
        parent = self()
        {us, _} =
          :timer.tc(fn ->
            pids = for _ <- 1..procs, do: spawn_link(fn -> receive(do: (:go -> loop([:cfg], n))); send(parent, :done) end)
            Enum.each(pids, &send(&1, :go))
            for _ <- pids, do: receive(do: (:done -> :ok))
          end)
        us * 1000 / (n * procs)
      end
    Enum.min(runs)
  end
  def noop(_, _, _, _), do: :ok
  def pt(_, _, _, key) do
    _ = :persistent_term.get(key)
    :ok
  end
end

counters = :counters.new(3, [:write_concurrency])
atomics = :atomics.new(1, [])
tab = :ets.new(:x, [:public])
key = {CfgBench, 1}
:persistent_term.put(key, %{counters: counters, stop: atomics, tab: tab, a: 1, b: 2, c: 3})

cases = [
  {"config nil", &CfgBench.noop/4, nil},
  {"config small map (7 ints)", &CfgBench.noop/4, %{a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7}},
  {"config with ETS tid + counters + atomics refs", &CfgBench.noop/4,
   %{tab: tab, counters: counters, stop: atomics, a: 1, b: 2, c: 3}},
  {"config = small key, persistent_term lookup", &CfgBench.pt/4, key}
]

IO.puts("OTP #{System.otp_release()} (3 interleaved rounds, min of 7 each; concurrent = 12 procs wall-clock ns/event, min of 5)")
_ = CfgBench.run()  # warm-up

for round <- 1..3 do
  base = CfgBench.run()
  row = for {label, fun, cfg} <- cases do
    :telemetry.attach("cfg", [:cfg], fun, cfg)
    ns = CfgBench.run()
    :telemetry.detach("cfg")
    "#{label}: +#{round(ns - base)}"
  end
  IO.puts("round #{round} (base #{round(base)} ns): " <> Enum.join(row, " | "))
end

procs = System.schedulers_online()
cbase = CfgBench.concurrent(procs)
IO.puts("\nconcurrent, #{procs} procs, base #{Float.round(cbase, 1)} ns/event")
for {label, fun, cfg} <- cases do
  :telemetry.attach("cfg", [:cfg], fun, cfg)
  ns = CfgBench.concurrent(procs)
  :telemetry.detach("cfg")
  IO.puts("  " <> String.pad_trailing(label, 50) <> " #{Float.round(ns, 1)} ns (+#{Float.round(ns - cbase, 1)})")
end
