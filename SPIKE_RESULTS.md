# Spike results

All numbers below come from scripts in this repository; raw outputs are
committed next to them ([experiments/results](experiments/results),
[bench/results](bench/results), [spike/results](spike/results)).

**Environment.** Linux 6.6 (WSL2), 12 schedulers, 7 GB RAM. Erlang/OTP 26.1.2,
27.0, 29.0; Elixir 1.15.8, 1.17.0, 1.20.1 (asdf). telemetry 1.4.3. Phoenix
1.8.17, Ecto SQL 3.13 (SQLite via ecto_sqlite3), Oban 2.x (Lite engine),
Finch 0.x, Bandit 1.15, LiveView 1.2. WSL2 timing noise is significant (the
same baseline varies 140-480 ns between runs); see BENCHMARKS.md for how this
was handled.

## 1. Answers to the spike questions

| Question | Answer | Evidence |
|---|---|---|
| Can compiled-code discovery reliably extract event call sites? | **Yes**, for code with debug info. In the spike app every real call site in dependency source was found (grep baseline: per-app counts equal once doc examples and `quote` bodies are excluded). Missing debug info and corrupt BEAMs are detected and reported, never crash. | §3.1, `spike/results/static_coverage_otp26.txt`, tests in `static_discovery_test.exs` |
| What percentage of relevant events can be statically resolved? | **83.5 %** of event names that actually fired were predicted exactly (66/79), identical on OTP 26/27/29. At call-site level 67.7 % of name-decision sites are literal (after wrapper resolution), 30.1 % partial, 2.2 % dynamic. Literal-only extraction (no wrapper resolution) would cover 60 of those 126 literal sites. | §3.3 |
| Can runtime tracing discover dynamic names? | **Yes.** All 13 fired names that static analysis could not resolve were discovered by the tracer (Bandit/ThousandIsland span names from struct fields, config-driven prefixes, string-built names). | §3.3, `pipeline_test.exs`, `tracer_test.exs` |
| Can tracing avoid copying large telemetry arguments? | **Yes.** With the `arity` process flag and a `{message, '$1'}` match spec, each message is 14-16 words regardless of payload (2,044 words without `arity` for 10 KB metadata). Verified on OTP 26, 27, 29. | §2.1 |
| Can handler inspection identify listeners accurately? | **Yes for registration** (`list_handlers([])` enumerates everything, `attach_many` expands per event). **Invocation counts are exact per function**, not per handler id; shared functions are detected and flagged as not attributable. | §2.4 |
| Can the shape observer operate safely? | **Yes**, after two redesigns driven by benchmarks. Never raises (verified with a killed observer), never stores values (verified by searching snapshots for raw values), bounded rows/shapes/events, cleanup on `:kill` verified. | §2.5, `observer_test.exs` |
| What is the measured runtime overhead? | Observer: **+1.1-1.2 us/event** (4 metadata keys), **+2.2-3.1 us** (30 keys); with `sample_rate: 0.1`: +0.37-0.62 us. Tracer (name known/suppressed): **+0.35-0.69 us per telemetry call VM-wide**. Without suppression the tracer mailbox reaches 500k messages: suppression and the circuit breaker are mandatory. Static scan: ~0.6 s / 47 MB for 840 modules. | BENCHMARKS.md |

## 2. Experiments

### 2.1 What does a trace message carry? (`experiments/trace_shape_experiment.exs`)

Hypotheses and results (OTP 26.1.2, 27.0, 29.0 - identical):

| # | Hypothesis | Result |
|---|---|---|
| H1 | Without `arity`, measurements and metadata are copied to the tracer | **Confirmed**: 2,044-2,046 words per message for 10 KB metadata |
| H2 | With `arity`, `{message, '$1'}` appends only the event name | **Confirmed**: `{trace, Pid, call, {telemetry, execute, 3}, [:exp, :plain]}`, 14 words |
| H3 | `global` patterns miss `span/3` (local call to `execute/3`) | **Confirmed**: span start/stop only with `local` |
| H4 | `execute_lazy/3` bypasses `execute/3` | **Confirmed** by source reading (`do_execute/4` directly) and tracing both |
| H5 | `{message, false}` clauses suppress known names | **Confirmed** (later replaced, see 2.3) |

