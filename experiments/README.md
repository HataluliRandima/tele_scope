# Experiments

Standalone scripts that validated (or refuted) each technical assumption
before or while it was built. Raw outputs are in `results/`; conclusions are
in [../SPIKE_RESULTS.md](../SPIKE_RESULTS.md).

| Script | Question | Run |
|---|---|---|
| `probe_otp.exs` | Which OTP versions have `trace:session_create/3`? | `elixir probe_otp.exs` |
| `trace_shape_experiment.exs` | What does a call-trace message contain? `arity` flag, name-only match spec, `local` vs `global`, `execute_lazy`, suppression clauses | `PRELOAD=1 elixir trace_shape_experiment.exs` |
| `trace_session_experiment.exs` | One-tracer-per-process conflicts, stale patterns after tracer death, session isolation and lifetime | `elixir trace_session_experiment.exs` |
| `trace_overhead_experiment.exs` | Raw tracing cost: full args vs name only vs suppressed vs clause lists | `elixir trace_overhead_experiment.exs` |
| `trace_mapkey_experiment.exs` | O(1) suppression with `is_map_key` on a constant map, 0-10,000 names | `elixir trace_mapkey_experiment.exs` |
| `trace_argsize_experiment.exs` | Does a suppressed breakpoint's cost depend on argument size? (library tracer) | `mix run experiments/trace_argsize_experiment.exs` |
| `handler_invocation_experiment.exs` | `list_handlers([])` global enumeration; `call_count` for external and anonymous handlers, in sessions; failing handler behaviour | `elixir handler_invocation_experiment.exs` |
| `handler_config_experiment.exs` | Cost of the handler *config* term on every execute | `mix run experiments/handler_config_experiment.exs` |

Scripts run with `elixir` use `Mix.install([:telemetry])` and are
independent of the library. Select versions with
`ASDF_ERLANG_VERSION=27.0 ASDF_ELIXIR_VERSION=1.17.0` (OTP 29 needs
`ASDF_ELIXIR_VERSION=1.20.1-otp-29`).

`results/test_matrix_*.txt` are the full test-suite outputs per Elixir/OTP
pairing, produced by `scripts/matrix.sh`.
