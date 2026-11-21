# TeleScope compatibility review

Part of the pre-release audit ([PRE_RELEASE_AUDIT.md](PRE_RELEASE_AUDIT.md)).
"Tested" means the full suite was executed on that combination during the
audit; raw outputs: `experiments/results/test_matrix_*.txt`.

## 1. Elixir / Erlang/OTP

| Elixir | OTP | Tracing backend | Result |
|---|---|---|---|
| 1.15.8 | 26.1.2 | legacy (`erlang:trace/3`) | 98 tests + 2 doctests pass |
| 1.17.0 | 26.1.2 | legacy | 98 + 2 pass |
| 1.17.0 | 27.0 | trace sessions | 98 + 2 pass |
| 1.20.1 | 29.0 | trace sessions | 98 + 2 pass |
| 1.16, 1.18, 1.19 | any | - | **not tested** (not installed) |
| any | 28 | - | **not tested** (not installed) |
| any | 24, 25 | - | **not tested**; see minimum OTP below |

**Declared requirement:** `elixir: "~> 1.15"` (mix.exs).
**Recommended supported OTP:** 26+ (tested). Nothing found in the code
requires OTP 26 specifically, but OTP 24/25 were not tested and should not be
advertised.

### OTP features used and their availability

| Feature | Used by | Available | Fallback |
|---|---|---|---|
| `trace:session_create/3`, `trace:function/4`, `trace:process/4` | Tracer, Handlers (OTP 27+) | OTP 27.0+ (verified absent on 26, present on 27/29) | legacy `erlang:trace/3` + `trace_pattern/3`, exclusive |
| `arity` process trace flag, `{message, '$1'}` | Tracer | all supported | - |
| `is_map_key/2` with `{const, Map}` in trace match-spec guards | Tracer suppression | verified OTP 26, 27, 29 | - |
| `{get_tcw}` + `band` in trace guards, `system_flag(trace_control_word, _)` | Tracer gate (audit) | verified OTP 26, 27 | - |
| `call_count` trace (local functions, anonymous funs) | Handlers | verified OTP 26, 27 (sessions) | - |
| `process_info(Pid, {dictionary, Key})` | Tracer attribution | OTP 26.2+ | raw `initial_call` (caught `badarg`) |
| `:counters` with `:write_concurrency`, `:atomics` | Observer | OTP 21.2+ | - |
| `:persistent_term` | Observer config | OTP 21.2+ | - |
| `ets:update_counter/3,4` with threshold ops | Observer | all supported | - |
| `beam_lib`, `debug_info_v1` backends | Static discovery | OTP 20+ | legacy `abstract_code` chunk |
| `:peer` | multi-node test only | OTP 25+ | - |
| `:json` | one test only (decoding check) | OTP 27+ | test skipped |

### Elixir-specific issues found

* **Elixir 1.15:** `Process.info/2` has a guard that rejects the
  `{:dictionary, key}` item spec, so the tracer crashed and took the capture
  down. Found by the version matrix during the spike; fixed by calling
  `:erlang.process_info/2` directly.
* **Elixir 1.20:** the new type checker reported two unreachable-clause and
  `&&` warnings in the spike; both fixed. `--warnings-as-errors` is clean on
  1.15, 1.17 and 1.20.
* Elixir debug info is decoded through `:elixir_erl` from the **running**
  Elixir. Scanning a `_build` compiled by a different Elixir version than the
  one running the scan is not supported (decoding failures are isolated per
  module and reported as `debug_info_error`).

## 2. `:telemetry`

| Version | Result | Notes |
|---|---|---|
| 1.0.0 | 98 + 2 pass, **1 skipped** | no `[:telemetry, :handler, :failure]` event before 1.1: handler-failure detection unavailable; no `execute_lazy` |
| 1.1.0 | pass | |
| 1.2.1 | pass | |
| 1.3.0 | pass | |
| 1.4.3 | pass | `execute_lazy/2,3` and `persist/0` exist |

Dependency requirement `~> 1.0` is kept; the 1.1+ requirement for failure
detection is documented in README and LIMITATIONS.

Internals relied upon (verified in telemetry source and by tests):
`list_handlers([])` returns every handler; `span/3`, `execute/2` and
`execute_lazy/2` reach `execute/3` / `execute_lazy/3`, which are the traced
functions; handler records (with config) are copied out of ETS on every
execute (why the observer passes a small key as config). Not verified:
behaviour after `:telemetry.persist/0` (works functionally by design; each
attach/detach then rewrites a persistent term).

## 3. Libraries covered by discovery (spike app, verified)

| Library | Version | Discovery |
|---|---|---|
| Phoenix | 1.8.17 | literal call sites; endpoint via `Rules.PlugTelemetry` (runtime init mode) |
| Phoenix LiveView | 1.2.x | literal spans |
| Plug | 1.20.x | `Plug.Telemetry` rule; `Plug.Router` macro calls appear in user routers |
| Ecto / Ecto SQL | 3.13 | `[:ecto, :repo, :init]` literal; `prefix ++ [:query]` via `Rules.Ecto` (SQLite and Postgres repos) |
| Oban | 2.x | literal + wrapper (`Oban.Engine.with_span/4`) |
| Finch | 0.2x | wrapper resolution (`Finch.Telemetry.*`) |
| Bandit / ThousandIsland | 1.15 / 1.6 | wrappers; span names from struct fields stay partial (runtime tracer resolves them) |
| DBConnection, telemetry_poller | - | literal; poller measurements configured as data stay dynamic |

A freshly generated Phoenix 1.8 app (Postgres default) was scanned without
false warnings.

## 4. Operating environment

Measured on Linux 6.6 (WSL2), 12 schedulers. No platform-specific code;
macOS and Windows untested. Interactive and embedded code-loading modes: the
tracer preloads its message path, so behaviour no longer depends on the mode
(audit R2).

## 5. Recommendations

1. CI matrix: Elixir 1.15, 1.17, 1.18, 1.19 x OTP 26, 27, 28 (plus
   latest), and one job with `telemetry == 1.0.0` and one with `~> 1.4`.
2. Advertise "OTP 26+, Elixir 1.15+, telemetry 1.0+ (1.1+ for handler-failure
   detection)".
3. Add one job that scans a fresh `mix phx.new` app and runs
   `mix telemetry.check --strict`.