**Failed assumption found:** the first run of H1 produced *no messages at
all*. `erlang:trace_pattern/3` silently matched 0 functions because the
`telemetry` module was not loaded yet (interactive code loading). The tracer
now calls `Code.ensure_loaded(:telemetry)` and fails loudly if
`trace_pattern` matches nothing.

Also verified with `match_spec_test/3`: guards `is_list('$1')`,
`length('$1') =< 16` filter improper lists, non-lists and very long names with
no message (so a pathological event name can never be copied).

### 2.2 Isolation and cleanup (`experiments/trace_session_experiment.exs`)

| Scenario | OTP 26 (legacy) | OTP 27 / 29 (sessions) |
|---|---|---|
| Second tracer on an already-traced process | `erlang:trace(Pid, ...)` raises; `erlang:trace(all, ...)` **silently skips** that process | n/a |
| Tracer process dies | process flags cleared, **trace pattern stays installed** (stale breakpoint) | patterns stay while the session handle is referenced |
| dbg-style legacy tracer + TeleScope session on the same function | - | **Both receive their own messages**, different flags; destroying the session leaves the legacy pattern intact |
| Owner of the session handle dies | - | session destroyed automatically (handle GC) |

Design consequence: on OTP 27+ the tracer process *owns* the session, so any
death of the tracer destroys it. On OTP 26 a janitor process removes the
patterns, and the tracer reports how many processes it could not trace
(`skipped_processes`). Both paths are covered by tests (`killing the tracer
leaves no trace patterns behind`).

### 2.3 Tracing overhead and suppression

Raw experiment (`trace_overhead_experiment.exs`, `trace_mapkey_experiment.exs`), ns per `:telemetry.execute/3`, no handlers:

| Configuration | OTP 26 | OTP 29 |
|---|---|---|
| baseline | 120-220 | 121-219 |
| trace, full args (10 KB metadata) | 5,551 | 5,610 |
| trace, `arity` + name only | 1,176-1,462 | 1,305-1,752 |
| name suppressed via one `{message,false}` clause | 604-710 | 541-621 |
| 200 suppression clauses (name not in list) | 2,942-5,089 | 4,148-4,841 |
| `not is_map_key('$1', {const, Map})`, 1 known name, suppressed | 925 | 866 |
| same, 10,001 known names, suppressed | 780 | 713 |

Conclusion: clause lists scale linearly; a constant map guard is flat from 1
to 10,000 names. The library uses the map guard and re-installs it (debounced,
20 ms) when new names are discovered. In the spike capture, 24-25 re-installs
were enough for the whole run (237 messages total for 825 events).

`trace_argsize_experiment.exs` confirmed that the cost of a *suppressed*
breakpoint does not depend on argument size (+0.56-1.0 us from empty maps to
1,000-element lists, within noise), on both backends.

### 2.4 Handlers (`handler_invocation_experiment.exs`)

* `:telemetry.list_handlers([])` returns all handlers (the empty prefix
  matches everything in both the ETS and `persistent_term` implementations of
  telemetry 1.4); `attach_many` handlers appear once per event.
* `call_count` tracing counts invocations **without a tracer process or
  messages**, for external captures and for anonymous funs (the underlying
  `-fun-N-` function, arity = fun arity + captured variables; a closure over
  one variable is `/5`). Works inside an OTP 27 session (isolated: the legacy
  view of the same MFA shows `false`).
* Counts are per function: `&MyHandlers.handle/4` shared by two handler ids
  counted 8 calls for both. TeleScope reports `invocations_shared_with` and
  `invocations_attributable: false` in that case.
* Failing handler: telemetry emits `[:telemetry, :handler, :failure]` and
  detaches it; TeleScope's observer records this event (handler id, event,
  error kind - no reason or stacktrace values).

### 2.5 Observer redesigns (benchmark-driven)

1. **v1** single ETS row per shape + `:atomics.add_get` hard cap:
   12 concurrent emitters -> **103,670 ns per event** (lock convoy on one row).
   Rejected.
