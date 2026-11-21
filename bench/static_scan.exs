# Static scanning time and memory.
#
#   cd spike/demo_app && mix run --no-start ../../bench/static_scan.exs
#
# 1. the Phoenix spike app (_build/dev: app + all deps), R runs
# 2. stress: every ebin of the installed OTP + Elixir (thousands of modules,
#    almost none call telemetry -> measures the prefilter/index cost)
# Peak memory is sampled every 2 ms from a separate process (:erlang.memory(:total)).
alias TeleScope.Discovery.Scanner

defmodule ScanBench do
  def peak(fun) do
    parent = self()
    base = :erlang.memory(:total)
    sampler = spawn_link(fn -> sample(parent, base) end)
    {us, result} = :timer.tc(fun)
    send(sampler, :stop)
    peak = receive do: ({:peak, p} -> p)
    {us, result, peak - base}
  end

  defp sample(parent, peak) do
    receive do
      :stop -> send(parent, {:peak, peak})
    after
      2 -> sample(parent, max(peak, :erlang.memory(:total)))
    end
  end

  def report(label, dirs, runs) do
    :erlang.garbage_collect()

    rows =
      for _ <- 1..runs do
        {us, r, peak} = peak(fn -> Scanner.scan(dirs) end)
        {div(us, 1000), r, peak}
      end

    {_, r, _} = hd(rows)
    times = Enum.map(rows, &elem(&1, 0)) |> Enum.sort()
    peaks = Enum.map(rows, &elem(&1, 2))

    IO.puts("""
    == #{label}
       beams=#{r.stats.beams} candidates=#{r.stats.candidates} decoded=#{r.stats.decoded} analyzed=#{r.stats.analyzed_modules} wrapper_rounds=#{r.stats.wrapper_rounds} no_debug_info=#{length(r.no_debug_info)} errors=#{length(r.errors)}
       wall ms: min=#{hd(times)} median=#{Enum.at(times, div(runs, 2))} max=#{List.last(times)}  (index #{r.stats.index_ms} ms / analyze #{r.stats.analyze_ms} ms in run 1)
       peak extra memory: #{Float.round(Enum.max(peaks) / 1_048_576, 1)} MB
    """)
  end
end

IO.puts(
  "OTP #{System.otp_release()} / Elixir #{System.version()} / schedulers #{System.schedulers_online()}\n"
)

app_dirs = Scanner.mix_app_dirs() |> Enum.reject(&(elem(&1, 0) == :tele_scope))
ScanBench.report("Phoenix spike app (#{length(app_dirs)} apps)", app_dirs, 5)

otp_dirs =
  for dir <-
        Path.wildcard(Path.join(:code.root_dir(), "lib/*/ebin")) ++
          Path.wildcard(Path.join([Path.dirname(Path.dirname(:code.lib_dir(:elixir))), "*/ebin"])),
      do: {dir |> Path.dirname() |> Path.basename() |> String.to_atom(), dir}

ScanBench.report(
  "stress: OTP + Elixir installation (#{length(otp_dirs)} apps)",
  Enum.uniq(otp_dirs),
  3
)
