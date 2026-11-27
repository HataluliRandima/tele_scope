# TeleScope pre-release audit

**Scope:** every module under `lib/`, the mix tasks, tests, benchmarks,
documentation and packaging of `HataluliRandima/tele_scope` (branch `audit`,
base commit `78d7e65`), audited before a first public release.

**Verdict: READY WITH CONDITIONS** (section 8).

**Method.** Every finding below was reproduced before being fixed. The
reproductions are in [`test/audit/repro.exs`](test/audit/repro.exs) (run:
`MIX_ENV=test mix run test/audit/repro.exs`) and are now permanent regression
tests in [`test/tele_scope/audit_regressions_test.exs`](test/tele_scope/audit_regressions_test.exs).
Nothing is reported as passing unless it was executed on this machine.
Companion documents: [SECURITY_REVIEW.md](SECURITY_REVIEW.md),
[COMPATIBILITY_REVIEW.md](COMPATIBILITY_REVIEW.md),
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

## 1. Summary

| Severity | Found | Fixed in this audit | Open |
|---|---|---|---|
| P0 release blocker | 2 | 2 | 0 |
| P1 important | 8 | 7 (+1 partly: CI added, not yet run on GitHub) | 0 |
| P2 improvement | 12 | 6 (+1 partly) | 5 (2 documented, 3 open) |
| P3 optional | 7 | 2 | 5 (3 documented, 2 open) |

**Test status after the audit (executed):** 98 tests + 2 doctests pass on
Elixir 1.15.8/OTP 26.1.2, 1.17.0/26.1.2, 1.17.0/27.0 and 1.20.1/29.0, and on
`:telemetry` 1.0.0 (1 documented skip), 1.1.0, 1.2.1, 1.3.0 and 1.4.3. Before the
audit: 87 tests, all passing; they passed because none of them exercised the
failure modes below. 30 randomized-seed runs: no flaky test.

**Positive findings (verified, not assumed):**

* No raw measurement or metadata value reaches ETS, snapshots, the catalog
  or reports (tests search snapshots for raw values; handler configs reduced
  to their type).
* The static analyzer ran on **all 2,128 modules with debug info** on the
  machine (OTP, Elixir, 36 dependencies): 0 crashes, slowest module 249 ms.
* A freshly generated Phoenix 1.8 application (Postgres default): static
  discovery in ~0.4 s, `mix telemetry.check --strict` and
  `mix telemetry.check --runtime --strict` exit 0 with **0 false warnings**.
* Static discovery results on the spike application are unchanged by every
  fix (79 names fired, 66 predicted, 83.5 %, OTP 26 and 27).

## 2. P0 - release blockers

### P0-1 Tracer mailbox grows to ~240k messages for a single hot new event (R2) - FIXED

* **Where:** `lib/tele_scope/runtime/tracer.ex` (pre-audit: synchronous
  debounced re-install, breaker checked every 256 messages). Fix:
  `start_install/1` (line 500), `close_gate/1` (516), match-spec gate guard
  (`@gate_bit`, 85), `warm_up/0` (222), `max_mailbox` (74).
* **Problem:** the documented safety property "trace messages cannot create
  uncontrolled memory growth" was false. A new name emitted in a tight loop
  queued one message per call until suppression landed. Re-installing a trace
  pattern under load takes 53-166 ms (thread-progress barrier,
  `experiments/trace_gate_experiment.exs`). In a fresh VM, lazy loading of the
  tracer's code delayed the reaction by a further ~250 ms.
* **Evidence (before):** OTP 26: `status=overload messages=240000
  peak_mailbox=239746` for one name; OTP 27: `peak_mailbox=12862`, overload.
  The breaker tripped *after* the memory was already allocated, and discovery
  stopped.
* **Impact:** transient tens of MB per burst, unbounded by configuration;
  discovery aborted under load (load tests, benchmarks, traffic spikes).
* **Fix:** suppression installed by a short-lived installer process (the
  tracer keeps draining); a trace-control-word gate bit checked in the match
  spec, closed in ~2 us when the mailbox exceeds `gate_threshold` (1,000) and
  reopened when suppression has landed; message path preloaded at start; high
  scheduling priority; installer awaited before teardown so it can never
  re-install after cleanup; janitor clears the gate bit if the tracer is
  killed. Gated time is reported (`gate_closures`, `gated_ms`) because names
  emitted only while gated can be missed.
* **Evidence (after):** first burst in a fresh VM: 12 messages, no gate;
  later bursts 1.1k-2.4k peak, gate closed once for 20-110 ms; with suppression
  *disabled* and 1M calls: peak 1.6k-2.3k (before: 464k-565k). Gate guard cost:
  not measurable (`experiments/trace_gate_cost_experiment.exs`).
* **Tests:** `audit_regressions_test.exs` "R2 ..." (3 tests incl. gate bit
  restored after `:kill`).

### P0-2 The package could not be built or published - FIXED

* **Where:** `mix.exs`.
* **Evidence:** `mix hex.build` -> `Missing metadata fields: licenses, links`;
  version `0.1.0-spike`; no `package`/`docs` config; two empty directories
  (`lib/tele_scope/diagnostics`, `lib/tele_scope/metrics`) shipped; no
  CHANGELOG.
