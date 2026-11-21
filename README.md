# TeleScope

**Telemetry discovery, observation and diagnostics for Elixir and Erlang applications.**

> Status: **release candidate** (`0.1.0-rc.1`), not yet published. Everything
> described here is implemented and tested; the API of modules grouped as
> "Internals" in the docs may still change. Evidence:
> [SPIKE_RESULTS.md](SPIKE_RESULTS.md); pre-release audit:
> [PRE_RELEASE_AUDIT.md](https://github.com/HataluliRandima/tele_scope/blob/main/PRE_RELEASE_AUDIT.md);
> roadmap: [ROADMAP.md](ROADMAP.md).

TeleScope answers four questions:

| Question | Mechanism | Cost |
|---|---|---|
| Which telemetry events **can** my app and its dependencies emit? | Static analysis of compiled `.beam` files (debug info -> Erlang abstract forms) + library rules | ~0.6 s for a Phoenix app with 840 modules; no app start |
| Which events **actually fire**, with which measurement/metadata **shapes**? | Time-boxed runtime capture: shape observer + event-name tracer | ~1-3 us per observed event + ~0.4-1.5 us per telemetry call while tracing; opt-in only |
| Which events have **handlers**, and do those handlers **run**? | `:telemetry.list_handlers([])` + `call_count` tracing | ~0.03-0.1 us per handler call while active |
| Which **Telemetry.Metrics** definitions should I write? | Heuristics over the catalog, every suggestion explained | offline |

It treats the absence of evidence carefully: an event that was not observed is
reported as `:not_observed` (in a given window), never as non-existent, and an
event without a handler is never reported as an error.

## What it found in a fresh Phoenix + Ecto + Oban + Finch app

From the spike ([spike/results](https://github.com/HataluliRandima/tele_scope/tree/main/spike/results), identical on OTP 26, 27 and 29):

* **170** emittable event names discovered statically across 36 applications in ~0.6 s
  (60 literal call sites, 65 more resolved through wrapper functions such as
  `Finch.Telemetry.start/3`, `Oban.Engine.with_span/4`, Bandit/ThousandIsland
  span helpers, plus Plug.Telemetry and Ecto rules).
* Of the **79** distinct names that actually fired under a realistic workload,
  **66 (83.5 %)** were predicted exactly by static analysis; 11 more matched a
  specific partial pattern (e.g. `[:bandit, *, :stop]`), and the remaining 2 were
  genuinely dynamic. All 13 were discovered by the runtime tracer.
* Deliberate mistakes in the fixture app were all caught:

```
[error]   handler_failure: Handler "demo-app-crasher" raised (:error) 1 time(s) and was detached by :telemetry
[warning] consumer_without_emitter: [:demo_app, :order, :created] is consumed by metric demo_app.order.created.count
          (lib/demo_app_web/telemetry.ex:81), handler "demo-app-typo" (lib/demo_app/instrumentation/handlers.ex:21)
          but no emitter found in scanned code; did you mean [:demo_app, :orders, :created]?
[warning] metric_measurement_missing: Metric demo_app.orders.created.total_amount reads measurement :total_amount
          which was never observed on [:demo_app, :orders, :created] (seen: :count, :total_cents)
[warning] sensitive_key: [:demo_app, :orders, :created] metadata contains a key named :password_hint; ...
```

The typo diagnostic works **statically** (no app start), so `mix telemetry.check --strict`
can run in CI.

Shapes, never values:

```
demo_app.orders.created          observed   count=15   handlers=1
    measurements: count: integer, total_cents: integer
    metadata: currency: binary, order_id: integer, coupon: nil|binary,
              customer: %DemoApp.Instrumentation.Customer{}, password_hint: binary
demo_app.repo.query              observed   count=113
    rule: Ecto query event for DemoApp.Repo (default prefix derived from DemoApp.Repo)
    measurements: decode_time: integer 91%, idle_time: integer 87%, queue_time: integer 87%,
                  query_time: integer, total_time: integer
```

## Usage

Add the dependency. TeleScope is a development tool: keep it out of
production releases with `only:` and `runtime: false` (it is still available
in `iex -S mix` during development):

```elixir
# once published (pre-releases must be requested explicitly)
{:tele_scope, "~> 0.1.0-rc.1", only: [:dev, :test], runtime: false}

# until then
{:tele_scope, github: "HataluliRandima/tele_scope", only: [:dev, :test], runtime: false}
```

Static discovery needs debug info, which Mix includes by default in `dev` and
`test` builds. Run it against `_build`, not against a stripped release.

### CLI

```sh
mix telemetry.explore                          # static discovery
mix telemetry.explore --verbose                # + call sites, rules, shapes, handlers
mix telemetry.explore --runtime --duration 15000   # start the app, capture for 15 s
mix telemetry.explore --runtime --serve        # Phoenix: start endpoints like phx.server
mix telemetry.explore --app my_app             # only events of my_app (repeatable)
mix telemetry.explore --metrics                # + Telemetry.Metrics suggestions
mix telemetry.explore --format json --output telescope.json
mix telemetry.check                            # diagnostics; non-zero exit on errors
mix telemetry.check --strict                   # ... and on warnings (CI)
```

`--runtime` begins the capture *before* the application starts, so startup
events (`[:phoenix, :endpoint, :init]`, `[:ecto, :repo, :init]`, Oban plugin
init, ...) are observed. Drive traffic during the window to observe request
events.

### From IEx (running system)

```elixir
catalog = TeleScope.scan()                               # static
catalog = TeleScope.capture(catalog, duration: 10_000)   # blocking, time-boxed

# or non-blocking
{:ok, cap} = TeleScope.start_capture(catalog, duration: 60_000)
# ... exercise the system ...
catalog = TeleScope.stop_capture(catalog, cap)

TeleScope.diagnose(catalog)
TeleScope.recommend_metrics(catalog) |> TeleScope.Metrics.to_code() |> IO.puts()
TeleScope.report(catalog, format: :json)
```

Runtime capture options (all bounded by default): `:duration`, `trace: false`
(observer only), `observer: [sample_rate: 0.1, max_events: ..., max_keys: ...]`,
`tracer: [max_mailbox: ..., max_names: ..., backend: :session | :legacy]`.

## How it works (short)

* **Static:** every `.beam` under `_build/ENV/lib/*/ebin` is indexed by its
  `imports` chunk (cheap, always present). Only modules that call telemetry,
  `Telemetry.Metrics`, a rule-watched function or a discovered *wrapper* are
  decoded (48 of 840 in the spike). Abstract forms are evaluated symbolically:
  literals, constant propagation, `if`/`case` alternatives, `prefix ++ [:x]`,
  local helper functions, and **wrapper resolution across modules**
  (`Finch.Telemetry.start(:request, ...)` -> `[:finch, :request, :start]`).
* **Rules:** an extension point for knowledge not visible in code
  (Ecto's `telemetry_prefix` from config / `@behaviour Ecto.Repo`;
  `plug Plug.Telemetry, event_prefix: ...` in either plug init mode).
* **Tracer:** call tracing on `telemetry:execute/3` and `execute_lazy/3` with
  the `arity` process flag and a match spec that appends **only the event
  name**: measurements and metadata are never copied. Known names are
  suppressed in the match spec through an O(1) `is_map_key` guard, so each
  name produces a handful of messages, not one per event. Uses isolated trace
  sessions on OTP 27+.
* **Observer:** a `:telemetry` handler that records key -> type shapes into
  per-scheduler striped ETS rows; never raises, never stores values, bounded
  in rows, shapes and events.

Details: [ARCHITECTURE.md](ARCHITECTURE.md). Measurements: [BENCHMARKS.md](BENCHMARKS.md).
What it cannot do: [LIMITATIONS.md](LIMITATIONS.md).

## Safety and privacy defaults

* Nothing starts with the application; runtime capture is explicit, time-boxed
  (tracer: 10 s default, 10 min max unless `allow_long: true`) and stops when
  its owner process dies.
* No measurement or metadata *value* is stored, ever: only key names and type
  tags. Structs keep only their module name. Non-atom map keys (often user
  data) are collapsed. Handler `config` terms are never copied (type only).
  The tracer never copies other processes' dictionaries.
* Bounded memory: observer rows (`max_rows`), shapes per event, events
  (soft cap), tracer names and messages. The tracer's mailbox is protected by
  adaptive suppression, a pressure gate (closes in ~2 us and is reported as
  `gated_ms`) and a last-resort circuit breaker.
* On OTP 26 only one tracer can run at a time (`{:error, {:already_tracing,
  pid}}`); OTP 27+ trace sessions are isolated from each other and from other
  tracing tools.
* Static analysis never executes scanned code; only the debug-info backends
  shipped with Erlang/OTP and Elixir are used to decode `.beam` files.
* Cleanup is verified by tests for `:kill` of every component: handlers are
  detached by a janitor, trace patterns removed, sessions destroyed.
* Sensitive-looking metadata keys (`password`, `token`, `secret`, ...) are
  reported as warnings because reporters attached to those events may export them.

## Compatibility

Tested ([experiments/results/test_matrix_*](https://github.com/HataluliRandima/tele_scope/tree/main/experiments/results)) on:

| Elixir | OTP | Tracing backend | Tests |
|---|---|---|---|
| 1.15.8 | 26.1.2 | legacy `erlang:trace/3` | 98 tests + 2 doctests pass |
| 1.17.0 | 26.1.2 | legacy | 98 + 2 pass |
| 1.17.0 | 27.0 | trace sessions | 98 + 2 pass |
| 1.20.1 | 29.0 | trace sessions | 98 + 2 pass |

`:telemetry` 1.0 to 1.4 are tested. Handler-failure detection needs
telemetry >= 1.1 (1.0 does not emit `[:telemetry, :handler, :failure]`).

## Repository layout

```
lib/tele_scope.ex                  public API
lib/tele_scope/event_name.ex       symbolic event names (literal/partial/dynamic patterns)
lib/tele_scope/event.ex            Event struct, status & confidence
lib/tele_scope/catalog.ex          central catalog, evidence merging
lib/tele_scope/discovery/          beam.ex, eval.ex, analyzer.ex, scanner.ex, rule.ex, rules/
lib/tele_scope/runtime/            tracer.ex, observer.ex, shape.ex, handlers.ex, capture.ex
lib/tele_scope/diagnostics.ex      checks
lib/tele_scope/metrics.ex          Telemetry.Metrics suggestions
lib/tele_scope/reporters/          console.ex, json.ex (dependency-free encoder)
lib/mix/tasks/                     telemetry.explore, telemetry.check
test/                              98 tests (static, runtime, failure modes, multi-node, audit regressions)
experiments/                       standalone experiments + raw results
bench/                             benchmarks + raw results
spike/demo_app                     Phoenix/Ecto/Oban/Finch spike application
spike/results                      spike reports (txt/json) per OTP version
scripts/matrix.sh                  test matrix across installed Elixir/OTP
```

Only runtime dependency: `:telemetry`.
