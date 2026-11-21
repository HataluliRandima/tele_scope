defmodule TeleScope.Reporters.Console do
  @moduledoc "Human-readable text report."

  alias TeleScope.{Catalog, Event, EventName}
  alias TeleScope.Discovery.CallSite
  alias TeleScope.Runtime.Shape

  def render(%Catalog{} = catalog, opts \\ []) do
    diagnostics =
      Keyword.get_lazy(opts, :diagnostics, fn -> TeleScope.Diagnostics.run(catalog) end)

    verbose = Keyword.get(opts, :verbose, false)
    apps = Keyword.get(opts, :apps)

    events =
      catalog
      |> Catalog.events()
      |> Enum.filter(fn e ->
        apps == nil or Enum.any?(e.apps, &(&1 in apps)) or e.apps == MapSet.new()
      end)

    [
      header(catalog),
      "\n",
      events_section(events, verbose),
      "\n",
      patterns_section(catalog),
      "\n",
      diagnostics_section(diagnostics, verbose),
      if(metrics = opts[:metrics], do: ["\n", TeleScope.Metrics.to_code(metrics)], else: [])
    ]
    |> IO.iodata_to_binary()
  end

  defp header(catalog) do
    s = Catalog.summary(catalog)
    stats = (catalog.static || %{})[:stats] || %{}

    runtime =
      case catalog.runtime do
        nil ->
          "runtime: not captured (static discovery only; nothing is known about which events fire)"

        rt ->
          trace =
            case rt.trace do
              nil ->
                "tracing off"

              t ->
                "tracer #{t.backend} #{t.status}, #{t.messages} msgs, peak mailbox #{t.peak_mailbox}"
            end

          "runtime: #{rt.duration_ms}ms capture, #{rt.observer.total_events} events observed, #{trace}"
      end

    """
    TeleScope report
    ================
    static:  #{stats[:beams] || 0} beams indexed, #{stats[:decoded] || 0} decoded, #{stats[:total_ms] || 0}ms
    #{runtime}
    events:  #{s.events} #{inspect(s.by_status)}
    confidence: #{inspect(s.by_confidence)}
    unresolved call-site patterns: #{s.unresolved_patterns} of #{s.patterns}
    """
  end

  defp events_section(events, verbose) do
    rows =
      Enum.map(events, fn e ->
        handlers = length(e.handlers)

        line =
          String.pad_trailing(EventName.dotted(e.name), 52) <>
            String.pad_trailing(to_string(Event.status(e)), 16) <>
            String.pad_trailing(to_string(Event.confidence(e)), 12) <>
            String.pad_trailing(if(e.observed, do: Integer.to_string(e.count), else: "-"), 8) <>
            "handlers=#{handlers}"

        if verbose, do: [line, "\n", details(e)], else: [line, "\n"]
      end)

    [
      "EVENT" |> String.pad_trailing(52),
      "STATUS" |> String.pad_trailing(16),
      "CONFIDENCE" |> String.pad_trailing(12),
      "COUNT" |> String.pad_trailing(8),
      "\n",
      rows
    ]
  end

  defp details(e) do
    sites =
      e.call_sites
      |> Enum.take(3)
      |> Enum.map(&"    at #{CallSite.location(&1)} (#{inspect(&1.via)})\n")

    shapes =
      for {section, stats} <- [measurements: e.measurements, metadata: e.metadata],
          stats != %{} do
        keys =
          Enum.map_join(stats, ", ", fn {k, s} ->
            types = s.types |> Map.keys() |> Enum.map_join("|", &Shape.format_type/1)
            pct = if s.presence < 1.0, do: " #{round(s.presence * 100)}%", else: ""
            "#{k}: #{types}#{pct}"
          end)

        "    #{section}: #{keys}\n"
      end

    handlers =
      Enum.map(e.handlers, fn h ->
        shared =
          if h.invocations_shared_with != [],
            do: " (function shared with #{inspect(h.invocations_shared_with)}; not attributable)",
            else: ""

        "    handler #{inspect(h.id)} invocations=#{inspect(h.invocations)}#{shared}\n"
      end)

    reasons = Enum.map(e.rule_reasons, &"    rule: #{&1.reason}\n")
    [sites, reasons, shapes, handlers]
  end

  defp patterns_section(catalog) do
    pats = catalog.patterns |> Map.values() |> Enum.sort_by(&EventName.format(&1.pattern))

    rows =
      Enum.map(pats, fn p ->
        matched =
          case p.matched do
            [] -> "UNRESOLVED"
            m -> "matches #{length(m)} name(s)"
          end

        site = p.call_sites |> List.first() |> CallSite.location()

        "  #{String.pad_trailing(EventName.format(p.pattern), 40)} #{String.pad_trailing(to_string(p.classification), 9)} #{String.pad_trailing(matched, 22)} #{site}\n"
      end)

    ["Non-literal call sites (", Integer.to_string(length(pats)), ")\n", rows]
  end

  defp diagnostics_section(diags, verbose) do
    {shown, hidden} =
      if verbose, do: {diags, []}, else: Enum.split_with(diags, &(&1.severity != :info))

    rows = Enum.map(shown, &"  [#{&1.severity}] #{&1.check}: #{&1.message}\n")

    note =
      if hidden != [],
        do: "  (#{length(hidden)} info diagnostics hidden; use --verbose)\n",
        else: ""

    ["Diagnostics\n", rows, note]
  end
end
