# Pre-release audit reproductions. Each case prints REPRODUCED or NOT REPRODUCED.
#   MIX_ENV=test mix run test/audit/repro.exs
alias TeleScope.Runtime.{Capture, Tracer}
Logger.configure(level: :error)
{:ok, _} = Application.ensure_all_started(:telemetry)

report = fn id, reproduced?, detail ->
  IO.puts("#{id}: #{if reproduced?, do: "REPRODUCED", else: "not reproduced"} - #{detail}")
end

IO.puts("OTP #{System.otp_release()} backend=#{Tracer.capabilities().default_backend}\n")

# R1: two concurrent tracers. Stopping the first must not blind the second.
{:ok, t1} = Tracer.start(duration: 10_000)
r1_second = Tracer.start(duration: 10_000)

case r1_second do
  {:ok, t2} ->
    Tracer.stop(t1)
    :telemetry.execute([:r1, :after_first_stopped], %{}, %{})
    Process.sleep(50)
    names = Tracer.stop(t2).names |> Enum.map(& &1.name)

    report.(
      "R1 concurrent tracers",
      [:r1, :after_first_stopped] not in names,
      "second tracer saw #{inspect(names)} after the first stopped"
    )

  {:error, reason} ->
    Tracer.stop(t1)
    report.("R1 concurrent tracers", false, "second tracer refused: #{inspect(reason)}")
end

# R2: burst of ONE new name from many processes before the debounced
# suppression lands -> does the default breaker (10k) trip?
{:ok, t} = Tracer.start(duration: 10_000)
parent = self()

pids =
  for _ <- 1..System.schedulers_online() do
    spawn(fn ->
      receive do: (:go -> :ok)
      for _ <- 1..20_000, do: :telemetry.execute([:r2, :hot], %{}, %{})
      send(parent, :done)
    end)
  end

Enum.each(pids, &send(&1, :go))
for _ <- pids, do: receive(do: (:done -> :ok))
res = Tracer.stop(t)

report.(
  "R2 burst of one new hot name trips the breaker",
  res.status == :overload,
  "status=#{res.status} messages=#{res.messages} peak_mailbox=#{res.peak_mailbox} gate_closures=#{res[:gate_closures]} gated_ms=#{res[:gated_ms]}"
)

# R3: observer killed mid-capture -> can the capture still be stopped and merged?
{:ok, cap} = Capture.start(duration: 5_000, events: [[:r3, :e]], trace: false)
Process.exit(:sys.get_state(cap).observer, :kill)
Process.sleep(50)

r3 =
  try do
    result = Capture.stop(cap)
    _ = TeleScope.Catalog.add_capture(TeleScope.Catalog.new(), result)
    {:ok, inspect(result.observations, limit: 3)}
  rescue
    e -> {:crash, Exception.format_banner(:error, e)}
  catch
    kind, reason -> {:crash, "#{kind}: #{inspect(reason, limit: 5)}"}
  end

report.("R3 observer death mid-capture", match?({:crash, _}, r3), inspect(r3))

# R4: a new tracer-discovered name while the observer is dead crashes Capture?
{:ok, cap4} = Capture.start(duration: 5_000, events: [])
Process.exit(:sys.get_state(cap4).observer, :kill)
:telemetry.execute([:r4, :new, :name], %{}, %{})
Process.sleep(200)

report.(
  "R4 capture crashes on new name with dead observer",
  not Process.alive?(cap4),
  "capture alive? #{Process.alive?(cap4)}"
)

if Process.alive?(cap4), do: Capture.stop(cap4)

# R5: raise branch adds a spurious fully-dynamic alternative
dir = TeleScope.Test.Fixtures.tmp_dir("r5")

TeleScope.Test.Fixtures.compile_elixir(
  """
  defmodule R5 do
    def emit(kind) do
      event = case kind do
        :a -> [:r5, :a]
        _ -> raise ArgumentError, "bad kind"
      end
      :telemetry.execute(event, %{}, %{})
    end
  end
  """,
  dir
)

site = TeleScope.Test.Fixtures.scan([{:r5, dir}]).sites |> Enum.find(&(&1.kind == :execute))

report.(
  "R5 raise branch -> spurious dynamic pattern",
  [{:splice, :unknown}] in site.patterns,
  "patterns=#{inspect(site.patterns)}"
)

# R6: debug_info backend named inside an untrusted .beam is called blindly
defmodule R6.EvilBackend do
  def debug_info(_format, _module, _data, _opts) do
    send(:r6_probe, :backend_called)
    {:error, :evil}
  end
end

Process.register(self(), :r6_probe)
dir6 = TeleScope.Test.Fixtures.tmp_dir("r6")

[mod] =
  TeleScope.Test.Fixtures.compile_elixir(
    "defmodule R6.Victim do\n def a, do: :telemetry.execute([:x], %{}, %{})\nend",
    dir6
  )

path = Path.join(dir6, "#{mod}.beam")
{:ok, _, chunks} = :beam_lib.all_chunks(to_charlist(path))
evil = :erlang.term_to_binary({:debug_info_v1, R6.EvilBackend, :whatever})
chunks = List.keyreplace(chunks, ~c"Dbgi", 0, {~c"Dbgi", evil})
{:ok, bin} = :beam_lib.build_module(chunks)
File.write!(path, bin)
_ = TeleScope.Discovery.Beam.forms(path)
called = receive do: (:backend_called -> true), after: (100 -> false)

report.(
  "R6 arbitrary debug_info backend invoked",
  called,
  "Beam.forms called #{inspect(R6.EvilBackend)}.debug_info/4: #{called}"
)
