# Diagnostics reference

Every diagnostic TeleScope reports has a **stable code**. A code never
changes meaning and is never reused, so you can reference codes in CI
logs, issues and documentation. The same list is available at runtime from
`TeleScope.Diagnostics.definitions/0`.

| Code | Check | Severity | Needs |
|---|---|---|---|
| [TS001](#ts001-handler-raised-and-was-detached) | `handler_failure` | error | runtime |
| [TS002](#ts002-consumer-references-an-event-nothing-emits) | `consumer_without_emitter` | warning / info | static |
| [TS003](#ts003-metric-reads-a-measurement-the-event-does-not-carry) | `metric_measurement_missing` | warning / info | runtime |
| [TS004](#ts004-attached-handler-was-not-invoked) | `inactive_handler` | warning / info | runtime |
| [TS005](#ts005-sensitive-looking-key-in-event-data) | `sensitive_key` | warning | runtime |
| [TS006](#ts006-telemetry-calling-modules-without-debug-info) | `no_debug_info` | warning / info | static |
| [TS007](#ts007-span-with-a-start-but-no-stop) | `incomplete_span` | info | static |
| [TS008](#ts008-event-name-could-not-be-resolved-statically) | `unresolved_call_site` | info | static |
| [TS009](#ts009-inconsistent-measurement-or-metadata-shape) | `schema_drift` | info | runtime |
| [TS010](#ts010-event-has-no-handler-attached) | `no_runtime_handler` | info | runtime |
| [TS011](#ts011-runtime-capture-was-incomplete) | `capture_limited` | info (limitation) | runtime |
| [TS012](#ts012-part-of-the-build-could-not-be-scanned) | `scan_error` | info (limitation) | static |
| [TS013](#ts013-event-fired-that-static-discovery-did-not-predict) | `runtime_only_event` | info | runtime |

"Needs runtime" means the diagnostic only appears with `--runtime` (or
after `TeleScope.capture/2`), because it relies on events having actually
fired.

## Severity and exit status

* **error**: something is demonstrably broken. `mix telemetry.check` fails.
* **warning**: very likely a mistake in the project. `mix telemetry.check
  --strict` fails.
* **info**: worth knowing, often fine. Never fails a check. Hidden from
  console output unless `--verbose` is given (JSON always includes it).

A **limitation** is an info diagnostic about what TeleScope could *not*
see, such as an unreadable module or a tracer that stopped early. It is
not a defect of your project, so it never fails a check, even in strict
mode. Console output always shows limitations, because they qualify every
other result.

`mix telemetry.check` exits `0` when the check passes, `1` when failing
diagnostics were found, and `2` on invalid usage or when the runtime
capture could not start.

TeleScope is conservative by design. It never reports an event as dead
because it did not fire in a capture window, and it never reports an
event without handlers as a problem.

## Console output

```text
[WARNING] TS002 Consumer references an event nothing emits (fails check)
  Event:      [:demo_app, :order, :created]
  Problem:    [:demo_app, :order, :created] is consumed by handler "demo-app-typo", metric demo_app.order.created.count, but no emitter was found in the scanned code
  Location:   lib/demo_app/instrumentation/handlers.ex:21
              lib/demo_app_web/telemetry.ex:81
  Suggestion: Did you mean [:demo_app, :orders, :created]? Check the event name in the metric or handler definition.

Result: FAILED (strict: errors and warnings fail): 0 errors, 1 warning, 36 info (36 hidden; use --verbose)
```

## JSON output

`mix telemetry.check --format json` prints one document:

```json
{
  "schema_version": 1,
  "status": "failed",
  "strict": true,
  "exit_code": 1,
  "counts": {"error": 0, "warning": 1, "info": 36},
  "runtime_captured": false,
  "summary": {"events": 186, "...": "..."},
  "diagnostics": [
    {
      "code": "TS002",
      "check": "consumer_without_emitter",
      "severity": "warning",
      "limitation": false,
      "fails_check": true,
      "title": "Consumer references an event nothing emits",
      "event": ["demo_app", "order", "created"],
      "message": "...",
      "suggestion": "Did you mean [:demo_app, :orders, :created]? ...",
      "locations": ["lib/demo_app/instrumentation/handlers.ex:21"],
      "detail": {"similar": [["demo_app", "orders", "created"]], "project_consumer": true}
    }
  ]
}
```

`detail` is check-specific and may gain fields. The JSON schema is
version 1 and is not frozen before TeleScope 1.0; fields are only added,
not renamed, within a schema version.

---

## TS001 Handler raised and was detached

Check `handler_failure` · **error** · runtime

A handler raised an exception while handling an event during the capture.
`:telemetry` detaches a handler the first time it raises, so the handler
silently stops receiving the event for the rest of the VM's life. Metrics
or logs fed by it stop without notice.

**Fix:** telemetry logs the exception with a stacktrace when it detaches
the handler. Fix the exception, and make the handler tolerate every
measurement and metadata shape the event can carry (see TS009).

Requires `:telemetry` 1.1 or later (1.0 does not emit
`[:telemetry, :handler, :failure]`).

## TS002 Consumer references an event nothing emits

Check `consumer_without_emitter` · **warning** or info · static

A handler (`:telemetry.attach/4`, `attach_many/4`) or a `Telemetry.Metrics`
definition references an event name, but no emitter for it was found.

* **warning**: the consumer is in your project and no dynamic call site
  could produce the name. Usually a typo (`:order` vs `:orders`) or a
  span-naming slip (`[:oban, :notifier, :exception]` vs
  `[:oban, :notifier, :notify, :exception]`). TeleScope suggests similar
  emitted names.
* **info**: a dynamic call site with a known namespace could emit the
  name (for example `[:bandit, *, :stop]`), or the consumer lives in a
  dependency (often an optional integration for a library you do not use).

**Fix:** correct the event name. If the event really is emitted by code
TeleScope cannot see, confirm it with `--runtime`.

**Known false positives:** events emitted only by code that is not in
`_build` (or compiled without debug info, see TS006), or through
`apply/3` with a computed module.

## TS003 Metric reads a measurement the event does not carry

Check `metric_measurement_missing` · **warning** or info · runtime

The event fired during the capture, but never with the measurement that a
`Telemetry.Metrics` definition reads (the last segment of the metric name,
or its `measurement:` option). The metric produces no data.

```text
[WARNING] TS003 Metric reads a measurement the event does not carry
  Event:      [:my_app, :orders, :processed]
  Problem:    Metric my_app.orders.processed.duration_ms reads measurement :duration_ms, which was never observed on [:my_app, :orders, :processed] (seen: :duration)
  Suggestion: Did you mean :duration? Check the measurement name (or the :measurement option) in the metric definition.
```

It is **info** when a rule declares the measurement optional (for example
Ecto's `:idle_time`, absent under the SQL sandbox). Counters and metrics
with a function as `measurement:` are not checked.

## TS004 Attached handler was not invoked

Check `inactive_handler` · **warning** or info · runtime

A handler was attached during the capture, but its function was never
called.

* **warning**: the event fired *after* invocation counting for that handler
  had started. Telemetry calls every attached handler, so this points to a
  handler that was detached and re-attached, or to a different VM handling
  the event.
* **info**: the event did not fire in the window, or only fired before the
  handler was picked up (handlers attached during the capture are picked
  up within 250 ms).

Counting is per function. When several handler ids share one function,
TeleScope cannot attribute calls and does not report this diagnostic.

## TS005 Sensitive-looking key in event data

Check `sensitive_key` · **warning** · runtime

An observed measurement or metadata key is named like a secret:
`password`, `token`, `secret`, `api_key`, `authorization`, `cookie`,
`credit_card`, `session_id`, ... Reporters, loggers and exporters attached
to the event may ship the value to a third party. Only key *names* are
inspected; TeleScope never records values.

Matching works on whole `_`-, `-`-, `.`- or camelCase-separated words, so
`author_id`, `passenger_count` and `tokenizer_ms` are not flagged.

**Fix:** make sure nothing attached to the event exports that value, or
stop passing it in the event.

## TS006 Telemetry-calling modules without debug info

Check `no_debug_info` · **warning** or info (limitation) · static

Modules that call telemetry were compiled without debug info, so static
discovery cannot see which events they emit.

* **warning** for your project's own modules: the cause is usually
  `debug_info: false` in `:elixirc_options` / `:erlc_options`, or scanning a
  stripped release instead of `_build`.
* **info (limitation)** for dependencies: their events can still be found
  with `--runtime`.

## TS007 Span with a :start but no :stop

Check `incomplete_span` · info · static

An event ending in `:start` was found without the matching `:stop`, or
the reverse. Duration metrics and span-aware reporters need both. Often
the other half is emitted with a dynamically built name, which a runtime
capture can confirm.

## TS008 Event name could not be resolved statically

Check `unresolved_call_site` · info · static

A telemetry call builds its event name from data that static analysis
cannot follow (a struct field, a runtime value, configuration read at
runtime), and no known name matches the resulting pattern. Run a capture
(`--runtime`) to discover the concrete names; a resolved pattern then
disappears from this list and its names appear as TS013.

## TS009 Inconsistent measurement or metadata shape

Check `schema_drift` · info · runtime

A key was missing from some occurrences of an event, had several types,
or was sometimes `nil`. Metrics, tags and handlers that read it must
tolerate that.

## TS010 Event has no handler attached

Check `no_runtime_handler` · info · runtime

No handler was attached to an emitted event during the capture. This is
usually fine: libraries emit events for optional consumers. It is listed
so you can see which events are available but unused.

## TS011 Runtime capture was incomplete

Check `capture_limited` · info (limitation) · runtime

Part of the runtime capture did not work as intended, so runtime results
are incomplete:

* the tracer could not start (on OTP 26 only one TeleScope tracer can run
  per VM) or crashed: names absent from the static catalog were not
  discovered. The capture continues with the observer only;
* the tracer stopped early (`overload`, `max_messages`, `max_names`) or
  paused under message pressure: names emitted only during that time were
  missed;
* the observer hit `:max_events` (events were counted but their shapes not
  recorded) or crashed.

## TS012 Part of the build could not be scanned

Check `scan_error` · info (limitation) · static

A configured `ebin` directory does not exist, a `.beam` file could not be
read (corrupt, truncated, or with a debug-info backend other than
Elixir's or Erlang's, which TeleScope refuses to call), a module could not
be analysed (a TeleScope bug: please report it), or a discovery rule
raised. Events defined there may be missing from the catalog.

## TS013 Event fired that static discovery did not predict

Check `runtime_only_event` · info · runtime

An event fired during the capture although no static evidence names it.
Either its name is built dynamically (the diagnostic then shows the
partial pattern static discovery knew, and where it is), or it is emitted
by code that was not scanned. This is the bridge between static and
runtime results; it is expected for libraries such as Bandit or
ThousandIsland that compute names from struct fields.
