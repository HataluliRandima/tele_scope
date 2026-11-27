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

    events = catalog |> Catalog.events() |> filter_apps(apps)

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

  @doc false
  # events of the given apps; events without a known app (only referenced,
  # or only seen at runtime) are always kept
  def filter_apps(events, nil), do: events

  def filter_apps(events, apps),
    do:
      Enum.filter(events, &(Enum.any?(&1.apps, fn a -> a in apps end) or &1.apps == MapSet.new()))

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
    {shown, hidden} = split_visible(diags, verbose)

    rows =
      Enum.map(shown, fn d ->
        "  [#{d.severity}] #{d.code} #{d.check}#{if d.limitation, do: " (limitation)"}: #{d.message}\n"
      end)

    note =
      if hidden != [],
        do: "  (#{length(hidden)} info diagnostics hidden; use --verbose)\n",
        else: ""

    ["Diagnostics (details: mix telemetry.check)\n", rows, note]
  end

  # errors, warnings and limitations are always shown; other info only when verbose
  defp split_visible(diags, true), do: {diags, []}

  defp split_visible(diags, _),
    do: Enum.split_with(diags, &(&1.severity != :info or &1.limitation))

  @doc """
  Renders the output of `mix telemetry.check`: one block per diagnostic
  (code, severity, event, problem, locations, suggestion) and a result line.

  `verdict` is the map returned by `TeleScope.Diagnostics.evaluate/2`.
  Options: `:verbose` (show every info diagnostic), `:catalog` (adds a
  one-line scan summary).
  """
  @spec render_check([TeleScope.Diagnostics.diagnostic()], map(), keyword()) :: String.t()
  def render_check(diagnostics, verdict, opts \\ []) do
    {shown, hidden} = split_visible(diagnostics, Keyword.get(opts, :verbose, false))
    failing = MapSet.new(verdict.failing)

    blocks =
      Enum.map(shown, fn d ->
        [check_block(d, MapSet.member?(failing, d)), "\n"]
      end)

    [
      case opts[:catalog] do
        nil -> []
        catalog -> [scope_line(catalog), "\n\n"]
      end,
      blocks,
      result_line(verdict, length(hidden)),
      "\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp check_block(d, failing?) do
    label = d.severity |> Atom.to_string() |> String.upcase()
    tags = Enum.reject([d.limitation && "limitation", failing? && "fails check"], &(!&1))
    tags = if tags == [], do: "", else: " (#{Enum.join(tags, ", ")})"

    [
      "[#{label}] #{d.code} #{d.title}#{tags}\n",
      if(d.event, do: field("Event", EventName.format(d.event)), else: []),
      field("Problem", d.message),
      case d.locations do
        [] -> []
        [first | rest] -> [field("Location", first), Enum.map(rest, &field("", &1))]
      end,
      if(d.suggestion, do: field("Suggestion", d.suggestion), else: [])
    ]
  end

  defp field(label, value) do
    label =
      if label == "", do: String.duplicate(" ", 12), else: String.pad_trailing(label <> ":", 12)

    ["  ", label, value, "\n"]
  end

  defp scope_line(catalog) do
    stats = (catalog.static || %{})[:stats] || %{}
    s = Catalog.summary(catalog)

    runtime =
      case catalog.runtime do
        nil ->
          "static analysis only (add --runtime to observe the running application)"

        rt ->
          "runtime capture of #{rt.duration_ms} ms, #{rt.observer[:total_events] || 0} events observed"
      end

    "TeleScope: #{s.events} events from #{stats[:beams] || 0} modules (#{stats[:decoded] || 0} analysed); #{runtime}"
  end

  defp result_line(verdict, hidden) do
    c = verdict.counts
    mode = if verdict.strict, do: "strict: errors and warnings fail", else: "errors fail"

    hidden_note = if hidden > 0, do: " (#{hidden} hidden; use --verbose)", else: ""

    "Result: #{verdict.status |> Atom.to_string() |> String.upcase()} (#{mode}): " <>
      "#{plural(c.error, "error")}, #{plural(c.warning, "warning")}, #{c.info} info#{hidden_note}"
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"
end