* **Fix:** package metadata with an explicit `files` allowlist (spike,
  experiments and benchmark results are excluded), ExDoc configuration with
  module groups (`API`, `Runtime (advanced)`, `Internals (unstable)`),
  version `0.1.0-rc.1`, `CHANGELOG.md`, empty dirs removed, all relative
  links that would break on hexdocs rewritten. `mix hex.build` succeeds;
  `mix docs` produces 0 warnings.

## 3. P1 - important

| ID | Finding | Where | Evidence | Impact | Status |
|---|---|---|---|---|---|
| P1-1 (R1) | On OTP 26 a second concurrent tracer silently went **blind** when the first stopped (legacy patterns and `:all` tracer flags are VM-global; the first tracer's cleanup removed the second's patterns) | `tracer.ex` `acquire_lock/1` (263) | `second tracer saw [] after the first stopped` | two captures (e.g. two IEx sessions, or a capture plus a mix task) silently produce empty results | **Fixed**: one legacy tracer at a time, second gets `{:error, {:already_tracing, pid}}`; OTP 27+ sessions remain concurrent and are tested to be independent |
| P1-2 (R3) | Observer crash made `Catalog.add_capture/2` raise | `capture.ex` `crashed_observations/2` (209) | `FunctionClauseError in Catalog.merge_observations/2` | a capture's tracer and handler results were lost | **Fixed**: well-formed `:crashed` observations + `capture_limited` diagnostic |
| P1-3 (R4) | A tracer-discovered name arriving while the observer was dead **crashed the capture process** | `capture.ex` `handle_info/2` (new-names clause; observer `:DOWN` at 130) | `capture alive? false` | whole capture lost | **Fixed**: observer monitored, calls guarded |
| P1-4 (R6) | The debug-info backend module named **inside a `.beam` file** was loaded and called without restriction | `discovery/beam.ex` `from_backend/3` (83), `@default_backends` (81) | crafted `Dbgi` chunk made TeleScope call `R6.EvilBackend.debug_info/4` | scanning a crafted file calls attacker-chosen code paths (any module on the code path with `debug_info/4`) | **Fixed**: allowlist `:elixir_erl`, `:erl_abstract_code` (+ opt-in config) |
| P1-5 (R7) | Symbolic evaluation built the full cartesian product of segment alternatives *before* capping: exponential time/memory | `discovery/eval.ex` cons (92), `append/2` (164) | 6 segments x 10 alternatives: 1,196 ms, +137 MB; 8 segments would not finish | scanner hang/OOM in CI on legal (if unusual) code | **Fixed**: capped before the product; 8 x 10 now instant (test) |
| P1-6 | Sensitive-key detection matched **substrings**: `author_id`, `passenger_count`, `compass_heading`, `bypass_cache`, `tokenizer_ms`, `classname` were warnings, so `--strict` CI failed on innocent keys. The first fix (segment list) introduced `otp` -> flagged Phoenix's `:otp_app`; caught by re-running the spike | `diagnostics.ex` `sensitive_key?/1` (38) | regex probe; spike report | false CI failures in every Phoenix app (`[:phoenix, :endpoint, :init]` carries `:otp_app`) | **Fixed**: whole-segment + pair matching, camelCase aware; both FP lists are regression tests; fresh Phoenix app `--runtime --strict` -> 0 warnings |
| P1-7 | Benchmarks reported **minimum only**; tracer budget stated as met | `BENCHMARKS.md`, `bench/runtime_overhead.exs` | re-run with medians: tracer +0.7-1.5 us median vs "0.35-0.69 us" claimed | readers would under-estimate overhead | **Fixed**: min/median/max reported, budget marked "at risk" on OTP 27 medians, noisy rows annotated |
| P1-8 | **No CI** in the repository; the version matrix only runs locally (`scripts/matrix.sh`) | repo root | no `.github/workflows` | contributors and users cannot see compatibility evidence; regressions such as the Elixir 1.15-only crash found in the spike would ship | **Partly fixed**: `.github/workflows/ci.yml` added and validated locally (actionlint clean; job scripts executed); must run green on GitHub before publishing |

## 4. P2 - improvements

