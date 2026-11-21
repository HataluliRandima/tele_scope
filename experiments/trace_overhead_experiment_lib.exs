# shared helpers for trace overhead experiments
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

