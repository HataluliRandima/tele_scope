defmodule TeleScope.Diagnostics do
  @moduledoc """
  Diagnostics over a `TeleScope.Catalog`.

  Severity is deliberately conservative:

    * `:error` - something is demonstrably broken (a handler crashed and was
      detached by telemetry)
    * `:warning` - very likely a mistake (a metric or handler referencing a
      name nothing emits, sensitive-looking metadata keys, blind spots)
    * `:info` - worth knowing, frequently fine (no listener, not observed,
      optional metadata keys)

  An event without a handler is **never** reported as an error: libraries
  emit events for optional consumers.
  """

  alias TeleScope.{Catalog, Event, EventName}

  @sensitive ~r/(pass(word|wd)?|secret|token|api_?key|auth(orization)?|cookie|session|credential|private_?key|ssn|credit_?card)/i

  @type diagnostic :: %{
          check: atom(),
          severity: :error | :warning | :info,
          event: [atom()] | nil,
          message: String.t(),
          detail: map()
        }

  @doc "Runs every check. Returns diagnostics sorted by severity."
  def run(%Catalog{} = catalog) do
    events = Catalog.events(catalog)
    emitted = for e <- events, Event.emitter_known?(e), do: e.name

    [
      handler_failures(catalog),
      unknown_event_consumers(events, emitted, catalog),
      metric_measurement_missing(events),
      unhandled(events, catalog),
      inactive_handlers(events, catalog),
      schema_drift(events),
      sensitive_keys(events),
      incomplete_spans(catalog),
      unresolved_patterns(catalog),
      blind_spots(catalog),
      capture_limits(catalog)
    ]
    |> List.flatten()
    |> Enum.sort_by(&{severity_rank(&1.severity), &1.check, &1.event || []})
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 2

  defp d(check, severity, event, message, detail),
    do: %{check: check, severity: severity, event: event, message: message, detail: detail}

  # -- errors -------------------------------------------------------------------

  defp handler_failures(%{runtime: %{handler_failures: failures}}) when is_list(failures) do
    for f <- failures do
      d(
        :handler_failure,
        :error,
        f.event,
        "Handler #{inspect(f.handler_id)} raised (#{inspect(f.kind)}) #{f.count} time(s) and was detached by :telemetry",
        %{handler_id: f.handler_id}
      )
    end
  end

  defp handler_failures(_), do: []

  # -- consumers referencing unknown events -------------------------------------

  defp unknown_event_consumers(events, emitted, catalog) do
    # fully dynamic patterns ([**]) and wrapper templates match almost
    # anything; only specific partial patterns are evidence
    patterns = Catalog.specific_patterns(catalog)

    for e <- events, not Event.emitter_known?(e), reduce: [] do
      acc ->
        consumers =
          Enum.map(e.metrics, &"metric #{&1.metric_name} (#{&1.location})") ++
            Enum.map(e.static_handlers, &"handler #{inspect(&1.id)} (#{&1.location})") ++
            Enum.map(e.handlers, &"runtime handler #{inspect(&1.id)}")

        possible = Enum.filter(patterns, &EventName.matches?(&1.pattern, e.name))
        similar = similar_names(e.name, emitted)

        {severity, why} =
          cond do
            possible != [] ->
              {:info,
               "may be emitted by a dynamic call site matching #{Enum.map_join(possible, ", ", &EventName.format(&1.pattern))}"}

            true ->
              {:warning, "no emitter found in scanned code" <> hint(similar)}
          end

        [
          d(
            :consumer_without_emitter,
            severity,
            e.name,
            "#{EventName.format(e.name)} is consumed by #{Enum.join(consumers, ", ")} but #{why}",
            %{similar: similar}
          )
          | acc
        ]
    end
  end

  defp hint([]), do: ""
  defp hint(similar), do: "; did you mean #{Enum.map_join(similar, " or ", &EventName.format/1)}?"

  defp similar_names(name, emitted) do
    dotted = EventName.dotted(name)

    emitted
    |> Enum.map(&{&1, String.jaro_distance(dotted, EventName.dotted(&1))})
    |> Enum.filter(fn {_, score} -> score >= 0.9 end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 0))
  end

  defp metric_measurement_missing(events) do
    for e <- events,
        e.observed == true,
        map_size(e.measurements) > 0,
        m <- e.metrics,
        m.metric_type != :counter,
        not Map.has_key?(e.measurements, m.measurement) do
      d(
        :metric_measurement_missing,
        :warning,
        e.name,
        "Metric #{m.metric_name} reads measurement #{inspect(m.measurement)} which was never observed on #{EventName.format(e.name)} (seen: #{e.measurements |> Map.keys() |> Enum.map_join(", ", &inspect/1)})",
        %{metric: m.metric_name}
      )
    end
  end

  # -- handlers -----------------------------------------------------------------

  defp unhandled(_events, %{runtime: nil}), do: []

  defp unhandled(events, _catalog) do
    for e <- events,
        Event.emitter_known?(e),
        e.handlers == [],
        e.name != [:telemetry, :handler, :failure] do
      d(
        :no_runtime_handler,
        :info,
        e.name,
        "#{EventName.format(e.name)} has no handler attached at runtime (not necessarily a problem)",
        %{status: Event.status(e)}
      )
    end
  end

  defp inactive_handlers(_events, %{runtime: nil}), do: []

  defp inactive_handlers(events, _catalog) do
    for e <- events, h <- e.handlers, h.invocations == 0, h.invocations_attributable do
      msg =
        if e.observed == true do
          "Handler #{inspect(h.id)} is attached to #{EventName.format(e.name)} which fired, but its function was never invoked"
        else
          "Handler #{inspect(h.id)} on #{EventName.format(e.name)} was not invoked during the capture window"
        end

      d(:inactive_handler, if(e.observed == true, do: :warning, else: :info), e.name, msg, %{
        handler_id: h.id
      })
    end
  end

  # -- shapes -------------------------------------------------------------------

  defp schema_drift(events) do
    for e <- events,
        e.observed == true,
        {section, stats} <- [measurements: e.measurements, metadata: e.metadata],
        {key, s} <- stats,
        key not in [:__too_many_keys__, :__non_atom_keys__],
        drift = drift(s),
        drift != nil do
      d(
        :schema_drift,
        :info,
        e.name,
        "#{EventName.format(e.name)} #{section}.#{key}: #{drift}",
        %{
          section: section,
          key: key,
          presence: s.presence,
          types: Map.keys(s.types)
        }
      )
    end
  end

  defp drift(%{presence: p, types: types}) do
    non_nil = Map.keys(types) -- [nil]

    cond do
      p < 1.0 -> "present in #{Float.round(p * 100, 1)}% of events"
      length(non_nil) > 1 -> "multiple types #{inspect(non_nil)}"
      Map.has_key?(types, nil) and non_nil != [] -> "nullable (#{inspect(hd(non_nil))} or nil)"
      true -> nil
    end
  end

  defp sensitive_keys(events) do
    for e <- events,
        {section, stats} <- [measurements: e.measurements, metadata: e.metadata],
        {key, _} <- stats,
        is_atom(key),
        Regex.match?(@sensitive, Atom.to_string(key)) do
      d(
        :sensitive_key,
        :warning,
        e.name,
        "#{EventName.format(e.name)} #{section} contains a key named #{inspect(key)}; make sure reporters/loggers attached to this event do not export its value",
        %{section: section, key: key}
      )
    end
  end

  # -- static structure ---------------------------------------------------------

  defp incomplete_spans(catalog) do
    for {prefix, roles} <- Catalog.spans(catalog), roles.start != roles.stop do
      missing = if roles.start, do: :stop, else: :start

      d(
        :incomplete_span,
        :info,
        prefix,
        "Span #{EventName.format(prefix)} has #{if roles.start, do: ":start", else: ":stop"} but no #{inspect(missing)} event was found",
        roles
      )
    end
  end

  defp unresolved_patterns(catalog) do
    for p <- Catalog.unresolved_patterns(catalog) do
      sites = Enum.map(p.call_sites, &TeleScope.Discovery.CallSite.location/1) |> Enum.uniq()

      d(
        :unresolved_call_site,
        :info,
        nil,
        "#{p.classification} event name #{EventName.format(p.pattern)} at #{Enum.join(Enum.take(sites, 3), ", ")}#{if length(sites) > 3, do: " (+#{length(sites) - 3} more)", else: ""} could not be resolved statically; a runtime capture can discover the concrete names",
        %{pattern: p.pattern, call_sites: sites}
      )
    end
  end

  defp blind_spots(%{static: %{no_debug_info: mods}}) when mods != [] do
    [
      d(
        :no_debug_info,
        :warning,
        nil,
        "#{length(mods)} module(s) call telemetry but have no debug info; their event names are invisible to static discovery",
        %{modules: mods}
      )
    ]
  end

  defp blind_spots(_), do: []

  defp capture_limits(%{runtime: %{trace: trace, observer: obs} = rt}) do
    trace_diags =
      case trace do
        nil when rt.trace_error != nil ->
          [
            d(
              :capture_limited,
              :warning,
              nil,
              "Tracer failed (#{inspect(rt.trace_error)}); dynamic names were not discovered",
              %{}
            )
          ]

        %{status: status} when status in [:overload, :max_messages, :max_names] ->
          [
            d(
              :capture_limited,
              :warning,
              nil,
              "Tracer stopped early (#{status}); dynamic name discovery is incomplete",
              %{}
            )
          ]

        _ ->
          []
      end

    obs_diags =
      if obs[:dropped_events] && obs[:dropped_events] > 0 do
        [
          d(
            :capture_limited,
            :warning,
            nil,
            "Observer hit :max_events; #{obs.dropped_events} events were not shape-recorded",
            %{}
          )
        ]
      else
        []
      end

    trace_diags ++ obs_diags
  end

  defp capture_limits(_), do: []
end
