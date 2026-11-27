defmodule TeleScope.Diagnostics do
  @moduledoc """
  Diagnostics over a `TeleScope.Catalog`.

  Every diagnostic has a **stable code** (`"TS001"` ...) that never changes
  meaning, so it can be referenced in CI logs, issues and documentation. The
  full list, with explanations and remediation, is in `definitions/0` and in
  the DIAGNOSTICS.md guide.

  ## Severity

  Severity is deliberately conservative:

    * `:error` - something is demonstrably broken (a handler crashed and was
      detached by telemetry)
    * `:warning` - very likely a mistake in the project (a metric or handler
      referencing a name nothing emits, a metric reading a measurement the
      event does not carry, sensitive-looking metadata keys)
    * `:info` - worth knowing, frequently fine (no listener, not observed,
      optional metadata keys, coverage notes)

  An event without a handler is **never** reported as an error: libraries
  emit events for optional consumers.

  ## Limitations

  Diagnostics with `limitation: true` describe what TeleScope *could not
  see* (unreadable modules, a tracer that stopped early, ...), not a defect
  of the project. They are always `:info`, so `mix telemetry.check --strict`
  never fails because of them, but reporters always show them because they
  qualify every other result.

  ## Shape of a diagnostic

      %{
        code: "TS002",
        check: :consumer_without_emitter,
        severity: :warning,
        limitation: false,
        title: "Consumer references an event nothing emits",
        event: [:my_app, :order, :created],      # or nil
        message: "...",                          # the problem, one paragraph
        suggestion: "Did you mean ...?",         # or nil
        locations: ["lib/my_app/telemetry.ex:42"],
        detail: %{...}                           # check-specific data
      }

  The list returned by `run/1` is deterministic: sorted by severity, code,
  event and message.
  """

  alias TeleScope.{Catalog, Event, EventName}
  alias TeleScope.Discovery.CallSite

  @type severity :: :error | :warning | :info

  @type diagnostic :: %{
          code: String.t(),
          check: atom(),
          severity: severity(),
          limitation: boolean(),
          title: String.t(),
          event: [atom()] | nil,
          message: String.t(),
          suggestion: String.t() | nil,
          locations: [String.t()],
          detail: map()
        }

  @type definition :: %{
          code: String.t(),
          check: atom(),
          title: String.t(),
          severities: [severity()],
          evidence: :static | :runtime | :static_or_runtime,
          description: String.t()
        }

  # Codes are part of the public contract: never renumber or reuse one.
  @definitions [
    %{
      code: "TS001",
      check: :handler_failure,
      title: "Handler raised and was detached",
      severities: [:error],
      evidence: :runtime,
      description:
        "A handler raised during the capture. :telemetry detaches a handler the first time it raises, so it silently stops receiving the event for the rest of the VM's life."
    },
    %{
      code: "TS002",
      check: :consumer_without_emitter,
      title: "Consumer references an event nothing emits",
      severities: [:warning, :info],
      evidence: :static_or_runtime,
      description:
        "A handler or Telemetry.Metrics definition references an event name for which no emitter was found. In the project's own code this is usually a typo; it is info when a dynamic call site could emit the name or when the consumer lives in a dependency."
    },
    %{
      code: "TS003",
      check: :metric_measurement_missing,
      title: "Metric reads a measurement the event does not carry",
      severities: [:warning, :info],
      evidence: :runtime,
      description:
        "The event fired during the capture, but never with the measurement a metric reads. The metric produces no data. Info when a rule declares the measurement optional."
    },
    %{
      code: "TS004",
      check: :inactive_handler,
      title: "Attached handler was not invoked",
      severities: [:warning, :info],
      evidence: :runtime,
      description:
        "A handler was attached, but its function was never called. Warning only when the event fired after invocation counting for that handler had started; otherwise the event simply did not fire in the window (info)."
    },
    %{
      code: "TS005",
      check: :sensitive_key,
      title: "Sensitive-looking key in event data",
      severities: [:warning],
      evidence: :runtime,
      description:
        "An observed measurement or metadata key is named like a secret (password, token, api_key, ...). Reporters, loggers or exporters attached to the event may export its value. Only key names are inspected, never values."
    },
    %{
      code: "TS006",
      check: :no_debug_info,
      title: "Telemetry-calling modules without debug info",
      severities: [:warning, :info],
      evidence: :static,
      description:
        "Modules that call telemetry were compiled without debug info, so their event names are invisible to static discovery. Warning for the project's own modules (fixable), info (limitation) for dependencies."
    },
    %{
      code: "TS007",
      check: :incomplete_span,
      title: "Span with a :start but no :stop (or vice versa)",
      severities: [:info],
      evidence: :static_or_runtime,
      description:
        "An event ending in :start was found without the matching :stop (or the reverse). Duration metrics and span-aware reporters need both."
    },
    %{
      code: "TS008",
      check: :unresolved_call_site,
      title: "Event name could not be resolved statically",
      severities: [:info],
      evidence: :static,
      description:
        "A telemetry call builds its event name from data static analysis cannot follow, and no known name matches it. A runtime capture can discover the concrete names."
    },
    %{
      code: "TS009",
      check: :schema_drift,
      title: "Inconsistent measurement or metadata shape",
      severities: [:info],
      evidence: :runtime,
      description:
        "A key was missing from some occurrences of an event, had several types, or was sometimes nil. Metrics and handlers reading it must tolerate that."
    },
    %{
      code: "TS010",
      check: :no_runtime_handler,
      title: "Event has no handler attached",
      severities: [:info],
      evidence: :runtime,
      description:
        "No handler was attached to an emitted event during the capture. Usually fine: libraries emit events for optional consumers."
    },
    %{
      code: "TS011",
      check: :capture_limited,
      title: "Runtime capture was incomplete",
      severities: [:info],
      evidence: :runtime,
      description:
        "The tracer could not start or stopped early, or the observer crashed or hit a limit. Runtime results (observed events, shapes, counts) are incomplete. Limitation, not a project defect."
    },
    %{
      code: "TS012",
      check: :scan_error,
      title: "Part of the build could not be scanned",
      severities: [:info],
      evidence: :static,
      description:
        "A directory was missing, a .beam file could not be read or analysed, or a discovery rule failed. Events defined there may be missing from the catalog. Limitation, not a project defect."
    },
    %{
      code: "TS013",
      check: :runtime_only_event,
      title: "Event fired that static discovery did not predict",
      severities: [:info],
      evidence: :runtime,
      description:
        "An event fired during the capture although no static evidence names it: its name is built dynamically, or it is emitted by code that was not scanned."
    }
  ]

  @by_check Map.new(@definitions, &{&1.check, &1})
  @by_code Map.new(@definitions, &{&1.code, &1})

  @doc "Every diagnostic TeleScope can produce, ordered by code."
  @spec definitions() :: [definition()]
  def definitions, do: @definitions

  @doc "Looks a definition up by code (`\"TS002\"`) or check (`:consumer_without_emitter`)."
  @spec definition(String.t() | atom()) :: definition() | nil
  def definition(code) when is_binary(code), do: Map.get(@by_code, code)
  def definition(check) when is_atom(check), do: Map.get(@by_check, check)

  # Matched against whole `_`/camelCase-separated segments of a key name, not
  # substrings: substring matching flagged :author_id, :passenger_count,
  # :compass_heading, :bypass_cache, :tokenizer_ms and :classname (audit),
  # which made `mix telemetry.check --strict` fail on innocent keys.
  @sensitive_segments ~w(password passwd pwd passphrase secret secrets token tokens
                         authorization auth cookie cookies credential credentials
                         ssn cvv cvc apikey privatekey)
  @sensitive_pairs [
    ~w(api key),
    ~w(private key),
    ~w(credit card),
    ~w(card number),
    ~w(access key),
    ~w(session id),
    ~w(client secret)
  ]

  @doc false
  def sensitive_key?(key) when is_atom(key) do
    segments =
      key
      |> Atom.to_string()
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.downcase()
      |> String.split(~r/[_\-.]+/, trim: true)

    Enum.any?(segments, &(&1 in @sensitive_segments)) or
      Enum.any?(Enum.chunk_every(segments, 2, 1, :discard), &(&1 in @sensitive_pairs))
  end

  def sensitive_key?(_), do: false

  @doc "Runs every check. Returns diagnostics sorted by severity, code, event and message."
  @spec run(Catalog.t()) :: [diagnostic()]
  def run(%Catalog{} = catalog) do
    events = Catalog.events(catalog)
    emitted = for e <- events, Event.emitter_known?(e), do: e.name

    [
      handler_failures(catalog),
      unknown_event_consumers(events, emitted, catalog),
      metric_measurement_missing(events),
      inactive_handlers(events, catalog),
      sensitive_keys(events),
      blind_spots(catalog),
      incomplete_spans(catalog),
      unresolved_patterns(catalog),
      schema_drift(events),
      unhandled(events, catalog),
      capture_limits(catalog),
      scan_errors(catalog),
      runtime_only(events, catalog)
    ]
    |> List.flatten()
    |> Enum.sort_by(&{severity_rank(&1.severity), &1.code, &1.event || [], &1.message})
  end

  @doc """
  Decides whether a list of diagnostics passes a check.

  Fails on `:error` diagnostics, and on `:warning` ones too with
  `strict: true`. Limitations (always `:info`) never fail a check.

      %{status: :failed, strict: true, failing: [...], counts: %{error: 0, warning: 1, info: 7}}
  """
  @spec evaluate([diagnostic()], keyword()) :: %{
          status: :passed | :failed,
          strict: boolean(),
          failing: [diagnostic()],
          counts: %{error: non_neg_integer(), warning: non_neg_integer(), info: non_neg_integer()}
        }
  def evaluate(diagnostics, opts \\ []) do
    strict = Keyword.get(opts, :strict, false)
    failing_severities = if strict, do: [:error, :warning], else: [:error]

    failing =
      Enum.filter(diagnostics, &(&1.severity in failing_severities and not &1.limitation))

    %{
      status: if(failing == [], do: :passed, else: :failed),
      strict: strict,
      failing: failing,
      counts: counts(diagnostics)
    }
  end

  @doc "Number of diagnostics per severity (all three keys always present)."
  def counts(diagnostics) do
    Map.merge(%{error: 0, warning: 0, info: 0}, Enum.frequencies_by(diagnostics, & &1.severity))
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 2

  defp d(check, severity, event, message, opts) do
    # severity in definition.severities is enforced by the test suite, not
    # asserted here: a slip must never crash a user's CI run
    definition = Map.fetch!(@by_check, check)

    %{
      code: definition.code,
      check: check,
      severity: severity,
      limitation: Keyword.get(opts, :limitation, false),
      title: definition.title,
      event: event,
      message: message,
      suggestion: Keyword.get(opts, :suggestion),
      locations: opts |> Keyword.get(:locations, []) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      detail: Keyword.get(opts, :detail, %{})
    }
  end

  defp limitation(check, message, opts),
    do: d(check, :info, nil, message, Keyword.put(opts, :limitation, true))

  # -- TS001 handler failures ------------------------------------------------------

  defp handler_failures(%{runtime: %{handler_failures: failures}} = catalog)
       when is_list(failures) do
    for f <- failures do
      static_locations =
        case f.event && Catalog.get(catalog, f.event) do
          %Event{static_handlers: hs} -> for h <- hs, h.id == f.handler_id, do: h.location
          _ -> []
        end

      d(
        :handler_failure,
        :error,
        f.event,
        "Handler #{inspect(f.handler_id)} raised (#{inspect(f.kind)}) #{f.count} time(s) and was detached by :telemetry; it no longer receives this event",
        suggestion:
          "Fix the exception in the handler (telemetry logs it with a stacktrace when it detaches the handler) and make the handler tolerate every measurement and metadata shape the event can carry.",
        locations: static_locations,
        detail: %{handler_id: f.handler_id, kind: f.kind, count: f.count}
      )
    end
  end

  defp handler_failures(_), do: []

  # -- TS002 consumers referencing unknown events -------------------------------

  defp unknown_event_consumers(events, emitted, catalog) do
    # fully dynamic patterns ([**]), patterns without a known namespace
    # ([**, :start]) and wrapper templates match almost anything; only
    # specific partial patterns are evidence
    patterns = Catalog.specific_patterns(catalog)

    for e <- events, not Event.emitter_known?(e) do
      consumers =
        Enum.map(e.metrics, &{"metric #{&1.metric_name}", &1.location, consumer_app(catalog, &1)}) ++
          Enum.map(
            e.static_handlers,
            &{"handler #{inspect(&1.id)}", &1.location, consumer_app(catalog, &1)}
          ) ++
          for h <- e.handlers,
              # the same registration found statically and at runtime is one consumer
              not Enum.any?(e.static_handlers, &(&1.id == h.id)),
              do: {"runtime handler #{inspect(h.id)}", nil, consumer_app(catalog, h)}

      consumers = Enum.sort(consumers)

      project? =
        Enum.any?(consumers, fn {_, _, app} -> Catalog.project_app?(catalog, app) end)

      dep_apps = consumers |> Enum.map(&elem(&1, 2)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      possible = Enum.filter(patterns, &EventName.matches?(&1.pattern, e.name))
      similar = similar_names(e.name, emitted)
      described = Enum.map_join(consumers, ", ", &elem(&1, 0))
      name = EventName.format(e.name)

      {severity, message, suggestion} =
        cond do
          possible != [] ->
            {:info,
             "#{name} is consumed by #{described}; no literal emitter was found, but it may be emitted by a dynamic call site matching #{Enum.map_join(possible, ", ", &EventName.format(&1.pattern))}",
             "Run a runtime capture (--runtime) while exercising the code path to confirm the event fires."}

          project? ->
            {:warning,
             "#{name} is consumed by #{described}, but no emitter was found in the scanned code",
             suggestion_for_missing_emitter(similar)}

          true ->
            # a dependency's optional integration (e.g. Sentry attaching to
            # Quantum events when Quantum is not installed) is not the
            # project's bug
            {:info,
             "#{name} is consumed by #{described}, but no emitter was found; the consumer is in a dependency (#{Enum.map_join(dep_apps, ", ", &inspect/1)}), likely an optional integration",
             nil}
        end

      d(:consumer_without_emitter, severity, e.name, message,
        suggestion: suggestion,
        locations: Enum.map(consumers, &elem(&1, 1)),
        detail: %{similar: similar, project_consumer: project?}
      )
    end
  end

  defp consumer_app(catalog, consumer), do: Catalog.consumer_app(catalog, consumer)

  defp suggestion_for_missing_emitter([]),
    do:
      "Check the event name for typos. If the event is emitted by code TeleScope cannot see (a dependency without debug info, a name built at runtime, code loaded dynamically), confirm it with a runtime capture (--runtime)."

  defp suggestion_for_missing_emitter(similar),
    do:
      "Did you mean #{Enum.map_join(similar, " or ", &EventName.format/1)}? Check the event name in the metric or handler definition."

  # Suggestions for a consumed-but-never-emitted name:
  #   * near-identical spelling (Jaro >= 0.9) - typos like :order vs :orders
  #   * same namespace and one name is a subsequence of the other with at most
  #     two extra segments - span-naming slips such as
  #     [:oban, :notifier, :exception] vs [:oban, :notifier, :notify, :exception]
  #     (real-app validation, Plausible)
  defp similar_names(name, emitted) do
    dotted = EventName.dotted(name)

    by_spelling =
      for e <- emitted,
          score = String.jaro_distance(dotted, EventName.dotted(e)),
          score >= 0.9,
          do: {e, score}

    by_structure =
      for e <- emitted,
          hd(e) == hd(name),
          abs(length(e) - length(name)) in 1..2,
          subsequence?(name, e) or subsequence?(e, name),
          do: {e, 0.85}

    (by_spelling ++ by_structure)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(fn {e, score} -> {-score, e} end)
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 0))
  end

  defp subsequence?([], _), do: true
  defp subsequence?(_, []), do: false
  defp subsequence?([a | as], [a | bs]), do: subsequence?(as, bs)
  defp subsequence?(as, [_ | bs]), do: subsequence?(as, bs)

  # -- TS003 metric measurement missing -----------------------------------------

  defp metric_measurement_missing(events) do
    for e <- events,
        e.observed == true,
        map_size(e.measurements) > 0,
        m <- e.metrics,
        # counters do not read a measurement; a function measurement
        # (`measurement: &fun/1`) cannot be checked statically
        m.metric_type != :counter,
        m.measurement != :custom,
        not Map.has_key?(e.measurements, m.measurement) do
      keys = e.measurements |> Map.keys() |> Enum.filter(&is_atom/1) |> Enum.sort()
      seen = Enum.map_join(keys, ", ", &inspect/1)
      similar = similar_measurements(m.measurement, keys)

      suggestion =
        case similar do
          [] ->
            "Check the measurement name (or the :measurement option) in the metric definition; the event carries: #{seen}."

          _ ->
            "Did you mean #{Enum.map_join(similar, " or ", &inspect/1)}? Check the measurement name (or the :measurement option) in the metric definition."
        end

      detail = %{metric: m.metric_name, measurement: m.measurement, observed: keys}

      if m.measurement in e.optional_measurements do
        d(
          :metric_measurement_missing,
          :info,
          e.name,
          "Metric #{m.metric_name} reads optional measurement #{inspect(m.measurement)}, which did not occur on #{EventName.format(e.name)} during this capture (seen: #{seen})",
          locations: [m.location],
          detail: Map.put(detail, :optional, true)
        )
      else
        d(
          :metric_measurement_missing,
          :warning,
          e.name,
          "Metric #{m.metric_name} reads measurement #{inspect(m.measurement)}, which was never observed on #{EventName.format(e.name)} (seen: #{seen})",
          suggestion: suggestion,
          locations: [m.location],
          detail: Map.put(detail, :similar, similar)
        )
      end
    end
  end

  # :duration_ms vs :duration, :total_time vs :total_tme
  defp similar_measurements(wanted, keys) when is_atom(wanted) do
    w = Atom.to_string(wanted)

    keys
    |> Enum.filter(fn k ->
      s = Atom.to_string(k)

      String.jaro_distance(w, s) >= 0.85 or String.starts_with?(w, s <> "_") or
        String.starts_with?(s, w <> "_")
    end)
    |> Enum.take(3)
  end

  defp similar_measurements(_wanted, _keys), do: []

  # -- TS004 inactive handlers --------------------------------------------------

  defp inactive_handlers(_events, %{runtime: nil}), do: []

  defp inactive_handlers(events, _catalog) do
    for e <- events, h <- e.handlers, h.invocations == 0, h.invocations_attributable do
      fired_while_tracked? = fired_after?(e, Map.get(h, :tracked_since))
      fun = format_mfa(h.function[:mfa])

      {severity, message} =
        cond do
          fired_while_tracked? ->
            {:warning,
             "Handler #{inspect(h.id)} is attached to #{EventName.format(e.name)}, which fired while the handler was being tracked, but its function #{fun} was never invoked"}

          e.observed == true ->
            {:info,
             "Handler #{inspect(h.id)} on #{EventName.format(e.name)} was not invoked; the event fired, but not after counting for this handler started (handlers attached during the capture are picked up within 250 ms)"}

          true ->
            {:info,
             "Handler #{inspect(h.id)} on #{EventName.format(e.name)} was not invoked during the capture window"}
        end

      locations = for sh <- e.static_handlers, sh.id == h.id, do: sh.location

      d(:inactive_handler, severity, e.name, message,
        suggestion:
          if(severity == :warning,
            do:
              "Check whether the handler is detached and re-attached at runtime, or whether another node handles the event."
          ),
        locations: locations,
        detail: %{handler_id: h.id, function: fun}
      )
    end
  end

  defp fired_after?(%Event{observed: true, last_seen_at: last}, since)
       when is_integer(last) and is_integer(since),
       do: last > since

  defp fired_after?(_event, _since), do: false

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(_), do: "(unknown function)"

  # -- TS005 sensitive keys -----------------------------------------------------

  defp sensitive_keys(events) do
    for e <- events,
        {section, stats} <- [measurements: e.measurements, metadata: e.metadata],
        {key, _} <- Enum.sort(stats),
        is_atom(key),
        sensitive_key?(key) do
      d(
        :sensitive_key,
        :warning,
        e.name,
        "#{EventName.format(e.name)} #{section} contains a key named #{inspect(key)}",
        suggestion:
          "Make sure no reporter, logger or exporter attached to this event exports the value of #{inspect(key)}, or stop passing it in the event #{section}.",
        locations: emitter_locations(e),
        detail: %{section: section, key: key}
      )
    end
  end

  defp emitter_locations(%Event{call_sites: sites}),
    do: sites |> Enum.map(&CallSite.location/1) |> Enum.take(3)

  # -- TS006 modules without debug info -----------------------------------------

  defp blind_spots(%{static: %{no_debug_info: mods}} = catalog) when mods != [] do
    {project, deps} =
      Enum.split_with(mods, &Catalog.project_app?(catalog, Map.get(catalog.module_apps, &1)))

    project_diag =
      if project != [] do
        d(
          :no_debug_info,
          :warning,
          nil,
          "#{length(project)} module(s) of the project call telemetry but have no debug info; their event names are invisible to static discovery: #{list_preview(project)}",
          suggestion:
            "Compile with debug info (the Mix default; look for `debug_info: false` in :elixirc_options or :erlc_options) and scan _build, not a stripped release.",
          detail: %{modules: project}
        )
      end

    deps_diag =
      if deps != [] do
        limitation(
          :no_debug_info,
          "#{length(deps)} dependency module(s) call telemetry but have no debug info; their event names are invisible to static discovery: #{list_preview(deps)}",
          suggestion: "Their events can still be discovered with a runtime capture (--runtime).",
          detail: %{modules: deps}
        )
      end

    Enum.reject([project_diag, deps_diag], &is_nil/1)
  end

  defp blind_spots(_), do: []

  defp list_preview(items, n \\ 5) do
    shown = items |> Enum.take(n) |> Enum.map_join(", ", &inspect/1)
    if length(items) > n, do: "#{shown} (+#{length(items) - n} more)", else: shown
  end

  # -- TS007 incomplete spans ---------------------------------------------------

  defp incomplete_spans(catalog) do
    for {prefix, roles} <- Enum.sort(Catalog.spans(catalog)), roles.start != roles.stop do
      {present, missing} = if roles.start, do: {:start, :stop}, else: {:stop, :start}

      locations =
        case Catalog.get(catalog, prefix ++ [present]) do
          %Event{} = e -> emitter_locations(e)
          nil -> []
        end

      d(
        :incomplete_span,
        :info,
        prefix,
        "Span #{EventName.format(prefix)} has #{inspect(present)} but no #{inspect(missing)} event was found",
        suggestion:
          "If you emit the events by hand, emit both (or use :telemetry.span/3). If the other event is built dynamically, a runtime capture can confirm it.",
        locations: locations,
        detail: roles
      )
    end
  end

  # -- TS008 unresolved call sites ----------------------------------------------

  defp unresolved_patterns(catalog) do
    for p <- Catalog.unresolved_patterns(catalog) do
      sites = p.call_sites |> Enum.map(&CallSite.location/1) |> Enum.uniq() |> Enum.sort()

      d(
        :unresolved_call_site,
        :info,
        nil,
        "#{p.classification} event name #{EventName.format(p.pattern)} could not be resolved statically (#{length(sites)} call site(s))",
        suggestion: "Run a runtime capture (--runtime) to discover the concrete names.",
        locations: Enum.take(sites, 3),
        detail: %{pattern: EventName.format(p.pattern), call_sites: sites}
      )
    end
  end

  # -- TS009 schema drift -------------------------------------------------------

  defp schema_drift(events) do
    for e <- events,
        e.observed == true,
        {section, stats} <- [measurements: e.measurements, metadata: e.metadata],
        {key, s} <- Enum.sort(stats),
        key not in [:__too_many_keys__, :__non_atom_keys__],
        drift = drift(s),
        drift != nil do
      d(
        :schema_drift,
        :info,
        e.name,
        "#{EventName.format(e.name)} #{section}.#{key}: #{drift}",
        detail: %{
          section: section,
          key: key,
          presence: s.presence,
          types: s.types |> Map.keys() |> Enum.sort()
        }
      )
    end
  end

  defp drift(%{presence: p, types: types}) do
    non_nil = types |> Map.keys() |> Kernel.--([nil]) |> Enum.sort()

    cond do
      p < 1.0 -> "present in #{Float.round(p * 100, 1)}% of events"
      length(non_nil) > 1 -> "multiple types #{inspect(non_nil)}"
      Map.has_key?(types, nil) and non_nil != [] -> "nullable (#{inspect(hd(non_nil))} or nil)"
      true -> nil
    end
  end

  # -- TS010 no runtime handler -------------------------------------------------

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
        detail: %{status: Event.status(e)}
      )
    end
  end

  # -- TS011 capture limits -----------------------------------------------------

  defp capture_limits(%{runtime: %{trace: trace, observer: obs} = rt}) do
    trace_diags =
      case trace do
        nil when rt.trace_error != nil ->
          [
            limitation(
              :capture_limited,
              "The tracer could not run (#{format_reason(rt.trace_error)}); event names that are not in the static catalog were not discovered",
              suggestion: trace_error_suggestion(rt.trace_error),
              detail: %{component: :tracer, reason: inspect(rt.trace_error)}
            )
          ]

        %{status: status} when status in [:overload, :max_messages, :max_names] ->
          [
            limitation(
              :capture_limited,
              "The tracer stopped early (#{status}); discovery of event names that are not in the static catalog is incomplete",
              suggestion:
                "Capture for a shorter window or under less load, or raise the tracer limits (tracer: [max_names: ..., max_messages: ...]).",
              detail: %{component: :tracer, status: status}
            )
          ]

        %{gate_closures: n} when is_integer(n) and n > 0 ->
          [
            limitation(
              :capture_limited,
              "The tracer paused discovery #{n} time(s) under message pressure (#{Map.get(trace, :gated_ms, 0)} ms in total); names emitted only during those pauses were missed",
              detail: %{component: :tracer, gate_closures: n, gated_ms: Map.get(trace, :gated_ms)}
            )
          ]

        _ ->
          []
      end

    obs_diags =
      cond do
        obs[:status] == :crashed ->
          [
            limitation(
              :capture_limited,
              "The observer crashed during the capture (#{obs[:error]}); shapes and counts are missing",
              suggestion:
                "This is a TeleScope bug; please report it with the error above at https://github.com/HataluliRandima/tele_scope/issues.",
              detail: %{component: :observer, error: obs[:error]}
            )
          ]

        obs[:dropped_events] && obs[:dropped_events] > 0 ->
          [
            limitation(
              :capture_limited,
              "The observer hit :max_events; #{obs.dropped_events} event(s) were counted but not shape-recorded",
              suggestion:
                "Capture for a shorter window, sample (observer: [sample_rate: 0.1]) or raise observer: [max_events: ...].",
              detail: %{component: :observer, dropped_events: obs.dropped_events}
            )
          ]

        true ->
          []
      end

    trace_diags ++ obs_diags
  end

  defp capture_limits(_), do: []

  defp format_reason({:already_tracing, pid}),
    do: "another TeleScope tracer (#{inspect(pid)}) is already running on this VM"

  defp format_reason(reason), do: inspect(reason)

  defp trace_error_suggestion({:already_tracing, _}),
    do:
      "On OTP 26 only one TeleScope tracer can run at a time; stop the other capture, or use OTP 27+ where captures are isolated."

  defp trace_error_suggestion(_), do: nil

  # -- TS012 scan errors --------------------------------------------------------

  defp scan_errors(catalog) do
    errors = ((catalog.static || %{})[:errors] || []) |> Enum.sort_by(&inspect/1)
    {missing, errors} = Enum.split_with(errors, &(&1[:reason] == :missing_directory))

    {analysis, unreadable} =
      Enum.split_with(errors, &match?({:analysis_failed, _}, &1[:reason]))

    missing_diags =
      for e <- missing do
        limitation(
          :scan_error,
          "Directory #{e.path} (application #{inspect(e.app)}) does not exist; nothing was scanned for it",
          suggestion: "Compile the project first (mix compile) or check the :app_dirs option.",
          detail: %{app: e.app, path: e.path}
        )
      end

    unreadable_diag =
      if unreadable != [] do
        limitation(
          :scan_error,
          "#{length(unreadable)} .beam file(s) could not be read: #{unreadable |> Enum.map(&error_subject/1) |> list_preview()}",
          suggestion:
            "Rebuild the project (mix compile --force). Files with a debug-info backend other than Elixir's or Erlang's are skipped on purpose; see the :debug_info_backends option.",
          detail: %{files: Enum.map(unreadable, &format_error/1)}
        )
      end

    analysis_diag =
      if analysis != [] do
        limitation(
          :scan_error,
          "#{length(analysis)} module(s) could not be analysed: #{analysis |> Enum.map(& &1.module) |> list_preview()}",
          suggestion:
            "This is a TeleScope bug; please report it with the module name at https://github.com/HataluliRandima/tele_scope/issues.",
          detail: %{
            modules:
              Enum.map(analysis, fn %{module: m, reason: {:analysis_failed, err}} ->
                %{module: m, error: err |> to_string() |> String.split("\n") |> hd()}
              end)
          }
        )
      end

    rule_diags =
      for e <- Enum.sort_by(catalog.config_errors, &inspect(&1.rule)) do
        limitation(
          :scan_error,
          "Discovery rule #{inspect(e.rule)} failed: #{e.error}",
          suggestion:
            "Events derived from configuration by this rule are missing. Check the rule's configuration, or report the failure to the rule's author.",
          detail: %{rule: e.rule, error: e.error}
        )
      end

    missing_diags ++ Enum.reject([unreadable_diag, analysis_diag], &is_nil/1) ++ rule_diags
  end

  defp error_subject(%{path: path}), do: Path.basename(path)
  defp error_subject(%{module: mod}), do: inspect(mod)

  defp format_error(%{path: path, reason: reason}), do: %{file: path, reason: inspect(reason)}
  defp format_error(%{module: mod, reason: reason}), do: %{module: mod, reason: inspect(reason)}

  # -- TS013 runtime-only events --------------------------------------------------

  @static_sources [:static_literal, :static_resolved, :config_rule, :declared]

  defp runtime_only(_events, %{runtime: nil}), do: []

  defp runtime_only(events, catalog) do
    for e <- events,
        e.observed == true,
        not Enum.any?(@static_sources, &MapSet.member?(e.sources, &1)),
        e.name != [:telemetry, :handler, :failure] do
      matching =
        for {_, p} <- Enum.sort(catalog.patterns), e.name in p.matched, do: p

      {message, locations} =
        case matching do
          [] ->
            {"#{EventName.format(e.name)} fired, but no scanned call site names it or matches it (emitted by code that was not scanned, or through dynamic dispatch)",
             []}

          ps ->
            {"#{EventName.format(e.name)} fired; static discovery only knew it as #{Enum.map_join(ps, ", ", &EventName.format(&1.pattern))}",
             ps
             |> Enum.flat_map(& &1.call_sites)
             |> Enum.map(&CallSite.location/1)
             |> Enum.take(3)}
        end

      d(:runtime_only_event, :info, e.name, message,
        locations: locations,
        detail: %{patterns: Enum.map(matching, &EventName.format(&1.pattern))}
      )
    end
  end
end
