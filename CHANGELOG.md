# Changelog

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
