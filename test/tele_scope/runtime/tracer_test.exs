defmodule TeleScope.Runtime.TracerTest do
  # tracing is VM-global state
  use ExUnit.Case, async: false
  @moduletag :tracing
  @compile {:no_warn_undefined, :trace}

  alias TeleScope.Runtime.Tracer

  @caps Tracer.capabilities()

  defp start(opts) do
    {:ok, pid} = Tracer.start(Keyword.merge([duration: 10_000], opts))
    on_exit(fn -> if Process.alive?(pid), do: Tracer.stop(pid) end)
    pid
  end

  defp names(res), do: Enum.map(res.names, & &1.name)

  defp traced?(mfa) do
    case Tracer.capabilities().default_backend do
      :legacy ->
        match?({:traced, t} when t in [:local, :global], :erlang.trace_info(mfa, :traced))

      :session ->
        Enum.any?(:trace.session_info(:all), &match?({:tele_scope, _}, &1))
    end
  end

  test "discovers dynamic names, including spans, execute/2 and execute_lazy" do
    pid = start([])
    kind = Enum.random([:alpha, :beta])
    :telemetry.execute([:tr, :dyn, kind], %{}, %{})
    :telemetry.execute([:tr, :two], %{})
    :telemetry.span([:tr, :span], %{}, fn -> {:ok, %{}} end)

    if function_exported?(:telemetry, :execute_lazy, 3),
      do: :telemetry.execute_lazy([:tr, :lazy], :ok, fn -> {:ok, :ignore} end)

    res = Tracer.stop(pid)
    found = names(res)
    assert [:tr, :dyn, kind] in found
    assert [:tr, :two] in found
    assert [:tr, :span, :start] in found and [:tr, :span, :stop] in found

    if function_exported?(:telemetry, :execute_lazy, 3), do: assert([:tr, :lazy] in found)
    assert res.status == :stopped
    assert res.backend == @caps.default_backend
  end

  test "names emitted from other processes are discovered with process info" do
    pid = start([])
    Task.await(Task.async(fn -> :telemetry.execute([:tr, :task], %{}, %{}) end))
    res = Tracer.stop(pid)
    entry = Enum.find(res.names, &(&1.name == [:tr, :task]))
    assert entry
  end

  test "adaptive suppression: repeated names stop producing messages" do
    pid = start(suppress_debounce: 5)
    :telemetry.execute([:tr, :repeat], %{}, %{})
    Process.sleep(100)
    for _ <- 1..1_000, do: :telemetry.execute([:tr, :repeat], %{}, %{})
    res = Tracer.stop(pid)
    assert res.pattern_updates >= 1
    assert res.messages < 50
  end

  test "pre-known names are never reported" do
    pid = start(known: [[:tr, :known]])
    :telemetry.execute([:tr, :known], %{}, %{})
    :telemetry.execute([:tr, :unknown], %{}, %{})
    res = Tracer.stop(pid)
    refute [:tr, :known] in names(res)
    assert [:tr, :unknown] in names(res)
  end

  test "the match spec appends only the event name (no payload copy)" do
    ms = Tracer.match_spec(%{[:k] => true})
    big = %{blob: String.duplicate("x", 100_000)}
    assert {:ok, [:a, :b], [], []} = :erlang.match_spec_test([[:a, :b], %{}, big], ms, :trace)
    assert {:ok, false, [], []} = :erlang.match_spec_test([[:k], %{}, big], ms, :trace)
    # improper lists, non-lists and very long names produce no message
    assert {:ok, false, _, _} = :erlang.match_spec_test([[:a | :b], %{}, %{}], ms, :trace)
    assert {:ok, false, _, _} = :erlang.match_spec_test([:atom, %{}, %{}], ms, :trace)

    assert {:ok, false, _, _} =
             :erlang.match_spec_test([List.duplicate(:x, 17), %{}, %{}], ms, :trace)
  end

  test "invalid event names reaching execute are counted, not recorded" do
    pid = start([])
    # telemetry's execute/3 has no clause for these; tracing sees the call first
    for name <- [[1, 2], ["a"]] do
      try do
        :telemetry.execute(name, %{}, %{})
      rescue
        _ -> :ok
      end
    end

    res = Tracer.stop(pid)
    assert res.invalid_calls >= 1
    refute [1, 2] in names(res)
  end

  test "time limit stops tracing and cleans up" do
    pid = start(duration: 100)
    Process.sleep(250)
    res = Tracer.result(pid)
    assert res.status == :completed
    refute traced?({:telemetry, :execute, 3})
  end

  test "killing the tracer leaves no trace patterns behind" do
    pid = start([])
    assert traced?({:telemetry, :execute, 3})
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    Process.sleep(100)
    :erlang.garbage_collect()
    refute traced?({:telemetry, :execute, 3})
    assert :ok = :telemetry.execute([:tr, :after_kill], %{}, %{})
  end

  test "owner death stops tracing" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid} = Tracer.start(duration: 10_000)
        send(parent, {:tracer, pid})
        receive do: (:never -> :ok)
      end)

    assert_receive {:tracer, pid}
    ref = Process.monitor(pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}, 1_000
    Process.sleep(50)
    refute traced?({:telemetry, :execute, 3})
  end

  test "mailbox circuit breaker stops tracing under flood" do
    # no suppression + tiny mailbox limit + many emitters -> overload
    pid = start(suppress: false, max_mailbox: 50)

    1..20
    |> Enum.map(fn _ ->
      Task.async(fn -> for _ <- 1..5_000, do: :telemetry.execute([:tr, :flood], %{}, %{}) end)
    end)
    |> Enum.each(&Task.await(&1, 30_000))

    res = Tracer.stop(pid)
    assert res.status in [:overload, :max_messages]
    refute traced?({:telemetry, :execute, 3})
  end

  test "max_names cap" do
    pid = start(max_names: 5)
    for i <- 1..20, do: :telemetry.execute([:tr, :"n#{i}"], %{}, %{})
    Process.sleep(50)
    res = Tracer.stop(pid)
    assert length(res.names) == 5
    assert res.status == :max_names
  end

  test "option validation" do
    assert {:error, {:duration_too_long, _, _}} = Tracer.start(duration: 3_600_000)
    assert {:error, {:invalid_option, :duration}} = Tracer.start(duration: 0)
    assert {:error, {:invalid_option, {:backend, :bogus}}} = Tracer.start(backend: :bogus)
  end

  if @caps.sessions do
    test "trace sessions coexist with a legacy (dbg-style) tracer" do
      legacy = spawn(fn -> receive do: (:never -> :ok) end)
      :erlang.trace(self(), true, [:call, {:tracer, legacy}])
      :erlang.trace_pattern({:telemetry, :execute, 3}, true, [:global])

      pid = start(backend: :session)
      :telemetry.execute([:tr, :coexist], %{}, %{})
      res = Tracer.stop(pid)
      assert [:tr, :coexist] in names(res)
      # the other tool's pattern is untouched
      assert {:traced, :global} = :erlang.trace_info({:telemetry, :execute, 3}, :traced)
      :erlang.trace_pattern({:telemetry, :execute, 3}, false, [:global])
      :erlang.trace(self(), false, [:all])
    end
  else
    test "unsupported tracing capability: sessions on OTP < 27" do
      assert {:error, {:unsupported, :trace_sessions, _}} = Tracer.start(backend: :session)
    end

    test "legacy backend reports processes owned by another tracer" do
      other = spawn(fn -> receive do: (:never -> :ok) end)
      victim = spawn(fn -> receive do: (:never -> :ok) end)
      :erlang.trace(victim, true, [:call, {:tracer, other}])
      pid = start(backend: :legacy)
      res = Tracer.stop(pid)
      assert res.skipped_processes >= 1
      assert [_ | _] = res.warnings
      :erlang.trace(victim, false, [:all])
    end
  end
end
