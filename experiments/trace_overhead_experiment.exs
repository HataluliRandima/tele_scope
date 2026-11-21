# Experiment B3: raw per-call overhead of call tracing :telemetry.execute/3.
#
# Measures ns/call for a tight loop of :telemetry.execute/3 under several
# tracing configurations, plus the tracer's peak mailbox length.
# Run: elixir experiments/trace_overhead_experiment.exs
Mix.install([{:telemetry, "~> 1.3"}])
Code.ensure_loaded!(:telemetry)

defmodule Bench do
  @n 200_000

  def loop(_name, _m, _md, 0), do: :ok
  def loop(name, m, md, n) do
    :telemetry.execute(name, m, md)
    loop(name, m, md, n - 1)
  end

  def measure(name, md) do
    m = %{duration: 1}
    loop(name, m, md, 1000) # warmup
    {us, _} = :timer.tc(fn -> loop(name, m, md, @n) end)
    us * 1000 / @n
  end

  # tracer that drains messages and records peak mailbox length via sampling
  def tracer do
    spawn(fn -> tloop(MapSet.new(), 0) end)
  end

  defp tloop(seen, count) do
    receive do
      {:stats, from} ->
        send(from, {:stats, MapSet.size(seen), count})
        tloop(seen, count)
      {:trace, _, :call, _, name} -> tloop(MapSet.put(seen, name), count + 1)
      {:trace, _, :call, {_, _, [name | _]}} -> tloop(MapSet.put(seen, name), count + 1)
      _ -> tloop(seen, count)
    end
  end

  def sampler(pid) do
    parent = self()
    spawn(fn -> sample(parent, pid, 0) end)
  end

  defp sample(parent, pid, peak) do
    receive do
      :stop -> send(parent, {:peak, peak})
    after
      1 ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, l} -> sample(parent, pid, max(peak, l))
          nil -> send(parent, {:peak, peak})
        end
    end
  end

  def run(label, md, setup) do
    t = tracer()
    cleanup = setup.(t)
    s = sampler(t)
    ns = measure([:bench, :event], md)
    send(s, :stop)
    peak = receive do {:peak, p} -> p end
    cleanup.()
    # wait for tracer to drain
    send(t, {:stats, self()})
    {names, count} = receive do {:stats, n, c} -> {n, c} after 30_000 -> {:timeout, :timeout} end
    Process.exit(t, :kill)
    IO.puts(String.pad_trailing(label, 58) <> " #{:erlang.float_to_binary(ns, decimals: 1)} ns/call  peak_mailbox=#{peak} msgs=#{count} names=#{names}")
    ns
  end
end

small = %{repo: :my_repo, source: "products", result: :ok}
big = %{payload: String.duplicate("x", 10_000), rows: Enum.to_list(1..500), repo: :my_repo}
ms_name = [{[:"$1", :_, :_], [], [{:message, :"$1"}]}]

legacy = fn flags, ms ->
  fn t ->
    :erlang.trace(self(), true, [:call, {:tracer, t} | flags])
    :erlang.trace_pattern({:telemetry, :execute, 3}, ms, [:local])
    fn ->
      :erlang.trace_pattern({:telemetry, :_, :_}, false, [:local])
      :erlang.trace(self(), false, [:all])
    end
  end
end

none = fn _t -> fn -> :ok end end

IO.puts("OTP #{System.otp_release()} / Elixir #{System.version()} / schedulers #{System.schedulers_online()}")
for {mdl, md} <- [{"small md", small}, {"large md", big}] do
  IO.puts("\n-- #{mdl} (flat_size=#{:erts_debug.flat_size(md)} words), 0 handlers --")
  Bench.run("baseline (no tracing)", md, none)
  Bench.run("trace, no arity, ms=true (full args)", md, legacy.([], true))
  Bench.run("trace, arity, ms {message,'$1'} (name only)", md, legacy.([:arity], ms_name))
  suppress = [{[[:bench, :event], :_, :_], [], [{:message, false}]} | ms_name]
  Bench.run("trace, arity, name suppressed (known)", md, legacy.([:arity], suppress))
  many = for i <- 1..200, do: {[[:other, String.to_atom("e#{i}")], :_, :_], [], [{:message, false}]}
  Bench.run("trace, arity, 200 suppress clauses, name NOT in list", md, legacy.([:arity], many ++ ms_name))
  Bench.run("trace, arity, 200 suppress clauses + known (last)", md, legacy.([:arity], many ++ suppress))
end

IO.puts("\n-- with one no-op handler attached --")
:telemetry.attach("noop", [:bench, :event], &__MODULE__.noop/4, nil) |> then(fn _ -> :ok end)
defmodule Noop do
  def handle(_, _, _, _), do: :ok
end
:telemetry.detach("noop")
:telemetry.attach("noop", [:bench, :event], &Noop.handle/4, nil)
Bench.run("baseline + 1 no-op handler", small, none)
:telemetry.detach("noop")
