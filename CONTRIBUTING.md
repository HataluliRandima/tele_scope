# Contributing to TeleScope

Thank you for helping. The most valuable contributions are reports of
**false positives** (a diagnostic that is wrong), **false negatives** (an
event TeleScope missed) and real-world validation on applications we have
not tried.

## Reporting a problem

Please include:

* the output of `mix telemetry.check --verbose --format json` (or the
  relevant diagnostic), with anything private removed. Reports contain
  event names and source paths, never telemetry values;
* the library and version that emits or consumes the event;
* Elixir, Erlang/OTP and `:telemetry` versions (they are in the JSON
  `environment` field).

Security issues: please do not open a public issue; contact the maintainer
through the email on their GitHub profile.

## Development setup

```sh
git clone https://github.com/HataluliRandima/tele_scope
cd tele_scope
mix deps.get
mix test
```

Supported toolchains: Elixir 1.15+ on Erlang/OTP 26+. The code base is
formatted with Elixir 1.17 (the formatter's output differs slightly between
versions; CI checks with 1.17).

## Checks to run before opening a pull request

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test --include peer --include integration --warnings-as-errors
mix docs --warnings-as-errors      # if you touched documentation
```

CI runs the same commands on Elixir 1.15-1.20 / OTP 26-29, on several
`:telemetry` versions, and runs `mix telemetry.check --strict` on a freshly
generated Phoenix application.

### Test tags

| Tag | What | Default |
|---|---|---|
| `:tracing` | Tests that install trace patterns or handlers (VM-global state); always `async: false` | included |
| `:peer` | Multi-node test using a `:peer` node | excluded, `--include peer` |
| `:integration` | Runs the real `mix telemetry.*` tasks against a generated project (10-30 s) | excluded, `--include integration` |
| `:bench` | Benchmarks | excluded |

`scripts/matrix.sh` runs the suite against every Elixir/OTP pair installed
with asdf.

### Writing tests

* **Fixtures are real `.beam` files.** Use `TeleScope.Test.Fixtures`
  (`compile_elixir/3`, `compile_erlang/3`, `catalog/2`) so tests exercise
  the same path as scanning `_build`. Give fixture modules and event names
  a prefix unique to your test file (`TsDiag.*`, `[:ts_diag, ...]`) so
  tests cannot see each other's events.
* **Runtime evidence without timing.** For diagnostics and reports, build
  capture results with `TeleScope.Test.Synthetic.capture/1` instead of
  running a real capture: the test is then exact, fast and `async: true`.
* **Global state.** Tests that attach telemetry handlers or trace must be
  `async: false`, tagged `:tracing`, and must detach what they attach
  (`on_exit`). Use unique handler ids.
* **JSON.** Decode output with `TeleScope.Test.JSONDecoder.decode!/1`,
  which is strict and works on OTP 26 (no `:json` module there).
* Never delete or weaken a failing test to make a change pass. If behaviour
  changes on purpose, update the test and say why in the pull request.

## Project layout

```
lib/tele_scope.ex                  public API
lib/tele_scope/catalog.ex          evidence merging (pure data)
lib/tele_scope/event.ex            Event struct, status and confidence
lib/tele_scope/event_name.ex       symbolic event names and patterns
lib/tele_scope/diagnostics.ex      diagnostic definitions and checks
lib/tele_scope/metrics.ex          Telemetry.Metrics suggestions
lib/tele_scope/discovery/          static analysis: beam, scanner, analyzer, eval, rules
lib/tele_scope/runtime/            capture, observer, tracer, handlers, shape
lib/tele_scope/reporters/          console and JSON output
lib/mix/                           mix telemetry.explore / telemetry.check
test/                              unit, runtime, regression, CLI and integration tests
experiments/, bench/, spike/       evidence behind design decisions (not packaged)
```

[ARCHITECTURE.md](ARCHITECTURE.md) explains the design and the decisions
behind it.

## Adding a diagnostic

1. Add a definition to `@definitions` in `lib/tele_scope/diagnostics.ex`
   with the **next unused code**. Codes are a public contract: never
   renumber, reuse or change the meaning of an existing code.
2. Implement the check as a function returning diagnostics built with
   `d/5` (or `limitation/3` for things TeleScope could not see). Give it a
   message that states the problem, locations when known, and a suggestion
   when there is a concrete fix.
3. Choose the severity from the evidence, not from how bad the problem
   would be. A warning must be very likely a real mistake in the project:
   `mix telemetry.check --strict` fails on it in CI. When in doubt, use
   `:info`.
4. Document it in [DIAGNOSTICS.md](DIAGNOSTICS.md) (a test checks every code
   is documented) and add tests for the positive case and for the false
   positives you considered.

## Adding a discovery rule

Rules teach TeleScope names that are not visible in code, for example a
prefix taken from configuration. Implement `TeleScope.Discovery.Rule`
(`watched_calls/0` + `on_call/3` for call sites, `config_events/1` for
configuration); see `TeleScope.Discovery.Rules.Ecto`. A rule that raises is
reported as `TS012` and never breaks discovery.

## Commits and releases

Keep commits focused and describe *why* in the message. Add a line to the
"Unreleased" section of [CHANGELOG.md](CHANGELOG.md) for any user-visible
change. Releases are made by the maintainer following
[RELEASE_CHECKLIST.md](https://github.com/HataluliRandima/tele_scope/blob/main/RELEASE_CHECKLIST.md).
