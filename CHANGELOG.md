# Changelog

## Unreleased

Production-readiness pass: stable diagnostic codes, a CI-grade
`mix telemetry.check`, more reliable runtime capture, and end-to-end CLI
tests.

### Added
- Stable diagnostic codes `TS001`-`TS013`, documented in DIAGNOSTICS.md and
  available from `TeleScope.Diagnostics.definitions/0`. Every diagnostic now
  has `code`, `title`, `suggestion`, `locations` and `limitation` in
  addition to `check`, `severity`, `event`, `message` and `detail`.
- `TeleScope.Diagnostics.evaluate/2`: pass/fail verdict with strict mode.
- `mix telemetry.check --format json` and `--output`.
- Exit status `2` for invalid usage (unknown options, bad values, positional
  arguments) and when a runtime capture cannot start, distinct from `1`
  (failing diagnostics).
- New diagnostics: `TS012 scan_error` (missing ebin directories, unreadable
  or unanalysable modules and failing rules were collected but never
  reported) and `TS013 runtime_only_event` (events that fired but that
  static discovery did not predict, linked to the matching partial
  pattern).
- `TS003` suggests the observed measurement closest to the one a metric
  reads (`:duration_ms` -> `:duration`).
- `TeleScope.CaptureError` with actionable messages.
- `--app` also filters the JSON report of `mix telemetry.explore`.
- CONTRIBUTING.md; end-to-end CLI tests against a generated project
  (`mix test --include integration`); tests for capture lifecycle,
  concurrent captures, duplicate handler registration, reporters and
  every diagnostic.

### Changed
- `mix telemetry.check` prints one block per diagnostic (code, event,
  problem, location, suggestion) and a result line, instead of one line
  per diagnostic followed by `** (Mix) telemetry.check failed`.
- "Did you mean" hints moved from `message` to `suggestion`.
- Limitations never fail `--strict` and are always shown: `no_debug_info`
  is a warning only for the project's own modules (info for dependencies),
  and `capture_limited` is info.
- With `--format json` and no `--output`, compilation output is suppressed
  and progress messages go to stderr, so stdout is valid JSON.
- If the VM refuses the tracer (e.g. a second capture on OTP 26), the
  capture continues with the observer only and reports `TS011`, instead of
  failing. Invalid tracer options still fail the start.
- Scan results are ordered deterministically: repeated runs produce
  identical reports and diagnostics.
- `--duration`, `--serve` and `--no-trace` without `--runtime` print a note
  instead of being silently ignored.

### Fixed
- `TS004 inactive_handler` could warn about a handler picked up
  mid-capture for an event that fired before counting started (for
  example startup events under `--runtime`). It is now a warning only when
  the event fired after counting for the handler began.
- `TeleScope.capture/2` and the mix tasks crashed with a `MatchError` when
  a capture could not start; `stop_capture/2` exited the caller when the
  capture had already stopped.
- A tracer crash during a capture was reported as `{:error, :not_running}`
  instead of the crash reason.
- A discovery rule that `throw`s or `exit`s (instead of raising) broke the
  scan.
- `TeleScope.report/2` crashed with a `CaseClauseError` on an unknown
  format; it now raises an `ArgumentError` that names the valid formats.

### CI
- Installs Hex and rebar3 explicitly, runs the integration tests, fails on
  test compile warnings, checks for unused locked dependencies and retired
  packages, lists the Hex package contents, and verifies that
  `mix telemetry.check --format json` on stdout parses in a fresh Phoenix
  app.
- `test/audit/repro.exs` (a script) is excluded from test discovery, so
  newer Elixir versions do not warn about it under `--warnings-as-errors`.

## v0.1.0-rc.1 (unreleased)

First release candidate, following the engineering spike and the pre-release
audit (PRE_RELEASE_AUDIT.md).

### Added
- Static discovery from compiled BEAM files: literal, partial and dynamic
  event names, wrapper resolution, handler registrations, Telemetry.Metrics
  definitions, `telemetry_event` declarations.
- Rules: Ecto `telemetry_prefix`, `plug Plug.Telemetry` (both init modes).
- Runtime capture: shape observer, event-name tracer (trace sessions on
  OTP 27+), handler invocation counting.
- Diagnostics, metric suggestions, console and JSON reports.
- `mix telemetry.explore` (`--runtime`, `--serve`, `--app`, `--metrics`,
  `--format json`) and `mix telemetry.check` (`--strict`).

### Fixed during real-app validation (VALIDATION.md)
- Telemetry.Metrics `measurement:` was ignored and a function in any option
  discarded `event_name:` (21 false warnings on hexpm) (V1).
- Rules can declare optional measurements; Ecto's `idle_time`,
  `queue_time`, `decode_time` no longer produce warnings when absent (V2).
- `consumer_without_emitter`: generic patterns (`[**, :start]`) no longer
  hide missing emitters; consumers in dependencies are `info`, consumers in
  the project's own apps are warnings (`:project_apps` option). This exposed
  a real never-firing handler in plausible/analytics (V3).
- "Did you mean" suggests span-naming slips such as
  `[:oban, :notifier, :exception]` -> `[:oban, :notifier, :notify, :exception]` (V4).
- Literal defaults of `Map.get/3`, `Keyword.get/3`, `Application.get_env/3`
  (and Erlang equivalents) are evaluated as possible event names (V5).

### Fixed during the pre-release audit
- Tracer: a burst of one new hot event could queue ~240k messages and trip
  the breaker. Suppression is now installed asynchronously, a trace-control
  word gate stops unknown-name messages under pressure, and the message path
  is preloaded (R2).
- Tracer (OTP 26): a second concurrent legacy tracer silently went blind when
  the first stopped; it is now refused with `{:error, {:already_tracing, pid}}` (R1).
- Capture: an observer crash crashed the capture and the catalog merge (R3, R4).
- Static: `raise`/`throw` branches produced spurious dynamic patterns (R5).
- Security: the debug_info backend named inside a `.beam` file was called
  without restriction; only OTP/Elixir backends are now allowed (R6).
- Static: name construction with many alternatives grew exponentially (R7).
- Diagnostics: sensitive-key detection matched substrings (`author_id`,
  `passenger_count`), failing `--strict` CI on innocent keys.
