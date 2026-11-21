# Experiment B4: can a match spec do O(1) set membership for suppression?
# Uses guard is_map_key('$1', {const, KnownMap}) — verifies support + cost vs set size.
Mix.install([{:telemetry, "~> 1.3"}])
Code.ensure_loaded!(:telemetry)
Code.require_file("trace_overhead_experiment_lib.exs", __DIR__)
small = %{repo: :my_repo, source: "products", result: :ok}
legacy = fn ms ->
  fn t ->
    :erlang.trace(self(), true, [:call, :arity, {:tracer, t}])
    r = :erlang.trace_pattern({:telemetry, :execute, 3}, ms, [:local])
    if r != 1, do: IO.puts("   trace_pattern returned #{inspect(r)}")
    fn ->
      :erlang.trace_pattern({:telemetry, :_, :_}, false, [:local])
      :erlang.trace(self(), false, [:all])
    end
  end
end
mk = fn known ->
  [{[:"$1", :_, :_], [{:not, {:is_map_key, :"$1", {:const, known}}}], [{:message, :"$1"}]}]
end
IO.puts("OTP #{System.otp_release()}")
# validate ms compiles
IO.inspect(:erlang.match_spec_test([[:a], %{}, %{}], mk.(%{[:a] => true}), :trace), label: "match_spec_test known")
IO.inspect(:erlang.match_spec_test([[:b], %{}, %{}], mk.(%{[:a] => true}), :trace), label: "match_spec_test unknown")
Bench.run("baseline", small, fn _ -> fn -> :ok end end)
for size <- [0, 1, 10, 100, 1000, 10_000] do
  others = Map.new(1..size//1, fn i -> {[:other, :"e#{i}"], true} end)
  Bench.run("map guard, #{size} known, name NOT known", small, legacy.(mk.(others)))
  Bench.run("map guard, #{size + 1} known, name known (suppressed)", small, legacy.(mk.(Map.put(others, [:bench, :event], true))))
end