2. **v2** per-scheduler striped rows + `:counters` (`write_concurrency`) +
   read-only stop flag (soft cap): **814 ns**; the concurrent/baseline ratio
   (9.5x) now equals the single-process ratio (8.9x), i.e. no contention left.
3. **v3** handler config moved to `:persistent_term` (telemetry copies the
   handler record - config included - from ETS on every execute; refs in the
   config cost +184 ns vs +56 ns with 12 emitters,
   `handler_config_experiment.exs`), unsorted shape fold (2.3 us -> 0.56 us
   for 30 keys).

### 2.6 Static discovery details

* Prefilter: 840 beams indexed, 48 decoded (5.7 %), 62 analyzed after the
  wrapper fixpoint (2 global rounds), 39 wrapper MFAs.
* **Performance bug found and fixed:** the first version took 6.7 s because each
  `Task.async_stream` closure captured the whole forms cache (copying every
  module's forms into every task). Passing each task only its forms: 0.56 s.
* Wrapper resolution verified on real libraries: `Finch.Telemetry.start/stop/
  exception/span` (atom parameter, default-argument clauses), `Oban.Engine.
  with_span/4` (19 engine spans), `Bandit.Telemetry.start_span/3`,
  `ThousandIsland.Telemetry.*` (wrapper of a private wrapper,
  `[@app_name | suffix]`), and the app's own `emit/3` and `span/3` wrappers.
* Rules verified on real code: Phoenix endpoint `plug Plug.Telemetry` in
  `:runtime` init mode (`[:phoenix, :endpoint, :start|:stop]`), Ecto
  `[:demo_app, :repo, :query]` from the default prefix.
* Telemetry's own `[:telemetry, :handler, :failure]` is emitted by a *local*
  call inside the `telemetry` module; it is handled as a special case (only
  literal local emits, so `span/3` does not become a bogus wrapper).

### 2.7 Things that went wrong during the spike (and are now tests)

| Problem | How it was found | Fix |
|---|---|---|
| `trace_pattern` matched 0 functions | empty experiment output | load `telemetry`; fail on 0 |
| 6.7 s static scan | timing | don't capture caches in task closures |
| One module crash aborted the whole scan | smoke test (bad pipe argument order) | per-module isolation |
| Erlang modules without `+debug_info` misclassified | test | map backend `{error, missing}` to `:no_debug_info` |
| Truncated BEAM classified as "no debug info" | test | `beam_lib:all_chunks/1` integrity check |
| `valid_name?/1` crashed on improper lists | test | explicit recursion |
| Broad patterns (`[**]`, `[:demo_app, **]`) hid a metric typo | spike diagnostics | only *specific* partial patterns are evidence; templates flagged |
| Default-argument clauses made wrapper templates look like real partial sites | `mix telemetry.check` on the spike | template-only patterns never count as evidence |
| `invocations=nil` for every handler | spike report | capture starts before app boot: refresh handler tracking every 250 ms |
| Count 0 for tracer-discovered names | spike report | reconcile with tracer lower bound |
| `system_time` suggested as a duration | `--metrics` output | timestamp denylist |
| Suggestions for every possible dependency event | `--metrics` output | with runtime data, only fired span groups/events |
| Observer contention (103 us/event) | benchmark | striping + counters (2.5) |
| Tracer read other processes' whole dictionaries | code review | targeted `process_info(Pid, {dictionary, Key})` |
| `Process.info/2` guard rejects `{dictionary, Key}` on Elixir 1.15 -> tracer crash -> capture crash | version matrix | call `:erlang.process_info/2`; capture tolerates a failed tracer |
| OTP 26 `call_count` patterns could outlive a killed capture | code review | janitor + test |

## 3. Spike application results

### 3.1 Static (`spike/results/static_coverage_otp26.txt`)

```
direct non-template call sites (66): literal 60, partial 2, dynamic 4
wrapper template call sites: 39 (names resolved at callers)
call sites resolved through wrappers (119): literal 65, partial 54
call sites produced by rules (1): literal 1
effective name-decision sites: 186 -> literal 67.7 %, partial 30.1 %, dynamic 2.2 %
```

The 54 partial wrapper sites are almost all Bandit/ThousandIsland span helpers
whose name comes from a struct field (`span.span_name`), which the evaluator
deliberately does not follow.

Grep baseline (source occurrences of `:telemetry.execute|span|execute_lazy(`
vs scanner direct sites): equal for bandit, db_connection, demo_app, ecto,
ecto_sql, finch, oban (22), phoenix (13), phoenix_live_view (10),
thousand_island. Differences are all explained: plug 3 vs 2 (the third is in
a `quote` in `Plug.Router`, compiled into *user* routers), telemetry_metrics
6 vs 0 and telemetry_poller 11 vs 5 (documentation examples), telemetry 0 vs 1
(local call not matched by the grep).

### 3.2 Runtime capture (`spike/demo_app/priv/spike/run_spike.exs`)

Capture started before application boot; workload: 25 HTTP requests through
Finch -> Bandit -> Phoenix (JSON + HTML + 2 exceptions), Ecto queries, 5 Oban
jobs, all custom instrumentation, an Erlang module.

| | OTP 26 (legacy) | OTP 27 (session) | OTP 29 (session) |
|---|---|---|---|
| events observed | 824 | 825 | 782 |
| distinct names fired | 79 | 79 | 79 |
| tracer messages | 237 | 238 | 234 |
| suppression re-installs | 24 | 25 | 24 |
| tracer peak mailbox | 0 | 0 | 0 |
| observer ETS memory | 124 KB | 125 KB | 103 KB |
| static scan (in-run) | 615 ms | 675 ms | 846 ms |

### 3.3 Coverage

* Predicted emittable names (static): 170; fired: 79; fired and predicted: 66
  (**83.5 %**): 32 via literal call sites, 33 via wrapper/rule resolution,
  1 via the Ecto config rule.
* Fired but not predicted (13): `bandit.request.stop|exception`,
  `thousand_island.connection.{ready,recv,send,stop,async_recv}` (struct
  field names, matched by specific partial patterns), `demo_app.cache.{hit,
  miss,evict}` (runtime atom, partial by design), `demo_app.search.query`
  (config prefix computed at runtime, `[**, :query]`), `demo_app.dynamic.
  {alpha,beta}` (string-built, dynamic by design). 11 of 13 match a specific
  partial pattern; all 13 were discovered by the tracer.
* Predicted but not fired: 104 (the workload did not exercise LiveView,
  channels, websockets, Oban plugins' error paths, etc.). These are
  `:not_observed`, not "dead".

### 3.4 Diagnostics on the spike app

Static only (`mix telemetry.check --strict`): 1 warning (the typo), exit code 1.
With runtime: 1 error (crashing handler), 3 warnings (typo with suggestion,
wrong metric measurement, sensitive key), info diagnostics for unresolved
call sites, optional/nullable keys (`coupon: nil|binary`, Ecto
`decode_time` present in 91 %), unhandled events, an inactive handler
(`demo-app-refund`).

## 4. Conclusions

1. **Static discovery is the backbone and it works well.** Debug-info-based
   analysis plus wrapper resolution and two small rules predicted 83.5 % of
   the events that fired in a realistic Phoenix app, located every real call
   site, and caught a typo'd metric/handler without starting the app.
2. **Runtime tracing is viable as a time-boxed complement**, not as an
   always-on feature: ~0.4-0.6 us per telemetry call VM-wide when suppressed,
   and dangerous without suppression (mailbox growth). Trace sessions (OTP 27+)
   make it safe to coexist with other tools; OTP 26 support is workable with
   documented caveats.
3. **Shape observation is cheap enough for dev/staging and sampled
   production use** (~1-3 us per event, ~0.4-0.6 us with 10 % sampling) and
   gives information nothing else provides (optional keys, nullable keys,
   struct types, sensitive key names).
4. The concept is **ready for an MVP** focused on static discovery +
   diagnostics (CI) and opt-in runtime capture. See ROADMAP.md.
