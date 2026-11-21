# Runtime overhead of TeleScope instrumentation, measured on the real library code.
#
#   mix run bench/runtime_overhead.exs            (from the repo root)
#
# Methodology
#   * tight loop of :telemetry.execute/3 in one process (N calls), minimum of R runs
#   * concurrent variant: P processes, same event (worst-case ETS row contention)
#   * every configuration is measured relative to the same-run baseline
#   * metadata "small" = 4 keys (typical); "large" = 30 keys incl. a struct and
#     a 10 KB binary (Phoenix/Ecto-like)
alias TeleScope.Runtime.{Observer, Tracer, Handlers}

defmodule Bench do
  @n String.to_integer(System.get_env("BENCH_N", "200000"))
  @runs String.to_integer(System.get_env("BENCH_RUNS", "7"))

  def n, do: @n

  def loop(_e, _m, _md, 0), do: :ok

  def loop(e, m, md, k) do
    :telemetry.execute(e, m, md)
    loop(e, m, md, k - 1)
  end

  def once(event, md, n \\ @n) do
    m = %{duration: 1000, count: 1}
    loop(event, m, md, 2_000)
    {us, _} = :timer.tc(fn -> loop(event, m, md, n) end)
    us * 1000 / n
  end

  def median(event, md), do: median_of(fn -> once(event, md) end)

  # minimum of R runs: on a shared/noisy machine (WSL2 here) the minimum is
  # the most reproducible estimate of the intrinsic cost (see BENCHMARKS.md)
  # Returns min / median / max of R runs. The minimum is the most reproducible
  # estimate of intrinsic cost on a noisy machine, but it is a best case: the
  # median is reported next to it (pre-release audit: reporting only the
  # minimum understated typical overhead).
  def median_of(fun) do
    runs = 1..@runs |> Enum.map(fn _ -> fun.() end) |> Enum.sort()
    %{min: hd(runs), med: Enum.at(runs, div(@runs, 2)), max: List.last(runs)}
  end

  def concurrent(event, md, procs) do
    per = div(@n, procs)

    median_of(fn ->
      parent = self()
      m = %{duration: 1000, count: 1}

      {us, _} =
        :timer.tc(fn ->
          pids =
            for _ <- 1..procs do
              spawn_link(fn ->
                receive do: (:go -> :ok)
                loop(event, m, md, per)
                send(parent, :done)
              end)
            end

          Enum.each(pids, &send(&1, :go))
          for _ <- pids, do: receive(do: (:done -> :ok))
        end)

      # wall-clock ns per event across all processes
      us * 1000 / (per * procs)
    end)
  end

  def handle(_, _, _, _), do: :ok

  def row(label, ns, base) do
    f = &:erlang.float_to_binary(&1 * 1.0, decimals: 0)

    IO.puts(
      String.pad_trailing(label, 60) <>
        " min #{String.pad_leading(f.(ns.min), 6)} (+#{String.pad_leading(f.(ns.min - base.min), 5)})" <>
        "  median #{String.pad_leading(f.(ns.med), 6)} (+#{String.pad_leading(f.(ns.med - base.med), 5)})" <>
        "  max #{String.pad_leading(f.(ns.max), 6)} ns"
    )
  end
end

defmodule BenchStruct do
  defstruct [:a, :b, :c]
end

small = %{repo: :my_repo, source: "products", result: :ok, user_id: 42}

large =
  Map.new(1..27, &{:"key_#{&1}", &1})
  |> Map.merge(%{
    conn: struct(BenchStruct, a: 1),
    blob: String.duplicate("x", 10_000),
    list: Enum.to_list(1..100)
  })

ev = [:bench, :event]

IO.puts(
  "OTP #{System.otp_release()} / Elixir #{System.version()} / schedulers #{System.schedulers_online()} / N=#{Bench.n()}"
)

IO.puts("tracing backend: #{Tracer.capabilities().default_backend}\n")

