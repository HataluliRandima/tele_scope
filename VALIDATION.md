# Validation on real open-source Phoenix applications

The spike's figures came from a fixture application written alongside
TeleScope. This document validates TeleScope against three independent,
production open-source Phoenix applications, as required before promoting
`0.1.0-rc.1` to `0.1.0` (RELEASE_CHECKLIST.md, section F).

**Bottom line**

* Fired-event prediction: **91.1 %** (hexpm) and **100 %** (changelog.com),
  above the 80 % target. Every name that was not predicted was discovered at
  runtime and matched a namespaced partial pattern.
* `mix telemetry.check --strict` on the three apps: **one warning, and it is
  a real bug** in plausible/analytics (a handler that can never fire), with
  the correct fix suggested. No false warnings remained after fixes.
* The validation found **5 TeleScope defects** (22 false warnings from two
  causes, one false negative hiding the bug above, a missing suggestion, one
  missed configurable name). All are fixed with regression tests.
* Runtime capture over full test suites (5,507 and 1,080 tests): 0 observer
  callback errors, tracer gate never closed, tracer mailbox peak <= 78.

## 1. Applications

| Application | Commit | Stack relevant to telemetry | Tests |
|---|---|---|---|
| [hexpm/hexpm](https://github.com/hexpm/hexpm) (hex.pm registry) | `2621535` (2026-11-20) | Phoenix, Bandit/ThousandIsland, Ecto/Postgrex, Oban, Broadway, Finch, Req, ExAws, PromEx, Sentry, oidcc (Erlang) | 5,507 (incl. 32 properties) |
| [thechangelog/changelog.com](https://github.com/thechangelog/changelog.com) | `31c4330` (2026-10-29) | Phoenix, Plug.Cowboy, Ecto/Postgrex, Oban, Oban Web, Sentry | 1,080 |
| [plausible/analytics](https://github.com/plausible/analytics) | `418da46` (2026-11-19) | Phoenix, Plug.Cowboy, Ecto/Postgrex + ClickHouse, Oban, Finch, Req, OpenTelemetry, Sentry | not run (needs ClickHouse) |

Environment: Elixir 1.20.1 / OTP 29.0 (all three require Elixir >= 1.18),
Postgres 17 in a throwaway container, Linux 6.6 (WSL2), 12 schedulers.
TeleScope was added as a path dependency; nothing else in the applications
was changed except one compiler option (below).

## 2. Method

* **Static:** `mix telemetry.check --strict` and `mix telemetry.explore
  --format json` on each application's `_build/dev`.
* **Runtime ground truth:** each application's **own test suite** as the
  workload. A hook ([`validation/scripts/telescope_hook.exs`](https://github.com/HataluliRandima/tele_scope/tree/main/validation/scripts/telescope_hook.exs),
  loaded from `test/test_helper.exs` only when `TELESCOPE_HOOK` is set) scans
  `_build/test`, starts a capture with the tracer in ground-truth mode
  (`known: []`, nothing pre-suppressed) and stops it in
  `ExUnit.after_suite/1`. *Fired* = names seen by the tracer or the observer;
  *predicted* = names with static or configuration evidence.
* **Recall** = fired and predicted / fired. Events fired only before the hook
  starts (application boot in `mix test`) are not counted.
* **Interference check:** each suite was also run without the hook.
* **Overhead:** changelog.com suite, baseline and capture alternated three
  times on an otherwise idle machine.

Workarounds needed to run the suites (not related to TeleScope):
`psql` is not installed on the host, so a shim forwards it into the Postgres
container ([`validation/scripts/psql_docker_shim`](https://github.com/HataluliRandima/tele_scope/tree/main/validation/scripts/psql_docker_shim));
changelog.com's `meck 0.9.2` does not compile on OTP 29 (deprecated `catch`
with warnings as errors), built with `ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]'`.
plausible's runtime validation was skipped because its suite needs ClickHouse.

## 3. Static results (final code)

| | hexpm | changelog.com | plausible |
|---|---|---|---|
| beams indexed | 2,764 | 2,637 | 4,053 |
| modules decoded / analyzed | 102 / 116 | 59 / 59 | 94 / 111 |
| scan time (idle) | 0.94 s | 0.83 s | 1.45 s |
| event names | 318 | 160 | 278 |
| by confidence | 170 literal, 101 resolved, 30 declared, 1 configured, 16 referenced | 77 literal, 79 resolved, 1 configured, 3 referenced | 148 literal, 119 resolved, 7 configured, 4 referenced |
| non-literal patterns (partial / dynamic) | 40 / 1 | 9 / 1 | 27 / 1 |
| unresolved patterns | 20 | 0 | 4 |
| analysis errors / missing debug info | 0 / 0 | 0 / 0 | 0 / 0 |
| `telemetry.check --strict` | 0 warnings, exit 0 | 0 warnings, exit 0 | **1 warning (true positive)**, exit 1 |

The 30 "declared" events in hexpm come from `oidcc`, an Erlang OpenID
Connect library that declares its events with `telemetry_event`
attributes: the first real-world use of that discovery path seen so far.

### The true positive (plausible/analytics)

```
[warning] consumer_without_emitter: [:oban, :notifier, :exception] is consumed by handler
"oban-errors" (lib/plausible/application.ex:385) but no emitter found in scanned code;
did you mean [:oban, :notifier, :notify, :exception]?
```

Plausible attaches its Sentry error reporter to
`[[:oban, :job, :exception], [:oban, :notifier, :exception], [:oban, :plugin, :exception]]`.
Oban 2.24.1 (the version in Plausible's `mix.lock`) emits
`[:oban, :notifier, :notify, :start | :stop | :exception]` (a `:telemetry.span/3`
in `Oban.Notifier`) and `[:oban, :notifier, :switch]`, but never
`[:oban, :notifier, :exception]` (verified in `deps/oban`). The handler can
therefore never fire for notifier failures, which are silently not reported
to Sentry. Before this validation, TeleScope reported it only as `info`
(see defect V3).

## 4. Runtime results

| | hexpm | changelog.com |
|---|---|---|
| suite result with capture | 5,506 / 5,507 passed (run 2); 5,505 / 5,507 (run 1) | 1,080 / 1,080 (4 runs) |
| suite result without capture | 5,505 / 5,507 | 1,080 / 1,080 (4 runs) |
| distinct event names fired | 123 | 23 |
| predicted statically | 112 (**91.1 %**) | 23 (**100 %**) |
| not predicted | 11: `bandit.request.{stop,exception}`, `thousand_island.{acceptor,connection,listener}.*` (span names stored in a struct field); all matched by `[:bandit, *, ...]` / `[:thousand_island, *, ...]` partial patterns and discovered by the tracer | - |
| observer events / callback errors | 387,167 / 0 | 14,301 / 0 |
| observer ETS | 365 KB | 98 KB |
| tracer messages / suppression updates | 1,769 / 101 | 31 / 22 |
| tracer gate closures / peak mailbox | 0 / 78 | 0 / 0 |

**Interference.** hexpm's suite is not deterministic in this environment:
every full run had 1-2 failures, and they were **different tests each time**
(with capture: `Hexpm.OAuth.DeviceFlowTest`, `Hexpm.PromEx.Plugins.OutboundHttpTest`;
then `HexpmWeb.SyntaxHighlightTest`; without capture:
`Hexpm.ObanConfigTest`, `Hexpm.PromEx.Plugins.ObanTest`). Every failing test
passed 3/3 in isolation both with and without the hook. One of them is a
timeout-sensitive test, so a contribution of capture overhead to that
particular failure cannot be excluded. changelog.com passed in all runs.

**Overhead (changelog.com suite, alternating runs, idle machine):**
baseline 92.5 / 73.1 / 75.5 s, with capture 84.5 / 81.1 / 76.1 s. Median
**75.5 s -> 81.1 s (+7 %)**; the ranges overlap (first baseline run was
cold). This includes a full static scan in the hook and ground-truth tracing
of every telemetry call.

## 5. Defects found in TeleScope and fixed

| ID | Found on | Problem | Fix | Test |
|---|---|---|---|---|
| V1 | hexpm | **21 false `metric_measurement_missing` warnings**: the `measurement:` option of `Telemetry.Metrics` was ignored (name-derived `:total`/`:milliseconds` was checked), and a function in any option (`measurement: &count/1`) made the whole option list non-literal, discarding `event_name:` too | options read key by key; `measurement: atom` honoured; function measurements are `:custom` and never checked; an unresolvable `event_name:` no longer falls back to the metric name | `real_app_validation_regressions_test.exs` |
| V2 | hexpm | **False warning for Ecto's `idle_time`**: documented as optional; never present under a SQL sandbox | rules can declare `optional_measurements` (Ecto: `idle_time`, `queue_time`, `decode_time`); missing optional measurements are `info` | idem |
| V3 | plausible | **False negative**: the never-firing handler above was reported as `info` because generic patterns such as `[**, :exception]` counted as possible emitters. Making them non-evidence alone would have turned Sentry's optional Quantum integration (handlers for a library that is not installed) into warnings on all three apps | specific patterns need a known first segment; consumers are attributed to applications, and only consumers in the project's own apps produce warnings (dependencies' consumers: `info`, "likely an optional integration") | idem |
| V4 | plausible | No suggestion for span-naming slips | "did you mean" also proposes same-namespace names where one is a subsequence of the other (<= 2 extra segments) | idem |
| V5 | hexpm | `ex_aws.request.*` not predicted: the name is `Map.get(config, :telemetry_event, [:ex_aws, :request])` | the literal default of `Map.get/3`, `Keyword.get/3`, `Application.get_env/3`, `maps:get/3`, `proplists:get_value/3`, `application:get_env/3` is a possible name (plus an unknown alternative) | idem |

Effect: hexpm recall 90.2 % -> 91.1 %; event names discovered +3 (hexpm),
+3 (changelog.com), +21 (plausible); strict warnings on the three apps
22 false + 0 true -> 0 false + 1 true.

## 6. What this does and does not show

* Shows: on three large, independent Phoenix codebases (2.6k-4k modules,
  current dependency versions), static discovery predicts 91-100 % of the
  events a full test suite fires, scans in about 1 s, and the strict check
  produced no false warnings and found one real bug.
* Does not show: behaviour under production traffic (test suites exercise
  different paths than real users), Postgres-heavy load, or umbrella
  projects. The 7 % suite overhead is an upper-bound-style figure for
  ground-truth mode (nothing pre-suppressed); normal captures pre-suppress
  statically known names.
* plausible's runtime recall was not measured.

## 7. Reproduce

```sh
git clone https://github.com/hexpm/hexpm && cd hexpm && git checkout 2621535
# add to deps: {:tele_scope, path: "/path/to/tele_scope", only: [:dev, :test], runtime: false}
mix deps.get && mix telemetry.check --strict
# runtime: Postgres on localhost:5432 (postgres/postgres), then append to test/test_helper.exs:
#   if hook = System.get_env("TELESCOPE_HOOK"), do: Code.require_file(hook)
TELESCOPE_HOOK=/path/to/tele_scope/validation/scripts/telescope_hook.exs \
TELESCOPE_OUT=/tmp/telescope_hexpm mix test
```

Summaries: [`validation/results/`](https://github.com/HataluliRandima/tele_scope/tree/main/validation/results).
