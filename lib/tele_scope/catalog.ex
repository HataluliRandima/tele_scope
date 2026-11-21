defmodule TeleScope.Catalog do
  @moduledoc """
  The central event catalog. A pure data structure: every `add_*` function
  takes evidence from one discovery mechanism and merges it.

  ## Merge semantics

    * Events are keyed by their **concrete name**; every mechanism that finds
      the same name updates the same `TeleScope.Event` (no duplicates).
    * `sources`, `apps` are set unions. Call sites are deduplicated by
      `CallSite.key/1`, so re-adding the same scan is idempotent.
    * Static call sites whose name is not fully known are kept as
      **patterns** (`:partial` / `:dynamic`). Concrete names from any source
      that match a pattern are linked to it (`matched`), which is how runtime
      discoveries explain dynamic call sites.
    * Runtime observations replace the previous runtime data for an event
      (a capture is a point-in-time window, not cumulative history).
    * Spans: `:span` call sites expand to `prefix ++ [:start|:stop|:exception]`;
      any name ending in one of those suffixes gets `span: %{prefix, role}`.
  """

  alias TeleScope.{Event, EventName}
  alias TeleScope.Discovery.CallSite

  defstruct events: %{},
            patterns: %{},
            static: nil,
            runtime: nil,
            config_errors: []

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  @emit_kinds [:execute, :execute_lazy, :span]

  ## static ------------------------------------------------------------------

  @doc "Merges a `TeleScope.Discovery.Scanner.Result`."
  def add_static(catalog, %TeleScope.Discovery.Scanner.Result{} = result) do
    # wrappers that have at least one call site resolved through them
    resolved_wrappers =
      for %CallSite{via: {:wrapper, mfa, _}, patterns: ps} <- result.sites,
          Enum.any?(ps, &EventName.literal?/1),
          into: MapSet.new(),
          do: mfa

    catalog =
      Enum.reduce(result.sites, catalog, fn site, cat ->
        add_site(cat, demote_unused_template(site, resolved_wrappers))
      end)

    catalog =
      Enum.reduce(result.declarations, catalog, fn decl, cat ->
        if EventName.valid_name?(decl.event) do
          upsert(cat, decl.event, fn e ->
            %{
              e
              | sources: MapSet.put(e.sources, :declared),
                apps: put_app(e.apps, decl[:app]),
                declaration: Map.take(decl, [:description, :measurements, :metadata, :module])
            }
          end)
        else
          cat
        end
      end)

    %{
      catalog
      | static: %{
          stats: result.stats,
          no_debug_info: result.no_debug_info,
          errors: result.errors
        }
    }
    |> link_patterns()
  end

  # Records whether a wrapper template's wrapper was resolved at >= 1 call site.
  defp demote_unused_template(%CallSite{extra: %{wrapper_template: true}} = site, resolved) do
    {f, a} = site.function

    %{
      site
      | extra:
          Map.put(site.extra, :wrapper_resolved, MapSet.member?(resolved, {site.module, f, a}))
    }
  end

  defp demote_unused_template(site, _resolved), do: site

  defp add_site(cat, %CallSite{kind: kind} = site) when kind in @emit_kinds do
    Enum.reduce(site.patterns, cat, fn pattern, cat ->
      names = expand(kind, pattern)

      if EventName.literal?(pattern) do
        source = if site.via == :direct, do: :static_literal, else: :static_resolved

        Enum.reduce(names, cat, fn name, cat ->
          upsert(cat, name, fn e ->
            %{
              e
              | sources: MapSet.put(e.sources, source),
                apps: put_app(e.apps, site.app),
                call_sites: add_call_site(e.call_sites, site)
            }
          end)
        end)
      else
        Enum.reduce(names, cat, fn p, cat -> add_pattern(cat, p, site) end)
      end
    end)
  end

  defp add_site(cat, %CallSite{kind: kind} = site) when kind in [:attach, :attach_many] do
    Enum.reduce(site.patterns, cat, fn pattern, cat ->
      if EventName.literal?(pattern) do
        upsert(cat, pattern, fn e ->
          h = Map.merge(site.handler, %{location: CallSite.location(site), module: site.module})

          %{
            e
            | sources: MapSet.put(e.sources, :handler_registration),
              static_handlers: Enum.uniq([h | e.static_handlers])
          }
        end)
      else
        cat
      end
    end)
  end

  defp add_site(cat, %CallSite{kind: :metric} = site) do
    Enum.reduce(site.patterns, cat, fn name, cat ->
      if EventName.valid_name?(name) do
        upsert(cat, name, fn e ->
          m = Map.merge(site.extra, %{location: CallSite.location(site), module: site.module})

          %{
            e
            | sources: MapSet.put(e.sources, :metric_definition),
              metrics: Enum.uniq([m | e.metrics])
          }
        end)
      else
        cat
      end
    end)
  end

  defp add_site(cat, _site), do: cat

  # span prefixes expand into the three conventional events
  defp expand(:span, pattern) when is_list(pattern),
    do: for(s <- [:start, :stop, :exception], do: pattern ++ [s])

  defp expand(_kind, pattern), do: [pattern]

  defp add_call_site(sites, site) do
    if Enum.any?(sites, &(CallSite.key(&1) == CallSite.key(site))),
      do: sites,
      else: sites ++ [site]
  end

  defp add_pattern(cat, pattern, site) do
    entry =
      Map.get(cat.patterns, pattern, %{
        pattern: pattern,
        classification: EventName.classify(pattern),
        call_sites: [],
        matched: [],
        wrapper_template: true,
        wrapper_resolved: false
      })

    # A wrapper template is the generic pattern of a telemetry call whose name
    # comes from a parameter (e.g. `[:demo_app | suffix]`). Its concrete names
    # are reported at the wrapper's call sites (a caller passing unknown
    # values produces its own non-template partial site), so a template is
    # never evidence that arbitrary matching names are emitted.
    template? = Map.get(site.extra, :wrapper_template, false)

    entry = %{
      entry
      | call_sites: add_call_site(entry.call_sites, site),
        wrapper_template: entry.wrapper_template and template?,
        wrapper_resolved: entry.wrapper_resolved or Map.get(site.extra, :wrapper_resolved, false)
    }

    %{cat | patterns: Map.put(cat.patterns, pattern, entry)}
  end

  ## configuration rules ---------------------------------------------------------

  @doc "Merges events produced by `TeleScope.Discovery.Rule.run_config/2`."
  def add_config_events(catalog, events) do
    {errors, events} = Enum.split_with(events, &Map.has_key?(&1, :error))

    catalog =
      Enum.reduce(events, catalog, fn ev, cat ->
        if EventName.valid_name?(ev.name) do
          upsert(cat, ev.name, fn e ->
            %{
              e
              | sources: MapSet.put(e.sources, :config_rule),
                apps: put_app(e.apps, ev[:app]),
                rule_reasons:
                  Enum.uniq([
                    %{rule: ev.rule, reason: ev.reason, emitted_by: Map.get(ev, :emitted_by, [])}
                    | e.rule_reasons
                  ])
            }
          end)
        else
          cat
        end
      end)

    %{catalog | config_errors: catalog.config_errors ++ errors} |> link_patterns()
  end

  ## runtime -------------------------------------------------------------------

  @doc "Merges the result of `TeleScope.Runtime.Capture`."
  def add_capture(catalog, capture) do
    catalog
    |> add_trace(capture.trace)
    |> add_observations(capture.observations)
    |> add_runtime_handlers(
      capture.handlers_after,
      capture.invocations,
      capture.shared_handler_functions
    )
    |> Map.put(:runtime, %{
      started_at: capture.started_at,
      finished_at: capture.finished_at,
      duration_ms: capture.duration_ms,
      trace: capture.trace && Map.drop(capture.trace, [:names]),
      trace_error: Map.get(capture, :trace_error),
      observer:
        Map.take(capture.observations, [
          :status,
          :error,
          :total_events,
          :dropped_events,
          :callback_errors,
          :ets_memory_bytes,
          :sample_rate,
          :handler_failures
        ]),
      handler_failures: capture.observations.handler_failures
    })
    |> link_patterns()
  end

  @doc false
  def add_trace(catalog, trace) when not is_map(trace), do: catalog

  def add_trace(catalog, trace) do
    Enum.reduce(trace.names, catalog, fn n, cat ->
      upsert(cat, n.name, fn e ->
        %{
          e
          | sources: MapSet.put(e.sources, :runtime_trace),
            observed: true,
            trace: Map.take(n, [:first_seen_at, :process, :via, :count])
        }
      end)
    end)
  end

  @doc false
  def add_observations(catalog, observations) do
    catalog
    |> merge_observations(observations)
    |> reconcile_trace_counts()
  end

  # The observer attaches to tracer-discovered names only after discovery, so
  # its count can miss the first occurrence(s). The tracer count is a lower
  # bound; use it when larger and flag the count as estimated.
  defp reconcile_trace_counts(catalog) do
    events =
      Map.new(catalog.events, fn {name, e} ->
        trace_count = (e.trace && e.trace[:count]) || 0

        if trace_count > e.count,
          do: {name, %{e | count: trace_count, count_estimated: true}},
          else: {name, e}
      end)

    %{catalog | events: events}
  end

  defp merge_observations(catalog, %{events: events, attached_events: attached}) do
    # every attached name was covered by the observer: not seen => :not_observed
    catalog =
      Enum.reduce(attached, catalog, fn name, cat ->
        upsert(cat, name, fn e ->
          if e.observed == true, do: e, else: %{e | observed: false}
        end)
      end)

    Enum.reduce(events, catalog, fn {name, obs}, cat ->
      upsert(cat, name, fn e ->
        %{
          e
          | sources: MapSet.put(e.sources, :runtime_observed),
            observed: true,
            count: obs.count,
            count_estimated: obs.count_estimated,
            first_seen_at: obs.first_seen_at,
            last_seen_at: obs.last_seen_at,
            measurements: obs.measurements,
            metadata: obs.metadata,
            shape_count: obs.shape_count,
            processes: obs.processes
        }
      end)
    end)
  end

  @doc false
  def add_runtime_handlers(catalog, handlers, invocations, shared) do
    invocations = invocations || %{}

    Enum.reduce(handlers, catalog, fn h, cat ->
      mfa = h.function.mfa

      entry =
        h
        |> Map.take([:id, :function, :config_type])
        |> Map.put(:invocations, Map.get(invocations, mfa))
        |> Map.put(:invocations_shared_with, Map.get(shared || %{}, mfa, []) -- [h.id])
        # call_count is per function: only attributable to this handler id
        # when no other handler id uses the same function
        |> then(&Map.put(&1, :invocations_attributable, &1.invocations_shared_with == []))

      upsert(cat, h.event_name, fn e ->
        %{
          e
          | sources: MapSet.put(e.sources, :runtime_handler),
            handlers: Enum.uniq_by([entry | e.handlers], & &1.id)
        }
      end)
    end)
  end

  ## queries -------------------------------------------------------------------

  @doc "Events sorted by name."
  def events(catalog), do: catalog.events |> Map.values() |> Enum.sort_by(& &1.name)

  def get(catalog, name), do: Map.get(catalog.events, name)

  @doc """
  Patterns that no concrete name explains. Template-only patterns are
  excluded when their wrapper was resolved at one or more call sites.
  """
  def unresolved_patterns(catalog),
    do:
      catalog.patterns
      |> Map.values()
      |> Enum.filter(&(&1.matched == [] and not (&1.wrapper_template and &1.wrapper_resolved)))

  @doc """
  Specific partial patterns: non-template patterns with at least one known
  segment. Used to decide whether an unknown name *might* be emitted.
  """
  def specific_patterns(catalog),
    do:
      catalog.patterns
      |> Map.values()
      |> Enum.filter(&(&1.classification == :partial and not &1.wrapper_template))

  @doc "Span groups: `%{prefix => %{start: bool, stop: bool, exception: bool}}`."
  def spans(catalog) do
    catalog
    |> events()
    |> Enum.filter(&(&1.span && Event.emitter_known?(&1)))
    |> Enum.group_by(& &1.span.prefix, & &1.span.role)
    |> Map.new(fn {prefix, roles} ->
      {prefix, %{start: :start in roles, stop: :stop in roles, exception: :exception in roles}}
    end)
  end

  @doc "Summary counts used by reports and the spike coverage measurement."
  def summary(catalog) do
    events = events(catalog)
    patterns = Map.values(catalog.patterns)

    %{
      events: length(events),
      by_status: Enum.frequencies_by(events, &Event.status/1),
      by_confidence: Enum.frequencies_by(events, &Event.confidence/1),
      patterns: length(patterns),
      patterns_by_class: Enum.frequencies_by(patterns, & &1.classification),
      unresolved_patterns: length(unresolved_patterns(catalog)),
      wrapper_templates: Enum.count(patterns, & &1.wrapper_template),
      spans: map_size(spans(catalog))
    }
  end

  ## helpers -------------------------------------------------------------------

  defp upsert(cat, name, fun) do
    event = Map.get_lazy(cat.events, name, fn -> Event.new(name) end)
    %{cat | events: Map.put(cat.events, name, fun.(event))}
  end

  defp put_app(apps, nil), do: apps
  defp put_app(apps, app), do: MapSet.put(apps, app)

  # Partial patterns are linked to every concrete emitted name they match.
  # Fully dynamic patterns (`[**]`) match anything, so they are only linked
  # through explicit evidence: a rule declaring the call site's module as the
  # emitter (e.g. Ecto rule -> Ecto.Adapters.SQL).
  defp link_patterns(cat) do
    emitted = for {name, e} <- cat.events, Event.emitter_known?(e), do: {name, e}

    patterns =
      Map.new(cat.patterns, fn {p, entry} ->
        matched =
          case entry.classification do
            :dynamic ->
              modules = MapSet.new(entry.call_sites, & &1.module)

              for {name, e} <- emitted,
                  Enum.any?(e.rule_reasons, fn r ->
                    Enum.any?(r.emitted_by, &MapSet.member?(modules, &1))
                  end),
                  do: name

            _ ->
              for {name, _} <- emitted, EventName.matches?(p, name), do: name
          end

        {p, %{entry | matched: Enum.sort(matched)}}
      end)

    %{cat | patterns: patterns}
  end
end