for {label, md} <- [
      {"small metadata (4 keys)", small},
      {"large metadata (30 keys, struct, 10KB binary)", large}
    ] do
  IO.puts("== #{label}, single process")
  base = Bench.median(ev, md)
  Bench.row("baseline: no handlers", base, base)

  :telemetry.attach("noop", ev, &Bench.handle/4, nil)
  Bench.row("reference: one no-op handler", Bench.median(ev, md), base)
  :telemetry.detach("noop")

  {:ok, obs} = Observer.start(events: [ev], duration: :infinity, max_events: 100_000_000)
  Bench.row("observer (shape recording)", Bench.median(ev, md), base)
  Observer.stop(obs)

  {:ok, obs} =
    Observer.start(events: [ev], duration: :infinity, sample_rate: 0.1, max_events: 100_000_000)

  Bench.row("observer, sample_rate 0.1", Bench.median(ev, md), base)
  Observer.stop(obs)

  {:ok, obs} = Observer.start(events: [ev], duration: :infinity, max_events: 1)
  Bench.row("observer after max_events reached (no-op path)", Bench.median(ev, md), base)
  Observer.stop(obs)

  {:ok, tr} = Tracer.start(duration: 600_000, known: [ev])
  Bench.row("tracer, name pre-suppressed (known)", Bench.median(ev, md), base)
  Tracer.stop(tr)

  {:ok, tr} = Tracer.start(duration: 600_000, known: Enum.map(1..5_000, &[:other, :"e#{&1}"]))
  Bench.once(ev, md, 10)
  Process.sleep(100)
  Bench.row("tracer, discovered then suppressed (5,000 known names)", Bench.median(ev, md), base)
  Tracer.stop(tr)

  {:ok, tr} =
    Tracer.start(
      duration: 600_000,
      suppress: false,
      max_messages: 100_000_000,
      max_mailbox: 100_000_000
    )

  Bench.row(
    "tracer WITHOUT suppression (worst case, every call sends)",
    Bench.median(ev, md),
    base
  )

  res = Tracer.stop(tr)
  IO.puts("    -> tracer peak mailbox #{res.peak_mailbox}, messages #{res.messages}")

  :telemetry.attach("noop", ev, &Bench.handle/4, nil)
  t = Handlers.track(Handlers.list())
  Bench.row("one no-op handler + call_count invocation tracking", Bench.median(ev, md), base)
  Handlers.stop_tracking(t)
  :telemetry.detach("noop")

  {:ok, obs} = Observer.start(events: [ev], duration: :infinity, max_events: 100_000_000)
  {:ok, tr} = Tracer.start(duration: 600_000, known: [ev])
  Bench.row("full capture: observer + tracer (known name)", Bench.median(ev, md), base)
  Tracer.stop(tr)
  Observer.stop(obs)
  IO.puts("")
end

procs = System.schedulers_online()
IO.puts("== concurrency: #{procs} processes, same event (ETS row contention), small metadata")
base = Bench.concurrent(ev, small, procs)
Bench.row("baseline: no handlers", base, base)
:telemetry.attach("noop", ev, &Bench.handle/4, nil)
Bench.row("reference: one no-op handler", Bench.concurrent(ev, small, procs), base)
:telemetry.detach("noop")
{:ok, obs} = Observer.start(events: [ev], duration: :infinity, max_events: 100_000_000)
Bench.row("observer (per-scheduler striped rows)", Bench.concurrent(ev, small, procs), base)
Observer.stop(obs)
{:ok, tr} = Tracer.start(duration: 600_000, known: [ev])
Bench.row("tracer, name pre-suppressed", Bench.concurrent(ev, small, procs), base)
Tracer.stop(tr)

IO.puts("\n== memory")

{:ok, obs} =
  Observer.start(
    events: [ev] ++ Enum.map(1..200, &[:mem, :"e#{&1}"]),
    duration: :infinity,
    max_events: 100_000_000
  )

for i <- 1..200, k <- 1..5, do: :telemetry.execute([:mem, :"e#{i}"], %{:"m#{k}" => 1}, small)
snap = Observer.snapshot(obs)

IO.puts(
  "observer ETS after 200 events x 5 shapes: #{snap.ets_memory_bytes} bytes (#{Float.round(snap.ets_memory_bytes / 1000, 1)} KB)"
)

for _ <- 1..100_000, do: :telemetry.execute(ev, %{n: 1}, large)
snap2 = Observer.snapshot(obs)

IO.puts(
  "after +100,000 events of an existing shape: #{snap2.ets_memory_bytes} bytes (growth #{snap2.ets_memory_bytes - snap.ets_memory_bytes})"
)

Observer.stop(obs)
