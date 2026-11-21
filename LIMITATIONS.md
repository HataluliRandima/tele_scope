# Known limitations

TeleScope reports evidence; it never claims completeness. These are the
limitations known at the end of the spike, grouped by component. Many are
fundamental to the approach and should stay documented after the MVP.

## Static discovery

* **Requires debug info.** Modules compiled with `debug_info: false`, or
  stripped beams (`mix release` with `strip_beams: true`, the default), are
  invisible except for their import table. They are reported
  (`no_debug_info` warning) but their event names are unknown. Scan
  `_build/ENV`, not a release.
* **Dynamic dispatch is invisible.** `apply(:telemetry, :execute, args)`,
  calls through a module stored in a variable, and telemetry calls in code
  loaded at runtime (`Code.eval_*`, hot-loaded modules) are not detected.
* **Unresolvable names stay partial or dynamic.** Values from runtime data,
  struct fields (`span.span_name` in Bandit/ThousandIsland), maps, ETS,
  process dictionary or config read at runtime are not followed. In the spike
  30 % of name-decision sites were partial (mostly struct fields) and 2.2 %
  fully dynamic.
* **Bounded evaluation.** Constant propagation is per function clause;
  local call evaluation depth <= 4; <= 16 alternatives per expression (beyond
  that the name becomes unknown); wrapper fixpoint <= 6 local and <= 4 global
  rounds. Wrappers that receive the name inside a data structure (map,
  tuple, struct) are not resolved.
* **Patterns aggregate by shape.** Two call sites with the same partial
  pattern share one entry; "unresolved" is evaluated per pattern, not per
  call site.
* **Macro-generated calls** are attributed to the module that *uses* the
  macro, with the line of the macro invocation (for example `use
  ThousandIsland.Handler` at line 7), not the line in the macro's source.
* **Telemetry.Metrics definitions** are found only when the metric name (and
  `event_name:` option) is a literal. Metrics built dynamically (`Enum.map`
  over a list) are missed. Metric names from scanned code are converted with
  `String.to_atom/1`, bounded by the size of the scanned code.
* **Handler registrations** with non-literal ids or event lists are recorded
  as `:unknown` and do not produce catalog entries.
* `telemetry_registry` declarations are supported, but none of the 36
  applications in the spike use them.

## Rules

* `Rules.Ecto`: prefixes changed in a repo's `init/2` callback, per-query
  `:telemetry_event` overrides and dynamically started repos with a different
  prefix are not covered. Repos must be listed in `:ecto_repos` or declare
  `@behaviour Ecto.Repo` in scanned code.
* `Rules.PlugTelemetry`: a non-literal `event_prefix` degrades to a partial
  pattern.
* Only two rules exist. Oban, Finch, Bandit and Phoenix did not need rules in
  the spike (wrapper resolution handled them). Other libraries with
  configurable prefixes will need rules (for example Absinthe, Broadway,
  Tesla middleware options, and `telemetry_poller` measurements, which are
  configured as data).

## Runtime tracer

* **Pressure gate.** Under a burst of unknown names the tracer sets bit 20
  (`0x100000`) of the VM-global *trace control word* to stop unknown-name
  messages. Names emitted *only* while the gate is closed are missed; the
  result reports `gate_closures` and `gated_ms` (typically 0-100 ms per
  burst). Tools that rely on the trace control word themselves (rare) may
  interact with this bit. Concurrent TeleScope tracers on OTP 27+ share it.
* **Residual burst backlog.** Between the first message of a new hot name and
  the gate closing, messages still queue: ~12 in a warm VM, 1-27k in the
  worst measured cases (OTP 26, 12 schedulers in a tight loop), i.e. a few MB
  transiently. The hard breaker (`max_mailbox: 50_000`) stops tracing beyond
  that.
* **One legacy tracer at a time.** On OTP 26 a second tracer is refused with
  `{:error, {:already_tracing, pid}}`.

* **VM-wide cost while active**: about 0.35-0.7 us on every telemetry call,
  including events nobody cares about. Captures are time-boxed for this
  reason.
* **OTP 26 (legacy backend):**
  * one tracer per process: processes already traced by another tool
    (dbg, recon_trace, observer) are skipped (reported as
    `skipped_processes`), and while TeleScope traces, those tools cannot
    trace the same processes;
  * trace patterns are global per function: if another tool has a pattern
    on `telemetry:execute/3`, TeleScope replaces its match spec, and
    cleanup removes it. Use OTP 27+ when other tracing tools are in use.
