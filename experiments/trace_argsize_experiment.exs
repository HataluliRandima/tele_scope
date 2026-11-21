# Experiment B5: does the cost of a *suppressed* call-trace breakpoint depend on
# the size/shape of the (unused) measurement/metadata arguments?
#   mix run experiments/trace_argsize_experiment.exs
defmodule ArgBench do
  def loop(_e, _m, _md, 0), do: :ok
  def loop(e, m, md, k), do: (:telemetry.execute(e, m, md); loop(e, m, md, k - 1))
  def run(md, n \\ 200_000) do
    loop([:b], %{}, md, 1_000)
    runs = for _ <- 1..5, do: elem(:timer.tc(fn -> loop([:b], %{}, md, n) end), 0) * 1000 / n
    runs |> Enum.sort() |> Enum.at(2)
  end
end

cases = [
  {"empty map", %{}},
  {"4 keys", %{a: 1, b: "x", c: :ok, d: 4}},
  {"30 small int keys", Map.new(1..30, &{:"k#{&1}", &1})},
  {"40 keys (HAMT)", Map.new(1..40, &{:"k#{&1}", &1})},
  {"10KB binary", %{blob: String.duplicate("x", 10_000)}},
  {"100-element list", %{list: Enum.to_list(1..100)}},
  {"1000-element list", %{list: Enum.to_list(1..1000)}}
]

IO.puts("OTP #{System.otp_release()} backend=#{TeleScope.Runtime.Tracer.capabilities().default_backend}")
IO.puts(String.pad_trailing("metadata", 22) <> "  no-trace   suppressed   delta")
for {label, md} <- cases do
  base = ArgBench.run(md)
  {:ok, t} = TeleScope.Runtime.Tracer.start(duration: 600_000, known: [[:b]])
  traced = ArgBench.run(md)
  TeleScope.Runtime.Tracer.stop(t)
  IO.puts(String.pad_trailing(label, 22) <> "  #{String.pad_leading("#{round(base)}", 6)} ns  #{String.pad_leading("#{round(traced)}", 7)} ns  +#{round(traced - base)} ns")
end
