# TeleScope engineering spike runner.
#
#   cd spike/demo_app && mix run --no-start priv/spike/run_spike.exs [results_dir]
#
# 1. static scan of _build/dev (app + all deps)
# 2. runtime capture started BEFORE the application boots (startup events)
#    - tracer in ground-truth mode (known: []): every name that fires is recorded
#    - observer attached to all statically known names + names found by tracer
# 3. realistic workload: HTTP via Finch -> Bandit -> Phoenix -> Ecto, Oban jobs,
#    custom instrumentation, an Erlang module
# 4. coverage = how many of the names that actually fired were predicted statically
alias TeleScope.{Catalog, Event, EventName}

results_dir = List.first(System.argv()) || Path.expand("../../../results", __DIR__)
File.mkdir_p!(results_dir)
Logger.configure(level: :warning)

Mix.Task.run("app.config")
{:ok, _} = Application.ensure_all_started(:telemetry)

{static_us, static} = :timer.tc(fn -> TeleScope.scan() end)
IO.puts("static scan: #{div(static_us, 1000)}ms, #{inspect(Catalog.summary(static))}")

predicted =
  for e <- Catalog.events(static), Event.emitter_known?(e), into: MapSet.new(), do: e.name

{:ok, cap} =
  TeleScope.start_capture(static,
    duration: 20_000,
    tracer: [known: []],
    observer: [max_events: 2_000_000]
  )

# boot the app with an HTTP listener
port = 4123
endpoint_conf = Application.get_env(:demo_app, DemoAppWeb.Endpoint, [])

Application.put_env(
  :demo_app,
  DemoAppWeb.Endpoint,
  Keyword.merge(endpoint_conf, server: true, http: [ip: {127, 0, 0, 1}, port: port])
)

{:ok, _} = Application.ensure_all_started(:demo_app)
DemoApp.Repo.query!("DELETE FROM products")
for i <- 1..5, do: DemoApp.Repo.query!("INSERT INTO products (name) VALUES (?)", ["p#{i}"])

get = fn path ->
  Finch.build(:get, "http://127.0.0.1:#{port}#{path}") |> Finch.request(DemoApp.Finch)
end

for _ <- 1..20, do: {:ok, %{status: 200}} = get.("/api/products")
for _ <- 1..3, do: {:ok, %{status: 200}} = get.("/")
# dev mode (debug_errors) may close the connection after an exception
for _ <- 1..2, do: _ = get.("/api/boom")

alias DemoApp.Instrumentation.Orders

for id <- 1..10, do: Orders.create(id)
for id <- 1..6, do: Orders.cancel(id)
Orders.settle(1, true)
Orders.settle(2, false)
for op <- [:hit, :miss, :evict, :hit], do: Orders.cache(op)
Orders.cache_from_string("hit")
Orders.search("abc")
Orders.dynamic("alpha")
Orders.dynamic("beta")
Orders.capture_payment(1)
for id <- 1..3, do: Orders.checkout(id)

for id <- 1..6 do
  try do
    Orders.fulfil(id)
  rescue
    _ -> :ok
  end
end

Orders.lazy(1)
:demo_erl_telemetry.tick(1)
:demo_erl_telemetry.work(2)

for id <- 1..5, do: Oban.insert!(DemoApp.Workers.OrderWorker.new(%{id: id}))

wait = fn wait ->
  %{rows: [[n]]} =
    DemoApp.Repo.query!("SELECT count(*) FROM oban_jobs WHERE state NOT IN ('completed','discarded')")

  if n > 0, do: (Process.sleep(100); wait.(wait)), else: :ok
end

wait.(wait)
Process.sleep(500)

capture = TeleScope.Runtime.Capture.stop(cap)
catalog = Catalog.add_capture(static, capture)

# ---- coverage ---------------------------------------------------------------
fired =
  (Enum.map(capture.trace.names, & &1.name) ++ Map.keys(capture.observations.events))
  |> MapSet.new()
  |> MapSet.delete([:telemetry, :handler, :failure])

hit = MapSet.intersection(fired, predicted)
missed = MapSet.difference(fired, predicted) |> Enum.sort()

# only *specific* partial patterns count (not fully dynamic [**] and not
# generic wrapper templates such as [:demo_app, **])
specific = Catalog.specific_patterns(static)

partial_explained =
  Enum.filter(missed, fn name -> Enum.any?(specific, &EventName.matches?(&1.pattern, name)) end)

by_source = fn names ->
  names
  |> Enum.group_by(fn n ->
    e = Catalog.get(static, n)

    cond do
      MapSet.member?(e.sources, :static_literal) -> :static_literal
      MapSet.member?(e.sources, :static_resolved) -> :static_resolved
      MapSet.member?(e.sources, :config_rule) -> :config_rule
      true -> :other
    end
  end)
  |> Map.new(fn {k, v} -> {k, length(v)} end)
end

coverage = %{
  otp: System.otp_release(),
  elixir: System.version(),
  static_scan_ms: div(static_us, 1000),
  static_summary: Catalog.summary(static),
  predicted_emittable_names: MapSet.size(predicted),
  fired_names: MapSet.size(fired),
  fired_and_predicted: MapSet.size(hit),
  recall_percent: Float.round(MapSet.size(hit) * 100 / max(MapSet.size(fired), 1), 1),
  fired_predicted_by_source: by_source.(MapSet.to_list(hit)),
  fired_not_predicted: Enum.map(missed, &EventName.dotted/1),
  fired_not_predicted_but_matching_partial_pattern: Enum.map(partial_explained, &EventName.dotted/1),
  predicted_but_not_fired: MapSet.size(MapSet.difference(predicted, fired)),
  tracer: Map.drop(capture.trace, [:names]),
  observer: Map.drop(capture.observations, [:events, :attached_events])
}

IO.inspect(coverage, label: "coverage", limit: :infinity, pretty: true)

diags = TeleScope.diagnose(catalog)
metrics = TeleScope.recommend_metrics(catalog)

File.write!(Path.join(results_dir, "spike_coverage_otp#{System.otp_release()}.exs"), inspect(coverage, pretty: true, limit: :infinity))

File.write!(
  Path.join(results_dir, "spike_report_otp#{System.otp_release()}.txt"),
  TeleScope.report(catalog, format: :console, verbose: true, diagnostics: diags, metrics: metrics)
)

File.write!(
  Path.join(results_dir, "spike_report_otp#{System.otp_release()}.json"),
  TeleScope.report(catalog, format: :json, diagnostics: diags, metrics: metrics)
)

IO.puts("\nDiagnostics (non-info):")
for d <- diags, d.severity != :info, do: IO.puts("  [#{d.severity}] #{d.check}: #{d.message}")
IO.puts("\nreports written to #{results_dir}")