* Counts reported by the tracer are lower bounds (names are suppressed after
  discovery). Use the observer for counts.
* Events emitted before the capture starts are not seen. `mix
  telemetry.explore --runtime` starts the capture before the application to
  include boot events.
* Names longer than 16 segments, improper lists and non-lists are ignored by
  the match spec (counted as invalid only when they are lists of non-atoms).
* Handler-failure detection needs telemetry >= 1.1.
* Only `telemetry:execute/3` and `execute_lazy/3` are traced (all other entry
  points funnel into them). An `execute_lazy` call without handlers is still
  discovered by its name.

## Runtime observer

* Shapes are **depth 1**: nested maps are `:map`, lists are `:list` with no
  element types, and struct fields are not recorded (only the struct module).
* Values are never recorded, including low-cardinality atoms such as
  `result: :ok`. Recording them would help metric tagging but is a deliberate
  privacy trade-off.
* An atom value that equals a loaded module name (for example `:erlang`) is
  typed `:module`.
* Shape identity uses a 32-bit `phash2`. A collision would merge two shapes of
  the same event (unlikely; not observed).
* Non-atom keys are collapsed into one marker. String-keyed metadata (for
  example headers maps) has no key-level detail.
* `max_events` is a soft cap (enforced within `check_interval`, 50 ms).
* With sampling, counts are estimates (`count_estimated: true`).
* For names discovered by the tracer mid-capture, the observer misses the
  first occurrence(s). The count falls back to the tracer's lower bound and is
  flagged as estimated.
* Process attribution records the registered name and `$initial_call` of the
  first process seen for each shape (Tasks appear as their task function).
* Each observer puts one `:persistent_term` and erases it when stopped. The
  erase triggers a VM-wide literal-area check, once per observer. This is
  negligible for dev tools; avoid starting and stopping captures in a tight
  loop on very large systems.

## Handler inspection

* **Invocation counts are per function**, not per handler id. When several
  ids share one function, counts are flagged `invocations_attributable:
  false`.
* Handlers attached after the capture starts are picked up within 250 ms, and
  their counts start then.
* Handlers attached and detached between two refreshes are not seen.
* Invocation counting uses `call_count` tracing. On OTP 26 it is global per
  function and would conflict with another tool counting the same function.

## Catalog, diagnostics and metrics

* "Not observed" means not observed in that capture window. There is no
  "dead event" diagnostic, by design.
* `consumer_without_emitter` relies on the scan covering the emitter. Events
  emitted only by unscanned code (a release without debug info, or code
  outside `_build`) produce false warnings.
* "Did you mean" suggestions use Jaro distance >= 0.9 on dotted names.
* Multi-node: capture is node-local (handlers and trace patterns are per
  VM). A test runs a capture on a `:peer` node and merges the result. The
  catalog replaces runtime data per event rather than summing across nodes,
  so multi-node aggregation is not implemented.
* Metric suggestions are heuristics: units for `*_time` measurements that are
  not part of a `:telemetry.span/3` span are guesses (flagged), and gauges are
  recognised by name only.
* The JSON schema (version 1) is not stable yet.

## Trust boundaries

* Scan only build output you trust (your `_build`). Decoding debug info uses
  `binary_to_term` (as `beam_lib` does); a hostile `.beam` can create atoms
  and, in the worst case, exhaust the atom table. TeleScope never calls a
  debug-info backend other than `:elixir_erl` and `:erl_abstract_code`
  (configurable via `config :tele_scope, debug_info_backends: [...]`) and
  never executes scanned code.
* Reports contain source file paths as recorded in debug info. For Erlang
  modules these can be absolute paths of the build machine; review JSON
  reports before publishing them.
* Event *names* are recorded as emitted. An application that builds event
  names from user input (an anti-pattern) would expose those atoms.

## Not yet verified

* `:telemetry.persist/0` (telemetry 1.4): each attach/detach then rewrites a
  persistent term (a VM-wide literal-area scan). Functionally expected to
  work; not measured.
* Umbrella projects, Postgres-backed apps under `--runtime --serve`,
  Elixir 1.16/1.18/1.19 and OTP 28 (not installed on the audit machine).

## Environment

* All measurements were taken on one WSL2 machine. Absolute numbers will
  differ on bare metal; the relative conclusions (suppression mandatory,
  striping required, persistent_term config, argument-size independence) are
  what matters.
* The spike app used SQLite. Postgres-specific events from Postgrex /
  DBConnection were not exercised beyond the generic ones.
