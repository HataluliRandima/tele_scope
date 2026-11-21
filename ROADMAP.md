# Recommended MVP roadmap

**Verdict: worth pursuing.** The spike shows that the two hard parts (static
discovery with useful accuracy, and safe runtime discovery of dynamic names)
work. Their costs are understood and bounded. The MVP should lead with what
is cheap and always safe: static discovery and CI diagnostics. Runtime capture
should be an opt-in second step.

## MVP (0.1) - "know your events, catch the typos"

Scope:

1. **Static discovery** as implemented (scanner, evaluator, wrapper
   resolution, Ecto + Plug.Telemetry rules), hardened:
   * per-application include/exclude options and `--only-project` output
     (dependency events are often noise to users);
   * cache the index and forms by beam mtime/md5 for repeated runs.
2. **`mix telemetry.check`** for CI: `consumer_without_emitter` (typos in
   metrics and handlers), `no_debug_info`, `incomplete_span`, `--strict`.
   This feature is the most immediately valuable: it needs no app start and
   produces no false "dead event" claims.
3. **`mix telemetry.explore`** console and JSON (schema v1 frozen, with a
   documented schema).
4. **Runtime capture from IEx** (`TeleScope.capture/2`) with the current
   safety limits; `--runtime` in the mix task.
5. **Metric suggestions** with reasons and confidence, behind `--metrics`.
6. Rules shipped: Ecto, Plug.Telemetry, plus `telemetry_poller` and Oban
   (verify whether Oban needs one beyond wrapper resolution).
7. CI matrix: Elixir 1.15-1.20 / OTP 26-29 (as `scripts/matrix.sh` does), plus
   a Postgres-backed fixture app.

Exit criteria for 0.1:

* >= 80 % of fired event names predicted statically on three real-world
  open-source Phoenix apps (not only the fixture app);
* zero crashes on full `_build` scans of those apps; every error classified;
* runtime overhead within the budgets in BENCHMARKS.md on bare metal;
* all failure-mode tests green on the matrix.

## 0.2 - better runtime insight

* Multi-node capture: run captures over `:erpc` on connected nodes and **sum**
  per-node results in the catalog (today the catalog replaces runtime data per
  event).
* Optional, explicit low-cardinality value capture for atom/boolean metadata
  (for example `result: :ok | :error`), off by default and with an allowlist.
  This would greatly improve tag suggestions.
* Depth-2 shapes behind an option (nested maps), with benchmarks.
* Caller attribution for dynamic names: an optional `{caller}` match-spec
  term to link runtime names to the emitting function. Measure the cost first,
  and remember tail calls hide callers.
* Schema drift between two captures (`mix telemetry.diff a.json b.json`).

## 0.3 - integrations

* Phoenix LiveDashboard page (reads the catalog/JSON; no new collection
  code).
* Export of suggested metrics into a reporter module skeleton.
* Rule packs contributed by libraries (Broadway, Absinthe, Tesla, Req/Finch
  options, Commanded, ...), plus documentation for writing rules.
* Possibly promote the `telemetry_event` declaration convention: TeleScope
  can show library authors which of their events are undocumented.

## Explicitly out of scope

* Always-on production tracing.
* Storing measurement/metadata values.
* Claims that an event "does not exist" or a handler is "broken" without a
  failure event.

## Open risks to retire early

| Risk | Mitigation |
|---|---|
| `elixir_erl` debug-info decoding changes between Elixir versions | Matrix CI; decoding failures are isolated per module and classified |
| Large umbrella apps (thousands of modules) | Measure; add index/forms cache; parallelism already in place |
| OTP 26 legacy tracing conflicts with users' tracing tools | Default to `trace: false` on OTP < 27 unless explicitly enabled; document clearly |
| Telemetry internals change (e.g. a new entry point that bypasses `execute/3`) | Tracer test asserts span/execute/2/execute_lazy coverage on every telemetry version in CI |
| False confidence from partial coverage | Reports always show unresolved patterns and blind spots; no "complete" wording anywhere |
