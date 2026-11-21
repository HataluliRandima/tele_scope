# TeleScope real-app validation hook. Required at the end of test/test_helper.exs.
# Ground truth = names seen by the tracer with nothing pre-suppressed (known: [])
# plus names the observer saw, while the app's own test suite runs.
alias TeleScope.{Catalog, Event, EventName}
out = System.fetch_env!("TELESCOPE_OUT")
File.mkdir_p!(out)
{scan_us, static} = :timer.tc(fn -> TeleScope.scan() end)

predicted =
  for e <- Catalog.events(static), Event.emitter_known?(e), into: MapSet.new(), do: e.name

{:ok, cap} =
  TeleScope.start_capture(static,
    duration: 3_600_000,
    tracer: [known: [], allow_long: true, max_names: 5_000, max_messages: 10_000_000],
    observer: [max_events: 100_000_000]
  )

ExUnit.after_suite(fn _ ->
  r = TeleScope.Runtime.Capture.stop(cap)
  cat = Catalog.add_capture(static, r)

  fired =
    (Enum.map(r.trace.names, & &1.name) ++ Map.keys(r.observations.events))
    |> MapSet.new()
    |> MapSet.delete([:telemetry, :handler, :failure])

  missed = MapSet.difference(fired, predicted) |> Enum.sort()
  specific = Catalog.specific_patterns(static)
  trace_by_name = Map.new(r.trace.names, &{&1.name, &1})

  missed_detail =
    for name <- missed do
      t = trace_by_name[name]

      %{
        name: EventName.dotted(name),
        matches_specific_partial:
          specific |> Enum.filter(&EventName.matches?(&1.pattern, name)) |> Enum.map(&EventName.format(&1.pattern)),
        process: t && inspect(t.process)
      }
    end

  diags = TeleScope.diagnose(cat)

  summary = %{
    app: System.get_env("TELESCOPE_APP"),
    otp: System.otp_release(),
    elixir: System.version(),
    static_scan_ms: div(scan_us, 1000),
    static_stats: static.static.stats,
    predicted: MapSet.size(predicted),
    fired: MapSet.size(fired),
    fired_and_predicted: MapSet.size(MapSet.intersection(fired, predicted)),
    recall_percent: Float.round(MapSet.size(MapSet.intersection(fired, predicted)) * 100 / max(MapSet.size(fired), 1), 1),
    missed: missed_detail,
    tracer: Map.drop(r.trace, [:names]),
    observer: Map.take(r.observations, [:status, :total_events, :dropped_events, :callback_errors, :ets_rows, :ets_memory_bytes]),
    diagnostics_by_severity: Enum.frequencies_by(diags, & &1.severity),
    non_info_diagnostics: for(d <- diags, d.severity != :info, do: "[#{d.severity}] #{d.check}: #{d.message}")
  }

  File.write!(Path.join(out, "summary.exs"), inspect(summary, pretty: true, limit: :infinity, printable_limit: :infinity))
  File.write!(Path.join(out, "report.txt"), TeleScope.report(cat, format: :console, verbose: true, diagnostics: diags))
  File.write!(Path.join(out, "report.json"), TeleScope.report(cat, format: :json, diagnostics: diags))
  IO.puts("\n[telescope] fired=#{summary.fired} predicted_hit=#{summary.fired_and_predicted} recall=#{summary.recall_percent}% tracer=#{r.trace.status} gated_ms=#{r.trace.gated_ms} peak_mailbox=#{r.trace.peak_mailbox}")
end)