| ID | Finding | Where | Status |
|---|---|---|---|
| P2-1 (R5) | `raise`/`throw`/`exit` branches added a spurious fully dynamic `[**]` alternative to otherwise literal names | `eval.ex` (108, 144) | **Fixed** + test |
| P2-2 | `--runtime` could not observe Phoenix request events: endpoints do not listen unless `phx.server` set `:serve_endpoints`. A fresh app capture saw 6 startup events only | `lib/mix/tele_scope_helpers.ex` (29) | **Fixed**: `--serve` (verified: 200 responses, 54 Ecto queries, 6 endpoint stops observed) |
| P2-3 | Static-only `--metrics` produced 48 suggestions for a fresh Phoenix app, mostly dependency events; no CLI filter | `telemetry.explore.ex` | **Fixed**: `--app` (repeatable) -> 5 suggestions |
| P2-4 | README claimed telemetry 1.0-1.3 support without tests; on 1.0.0 handler-failure detection does not work (no failure event before 1.1) | README, `observer_test.exs` (124) | **Fixed**: tested 1.0.0-1.4.3; requirement documented; test skips with reason on 1.0 |
| P2-5 | Public API boundary undefined: every module is public | `lib/` | **Partly fixed**: docs group internals as "Internals (unstable)". Recommend `@moduledoc false` or explicit stability notes before 1.0 |
| P2-6 | The `:telemetry.persist/0` (1.4) path is untested: each observer attach/detach then rewrites a persistent term (VM-wide literal-area scan) | `observer.ex` attach | **Open**, documented in LIMITATIONS.md |
| P2-7 | Umbrella projects, Postgres-backed `--runtime --serve`, OTP 28, Elixir 1.16/1.18/1.19 untested | - | **Open** (not installed) |
| P2-8 | Mix tasks have no automated tests (exercised manually on two apps) | `lib/mix/tasks/*` | **Open** |
| P2-9 | Atoms are created from scanned files (`String.to_atom` on metric names `analyzer.ex:380`, Ecto prefixes `rules/ecto.ex:60`, ebin dir names `scanner.ex:140`, plus `binary_to_term` inside debug-info decoding) | discovery | **Documented** trust boundary (SECURITY_REVIEW.md) |
| P2-10 | Tracer uses a bit of the VM-global trace control word (new in this audit) | `tracer.ex` (85) | **Documented**; shared by concurrent TeleScope session tracers by design |
| P2-11 | Hexdocs relative links to repository files were broken | docs | **Fixed** (0 doc warnings) |
| P2-12 | Capture durations between 599,001 and 600,000 ms failed because the tracer's safety-net duration exceeded its maximum; non-integer durations crashed `init` | `capture.ex` (53, 103) | **Fixed** + tests |

## 5. P3 - optional

| ID | Finding | Status |
|---|---|---|
| P3-1 | Observer shape-cap counter over-counted when two schedulers registered the same new shape concurrently (`observer.ex` 191) | **Fixed** |
| P3-2 | JSON encoder did not validate UTF-8 in binary map keys (`reporters/json.ex` 146) | **Fixed** + test |
| P3-3 | Runtime processes are not supervised (unlinked, monitor-owned, janitors) - acceptable for a tool with no application callback; an optional `DynamicSupervisor` would make them visible in observer tools | Open (design choice) |
| P3-4 | Invocation counts are per function, not per handler id (flagged `invocations_attributable: false`) | Documented |
| P3-5 | Reports contain absolute source paths for Erlang modules | Documented |
| P3-6 | Under a pathological flood with suppression disabled the high-priority tracer cycles the gate continuously | Documented; suppression is on by default |
| P3-7 | `[:telemetry, :handler, :failure]` shows as `static_only` after a capture (observed via a separate handler) | Open, cosmetic |

## 6. Architecture review notes

* **Responsibilities** are well separated: discovery (pure, no processes),
  runtime (three processes with clear ownership), catalog (pure data),
  diagnostics/metrics/reporters (pure functions). The audit fixes did not
  require structural changes.
* **Lifecycle and ownership** (verified by tests that `:kill` each component):
  ETS table owned by the observer; persistent term erased by observer or its
  janitor; trace sessions owned by the tracer and by the capture; legacy
  patterns removed by janitors (tracer: twice, to cover an installer finishing
  its BIF after the kill); gate bit cleared by the tracer janitor;
  `call_count` patterns removed by the handler-tracking janitor on OTP 26.
* **Error handling**: per-module isolation in the scanner, per-rule isolation,
  never-raising telemetry callbacks, tagged errors from `Beam`. The audit
  closed the remaining gaps in `Capture`.
* **OTP compatibility**: see COMPATIBILITY_REVIEW.md.

## 7. Missing tests (identified)

Added in this audit: R1-R7, sensitive keys (positive and negative), invalid
capture durations, capture at maximum duration, JSON with invalid UTF-8,
telemetry version gating (98 tests total, was 87).

Still missing (recommended before 1.0): mix task integration tests (fixture
project); umbrella project scan; property-based tests for `Eval`
(alternatives cap, substitution); a soak test (10-minute capture under load,
memory flat); `:telemetry.persist/0`; two concurrent session tracers under
gate pressure; benchmarks in CI with regression thresholds.

## 8. Recommendation

**READY WITH CONDITIONS** for a public MVP published as a **pre-release**
(`0.1.0-rc.1`):

1. Push and confirm the added CI workflow (`.github/workflows/ci.yml`) is
   green on GitHub before publishing (P1-8).
2. Re-measure the tracer on bare metal; if medians exceed 1 us per call,
   state the measured range instead of the budget in README (P1-7 follow-up).
3. ~~Validate on at least two real open-source Phoenix applications~~ Done:
   VALIDATION.md (91.1 % and 100 % recall; 5 defects found and fixed).
4. Then promote to `0.1.0`, tag `v0.1.0`, publish docs.

Not blocking an rc: P2-5 to P2-8. Blocking 1.0: P2-5 (API boundary) and
P2-8 (mix task tests).
