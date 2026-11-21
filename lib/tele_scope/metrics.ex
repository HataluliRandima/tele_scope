defmodule TeleScope.Metrics do
  @moduledoc """
  `Telemetry.Metrics` suggestions derived from the catalog.

  Principles:

    * Suggestions, not truth: every recommendation carries a `reason` and a
      `confidence`; generated code is prefixed with a review banner.
    * Fewer, better metrics: a metric per measurement is *not* generated.
      Span `:start` events produce nothing (the `:stop` event carries the
      duration); exceptions produce a counter; standalone events produce a
      counter unless a measurement is clearly a duration or a gauge.
    * Units: `duration` and `*_time` measurements on telemetry spans are in
      `:native` time units (`:telemetry.span/3` uses `System.monotonic_time/0`),
      so `unit: {:native, :millisecond}` is suggested and flagged for review
      when the event is not a `:telemetry.span/3` span.
    * Tags: only metadata keys that were *observed* on 100% of events with a
      low-cardinality type (atom, module, boolean). Binaries/integers may be
      high-cardinality (ids, paths) and are listed as rejected candidates.
    * Existing `Telemetry.Metrics` definitions found statically are not
      suggested again.

  Confidence:
    * `:high` - measurement observed at runtime with a numeric type
    * `:medium` - guaranteed by the `:telemetry.span/3` contract
    * `:low` - naming convention only, not verified
  """

  alias TeleScope.{Catalog, Event, EventName}

  @tag_types [:atom, :module, :boolean]
  @skip_events [[:telemetry, :handler, :failure]]

  @doc "Returns a list of recommendation maps."
  def recommend(%Catalog{} = catalog, opts \\ []) do
    # With runtime data, only recommend for what actually fired: a metric for
    # an event that never fires is noise. Static-only catalogs get everything
    # (with lower confidence) unless told otherwise.
    include_unobserved = Keyword.get(opts, :include_unobserved, catalog.runtime == nil)
    apps = Keyword.get(opts, :apps)
    events = Catalog.events(catalog)

    # a span counts as observed if any of its events fired, so the exception
    # counter is still suggested for spans that never failed during capture
    observed_spans =
      for %Event{span: %{prefix: p}, observed: true} <- events, into: MapSet.new(), do: p

    events
    |> Enum.filter(&Event.emitter_known?/1)
    |> Enum.reject(&(&1.name in @skip_events))
    |> Enum.filter(&(apps == nil or Enum.any?(&1.apps, fn a -> a in apps end)))
    |> Enum.filter(fn e ->
      include_unobserved or e.observed == true or
        (e.span != nil and MapSet.member?(observed_spans, e.span.prefix))
    end)
    |> Enum.flat_map(&for_event/1)
    |> Enum.reject(& &1.already_defined)
  end

  defp for_event(%Event{span: %{role: :start}}), do: []

  defp for_event(%Event{span: %{role: :exception}} = e) do
    [
      rec(e, :counter, :count, nil,
        reason: "exception event of span #{EventName.format(e.span.prefix)}: count failures",
        confidence: if(e.observed, do: :high, else: :medium)
      )
    ]
  end

  defp for_event(%Event{span: %{role: :stop}} = e) do
    span_call? = span_call?(e)

    {has_duration, conf, why} =
      cond do
        observed_numeric?(e, :duration) ->
          {true, :high, "duration observed at runtime"}

        span_call? ->
          {true, :medium, ":telemetry.span/3 always measures :duration on :stop"}

        e.observed == true ->
          {false, nil, nil}

        true ->
          {true, :low, "span naming convention (:stop); measurement not verified"}
      end

    if has_duration do
      [
        rec(e, :summary, :duration, {:native, :millisecond},
          reason:
            "stop event of span #{EventName.format(e.span.prefix)}; #{why}" <>
              if(span_call?, do: "", else: "; verify the unit is native time"),
          confidence: conf
        )
      ]
    else
      [
        rec(e, :counter, :count, nil,
          reason: "stop event without a :duration measurement",
          confidence: :high
        )
      ]
    end
  end

  defp for_event(%Event{} = e) do
    numeric =
      for {key, s} <- e.measurements,
          is_atom(key),
          Enum.any?(Map.keys(s.types), &(&1 in [:integer, :float])),
          do: key

    timings = Enum.filter(numeric, &timing_key?/1)
    gauges = Enum.filter(numeric -- timings, &gauge_key?/1)

    cond do
      timings != [] ->
        Enum.map(timings, fn k ->
          rec(e, :summary, k, {:native, :millisecond},
            reason:
              "#{inspect(k)} looks like a duration (observed numeric); verify the unit is native time",
            confidence: :low
          )
        end)

      gauges != [] ->
        Enum.map(gauges, fn k ->
          rec(e, :last_value, k, nil,
            reason:
              "#{inspect(k)} looks like a gauge (size/count/total); last_value keeps the latest reading",
            confidence: :low
          )
        end)

      true ->
        [
          rec(e, :counter, :count, nil,
            reason: "standalone event: count occurrences",
            confidence: if(e.observed, do: :high, else: :medium)
          )
        ]
    end
  end

  # *_time is a duration in Ecto (query_time, queue_time, ...) but
  # system_time / monotonic_time are timestamps, never durations.
  @timestamps ~w(system_time monotonic_time start_time end_time timestamp)

  defp timing_key?(k) do
    s = Atom.to_string(k)

    s not in @timestamps and
      (s == "duration" or String.ends_with?(s, "_time") or String.ends_with?(s, "_duration"))
  end

  defp gauge_key?(k) do
    s = Atom.to_string(k)

    s in ["total", "count", "size", "length", "value"] or
      Enum.any?(["_size", "_count", "_length", "_bytes", "_total"], &String.ends_with?(s, &1))
  end

  defp observed_numeric?(e, key) do
    case e.measurements do
      %{^key => %{types: types}} -> Enum.any?(Map.keys(types), &(&1 in [:integer, :float]))
      _ -> false
    end
  end

  defp span_call?(e), do: Enum.any?(e.call_sites, &(&1.kind == :span))

  defp rec(e, type, measurement, unit, opts) do
    name = EventName.dotted(e.name) <> "." <> Atom.to_string(measurement)
    {tags, rejected} = tags(e)

    %{
      metric: type,
      name: name,
      event: e.name,
      measurement: measurement,
      unit: unit,
      tags: tags,
      rejected_tags: rejected,
      reason: opts[:reason],
      confidence: opts[:confidence],
      already_defined: Enum.any?(e.metrics, &(&1.metric_name == name and &1.metric_type == type))
    }
  end

  defp tags(e) do
    candidates =
      for {k, s} <- e.metadata,
          is_atom(k),
          k not in [:__too_many_keys__, :__non_atom_keys__, :telemetry_span_context] do
        {k, s}
      end

    accepted =
      for {k, s} <- candidates,
          s.presence == 1.0,
          Map.keys(s.types) != [],
          Enum.all?(Map.keys(s.types), &(&1 in @tag_types)),
          do: k

    rejected =
      for {k, s} <- candidates, k not in accepted, do: {k, Map.keys(s.types)}

    {Enum.sort(accepted), rejected}
  end

  @doc "Renders recommendations as reviewable Elixir code."
  def to_code(recommendations) do
    lines =
      Enum.map(recommendations, fn r ->
        opts =
          [
            r.unit && "unit: #{inspect(r.unit)}",
            r.tags != [] && "tags: #{inspect(r.tags)}"
          ]
          |> Enum.filter(& &1)

        args = Enum.join([inspect(r.name) | opts], ", ")

        "    # [#{r.confidence}] #{r.reason}\n    #{r.metric}(#{args})"
      end)

    """
    # ---------------------------------------------------------------------------
    # TeleScope metric SUGGESTIONS - generated #{Date.utc_today()}
    # Review every entry before use: units, tags and metric types are inferred
    # from static analysis and a finite runtime capture, not from documentation.
    # Confidence: high = measurement observed, medium = :telemetry.span contract,
    # low = naming heuristic only.
    # ---------------------------------------------------------------------------
    def metrics do
      [
    #{Enum.join(lines, ",\n\n")}
      ]
    end
    """
  end
end
