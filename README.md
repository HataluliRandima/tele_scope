# TeleScope

**Find, observe and check the `:telemetry` events of an Elixir or Erlang
application, including those emitted by its dependencies.**

> Status: **release candidate** (`0.1.0-rc.1`), not yet published on Hex.
> The CLI, the diagnostic codes and the `TeleScope` module are the
> supported interface; modules grouped as "Internals" in the docs may
> still change. See the [CHANGELOG](CHANGELOG.md) and [ROADMAP](ROADMAP.md).

## Why

Most Elixir libraries report what they do through
[`:telemetry`](https://hexdocs.pm/telemetry) events: Phoenix, Ecto, Oban,
Finch, Bandit and your own code. Using them well is harder than it looks:

* There is no list of the events your application *can* emit. You read
  library source code or documentation that may be out of date.
* A typo in a handler or a `Telemetry.Metrics` definition
  (`[:my_app, :order, :created]` instead of `[:my_app, :orders, :created]`)
  fails silently: the handler never runs and the metric stays empty.
* A handler that raises is detached by `:telemetry` the first time it
  fails, and is never called again.
* You cannot see which measurements and metadata keys an event actually
  carries without attaching handlers by hand.

TeleScope answers these questions from your build output and, if you ask,
from the running application, and turns the answers into a CI check.

## What it does

| Question | How TeleScope answers it |
|---|---|
| Which events **can** my app and its dependencies emit? | Static analysis of the compiled `.beam` files, without starting the app |
| Which events **actually fire**, with which measurement and metadata **shapes**? | A time-boxed runtime capture you start explicitly |
| Which events have **handlers**, and do those handlers **run** (or crash)? | Handler inspection and invocation counting during a capture |
| Do my handlers and metrics reference events and measurements that **exist**? | Diagnostics with stable codes, a CI command, and a strict mode |
| Which `Telemetry.Metrics` definitions would be useful? | Suggestions, each with its reason and a confidence |

TeleScope records **shapes, never values**: key names and types such as
`total_cents: integer`, never the numbers, strings or structs themselves.

## How it works

* **Static discovery.** Every `.beam` under `_build/ENV/lib/*/ebin` is
  indexed by its import table. Only modules that call telemetry (or a
  function that wraps it) are decoded from their debug info into Erlang
  abstract forms and evaluated symbolically: literals, module attributes,
  local variables, `if`/`case` branches, `prefix ++ [:stop]`, helper
  functions, and wrapper functions across modules (for example
  `Finch.Telemetry.start(:request, ...)` resolves to
  `[:finch, :request, :start]`). Rules add knowledge that is not in the code,
  such as an Ecto repo's `telemetry_prefix` or a `Plug.Telemetry` event
  prefix. Scanned code is never loaded or executed.
* **Runtime capture** (opt-in, time-boxed). An *observer* handler records
  the shape of each known event. A *tracer* uses call tracing on
  `:telemetry.execute/3` to discover event names that static analysis could
  not resolve, and receives only the event name, never the payload.
  Handler functions are counted with `call_count` tracing.
* **Catalog.** Both sources are merged per event name, with the evidence
  for each one (literal call site, resolved through a wrapper, configured,
  observed, ...). Diagnostics, metric suggestions and reports are computed
  from this catalog.

An event that did not fire during a capture is reported as `not_observed`
*in that window*, never as dead. An event without handlers is never
reported as a problem. Details: [ARCHITECTURE.md](ARCHITECTURE.md).

## Installation

TeleScope is a development tool. Add it to `mix.exs` for `dev` and `test`
only, so it never ships in a release:

```elixir
def deps do
  [
    # until 0.1.0 is published on Hex:
    {:tele_scope, github: "HataluliRandima/tele_scope", only: [:dev, :test], runtime: false}

    # once published (pre-releases must be requested explicitly):
    # {:tele_scope, "~> 0.1.0-rc.1", only: [:dev, :test], runtime: false}
  ]
end
```

```sh
mix deps.get
```

Requirements: Elixir 1.15+, Erlang/OTP 26+, `:telemetry` 1.x (handler
failure detection needs 1.1+). Static discovery needs debug info, which
Mix includes by default in `dev` and `test` builds; scan `_build`, not a
stripped release.

## Quick start

```sh
# 1. Which events can my application emit? (static, nothing is started)
mix telemetry.explore

# 2. Only my own application's events, with call sites and shapes
mix telemetry.explore --app my_app --verbose

# 3. Is anything wrong? (non-zero exit on errors; on warnings with --strict)
mix telemetry.check

# 4. Start the app, observe it for 15 s, and check again with runtime evidence
mix telemetry.check --runtime --duration 15000
```

For a Phoenix application, add `--serve` to `--runtime` so endpoints listen
(as with `mix phx.server`), and send requests during the capture window.

## CLI

### `mix telemetry.explore`

Prints the catalog: one line per event with its status, the strongest
evidence for it, the observed count and the number of handlers, followed
by call sites whose event names could not be resolved, and diagnostics.

```sh
mix telemetry.explore                          # static discovery
mix telemetry.explore --verbose                # + call sites, rules, shapes, handlers
mix telemetry.explore --app my_app             # only events of my_app (repeatable)
mix telemetry.explore --metrics                # + Telemetry.Metrics suggestions
mix telemetry.explore --format json --output telescope.json
mix telemetry.explore --runtime --duration 15000   # start the app, capture for 15 s
mix telemetry.explore --runtime --serve        # Phoenix: start endpoints like phx.server
mix telemetry.explore --runtime --no-trace     # observe known events only
```

Shapes, never values (excerpt from `--runtime --verbose`):

```text
demo_app.orders.created          observed   count=15   handlers=1
    measurements: count: integer, total_cents: integer
    metadata: currency: binary, order_id: integer, coupon: nil|binary,
              customer: %DemoApp.Instrumentation.Customer{}, password_hint: binary
```

`--runtime` starts the capture *before* the application, so startup events
such as `[:phoenix, :endpoint, :init]` and `[:ecto, :repo, :init]` are
observed.

### `mix telemetry.check`

Runs the diagnostics and exits with a status your CI can use.

```sh
mix telemetry.check                    # fail on errors
mix telemetry.check --strict           # fail on errors and warnings
mix telemetry.check --verbose          # also print informational diagnostics
mix telemetry.check --format json      # machine-readable result on stdout
mix telemetry.check --format json --output telescope-check.json
mix telemetry.check --runtime --duration 5000 --strict
```

| Exit status | Meaning |
|---|---|
| `0` | The check passed |
| `1` | Failing diagnostics were found: errors, plus warnings with `--strict` |
| `2` | Invalid usage, or the runtime capture could not start |

A compilation failure of your project exits non-zero, as reported by
`mix compile`. Strict mode never fails on *limitations*: things TeleScope
could not see, such as a dependency compiled without debug info.

In GitHub Actions:

```yaml
- run: mix telemetry.check --strict
```

With `--format json` and no `--output`, stdout carries only the JSON
document; compilation and progress messages go to stderr. With `--runtime`,
prefer `--output`, because your application's own logs also go to stdout.

### Example diagnostic

Real output for the Phoenix application in `spike/demo_app`, which
contains a deliberate typo:

```text
$ mix telemetry.check --strict
TeleScope: 186 events from 840 modules (48 analysed); static analysis only (add --runtime to observe the running application)

[WARNING] TS002 Consumer references an event nothing emits (fails check)
  Event:      [:demo_app, :order, :created]
  Problem:    [:demo_app, :order, :created] is consumed by handler "demo-app-typo", metric demo_app.order.created.count, but no emitter was found in the scanned code
  Location:   lib/demo_app/instrumentation/handlers.ex:21
              lib/demo_app_web/telemetry.ex:81
  Suggestion: Did you mean [:demo_app, :orders, :created]? Check the event name in the metric or handler definition.

Result: FAILED (strict: errors and warnings fail): 0 errors, 1 warning, 36 info (36 hidden; use --verbose)
```

Every diagnostic has a stable code:

| Code | Finds | Severity |
|---|---|---|
| TS001 | A handler raised and was detached by `:telemetry` | error |
| TS002 | A handler or metric references an event nothing emits (typos) | warning / info |
| TS003 | A metric reads a measurement the event does not carry | warning / info |
| TS004 | An attached handler was not invoked | warning / info |
| TS005 | Sensitive-looking keys (`password`, `token`, ...) in event data | warning |
| TS006 | Telemetry-calling modules without debug info | warning / info |
| TS007 | A span with `:start` but no `:stop` (or the reverse) | info |
| TS008 | An event name that could not be resolved statically | info |
| TS009 | Inconsistent measurement or metadata shapes | info |
| TS010 | An event without any handler | info |
| TS011 | The runtime capture was incomplete | info (limitation) |
| TS012 | Part of the build could not be scanned | info (limitation) |
| TS013 | An event fired that static discovery did not predict | info |

What each one means, when it is a false positive, and how to fix it:
[DIAGNOSTICS.md](DIAGNOSTICS.md).

## From IEx or code

```elixir
catalog = TeleScope.scan()                               # static
catalog = TeleScope.capture(catalog, duration: 10_000)   # blocking, time-boxed

# or non-blocking
{:ok, cap} = TeleScope.start_capture(catalog, duration: 60_000)
# ... exercise the system ...
catalog = TeleScope.stop_capture(catalog, cap)

diagnostics = TeleScope.diagnose(catalog)
TeleScope.Diagnostics.evaluate(diagnostics, strict: true)
#=> %{status: :passed, counts: %{error: 0, warning: 0, info: 12}, ...}

TeleScope.recommend_metrics(catalog) |> TeleScope.Metrics.to_code() |> IO.puts()
TeleScope.report(catalog, format: :json)
```

Capture options (all bounded by default): `:duration`, `trace: false`
(observer only), `observer: [sample_rate: 0.1, max_events: ...]`,
`tracer: [max_names: ..., max_mailbox: ...]`. A capture belongs to the
process that started it and is cleaned up if that process exits.
`capture/2` and `stop_capture/2` raise `TeleScope.CaptureError` with an
explanation when a capture cannot start or is no longer running.

## Supported

* Event emission through `:telemetry.execute/2,3`, `execute_lazy/2,3` and
  `span/3`, from Elixir and Erlang modules, in the project and in
  dependencies.
* Event names built from literals, module attributes, local variables,
  branches, list concatenation, helper functions and wrapper functions
  across modules. Names that stay partly unknown are kept as patterns such
  as `[:bandit, *, :stop]` and linked to the concrete names seen at runtime.
* Handlers registered with `:telemetry.attach/4` and `attach_many/4`;
  `Telemetry.Metrics` definitions (`counter`, `sum`, `last_value`, `summary`,
  `distribution`) including `event_name:` and `measurement:` options.
* Rules for Ecto repositories (`telemetry_prefix`) and `Plug.Telemetry`
  (`event_prefix`); custom rules through `TeleScope.Discovery.Rule`.
* `telemetry_registry`-style `telemetry_event` declarations.
* Runtime capture on OTP 26 (legacy tracing) and OTP 27+ (isolated trace
  sessions), including startup events, and capture on a remote node
  merged into a local catalog.
* Console and JSON reports; `Telemetry.Metrics` suggestions with reasons.

## Known limitations

TeleScope reports evidence; it never claims completeness. The most
important limitations:

* **Static discovery cannot see everything.** Names computed from runtime
  data (struct fields, configuration read at runtime, user input),
  `apply/3` with a computed module, and code without debug info are
  invisible statically. Such names are reported as patterns (TS008) and can
  be discovered with `--runtime`.
* **A capture is a window.** "Not observed" means not observed while
  TeleScope was watching, not that the event cannot fire.
* **Runtime capture costs something** while it runs: about 0.4-1.5 us per
  telemetry call for the tracer and 1-3 us per observed event
  ([BENCHMARKS.md](BENCHMARKS.md)). That is why it is opt-in and time-boxed.
* **On OTP 26 only one TeleScope tracer can run per VM**, and tracing can
  interfere with other tracing tools (dbg, recon). OTP 27+ isolates them.
  If the tracer cannot start, the capture continues without it and says so
  (TS011).
* **Handler invocation counts are per function**, not per handler id.
* **Multi-node**: a capture covers one node.
* **Shapes are one level deep**: nested maps are `map`, lists are `list`.

The full list, by component: [LIMITATIONS.md](LIMITATIONS.md).

## Safety and privacy

* Nothing starts with your application. Runtime capture is explicit,
  time-boxed (tracer: 10 s by default, 10 min maximum unless
  `allow_long: true`) and stops when the process that started it exits.
* No measurement or metadata value is stored, only key names and type
  tags. Structs keep only their module name. Handler configs are never
  copied (type only).
* Memory is bounded: observer rows, shapes per event, attached events,
  tracer names, messages and mailbox (with a backpressure gate and a
  circuit breaker).
* Static analysis never executes scanned code, and only decodes debug info
  with the backends shipped by Erlang/OTP and Elixir.
* Cleanup after a `:kill` of any TeleScope process is covered by tests:
  handlers are detached, trace patterns removed, sessions destroyed.

Security notes and trust boundaries:
[SECURITY_REVIEW.md](https://github.com/HataluliRandima/tele_scope/blob/main/SECURITY_REVIEW.md).

## Validation

* On three open-source Phoenix code bases ([VALIDATION.md](VALIDATION.md)),
  static discovery predicted **91.1 %** (hexpm) and **100 %** (changelog.com)
  of the event names fired by their full test suites, in about 1 s for
  2,600-4,000 modules. `mix telemetry.check --strict` raised no false
  warnings, and found a real bug in plausible/analytics: a handler attached
  to `[:oban, :notifier, :exception]`, an event Oban never emits.
* On a fresh Phoenix + Ecto + Oban + Finch application (`spike/`),
  static discovery found 170 emittable event names across 36 applications
  in about 0.6 s; 66 of the 79 names that fired under load (83.5 %) were
  predicted exactly, and the rest were discovered by the tracer
  ([SPIKE_RESULTS.md](SPIKE_RESULTS.md)).
* CI runs the test suite on Elixir 1.15 to 1.20 with OTP 26 to 29, on
  `:telemetry` 1.0 to 1.4, and runs `mix telemetry.check --strict` on a
  freshly generated Phoenix application.

## Contributing

Bug reports, false positives and false negatives are especially welcome:
include the event, the library and its version. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, the test
suite and how to add a diagnostic or a discovery rule.

## License

MIT, see [LICENSE](https://github.com/HataluliRandima/tele_scope/blob/main/LICENSE).
