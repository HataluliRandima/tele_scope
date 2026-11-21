# TeleScope security and privacy review

Part of the pre-release audit ([PRE_RELEASE_AUDIT.md](PRE_RELEASE_AUDIT.md)).
Every statement marked **verified** was checked by an executed test or
reproduction; references point to the tests.

## Threat model

TeleScope is a **development tool**. It reads the compiled output of the
user's own project (`_build`) and, when explicitly asked, observes the
running VM for a bounded time. Assets to protect:

1. telemetry measurement/metadata **values** (may contain user data,
   credentials, query parameters);
2. handler **configs** (may contain API keys, e.g. reporter credentials);
3. the **availability and memory** of the observed VM;
4. the integrity of the scanning process when given untrusted files.

Out of scope: protecting against code that already runs in the VM (it can
read everything TeleScope can).

## 1. Raw telemetry values are never persisted - verified

| Path | Mechanism | Evidence |
|---|---|---|
| Observer (ETS) | only key names and type tags (`Shape.of_unsorted/2`); structs reduced to `{:struct, Module}`; non-atom keys collapsed to one marker | `observer_test.exs` "records counts, shapes ... never values" searches the whole snapshot for the raw values; `shape_test.exs` nested struct test |
| Tracer | `arity` flag + name-only match spec: measurements/metadata are never copied to the tracer (14-16 word messages) | `tracer_test.exs` match-spec test with a 100 KB payload; experiments/trace_shape_experiment.exs |
| Handler-failure recording | stores handler id, event name and error kind; **not** the failure `reason`, `stacktrace` or `handler_config` that telemetry passes in the failure metadata | `observer.ex` `handle_failure/4` |
| Process attribution | registered name and `$initial_call` only. The tracer reads **one** dictionary key of another process (`process_info(Pid, {dictionary, Key})`), never the whole dictionary | `tracer.ex` `process_info/1` |
| Reports (console/JSON) | built from the catalog only | pipeline test |

Values that **are** recorded: event names (atoms), metadata/measurement key
names (atoms), struct module names, handler ids, MFAs, registered process
names, source file paths. Event names built from user input (an
anti-pattern) would therefore appear in reports.

## 2. Handler configurations are not exposed - verified

`TeleScope.Runtime.Handlers.list/0` reduces each handler's `config` to its
type tag (`config_type: :map`); the config term is never copied into
results. Test: `handlers_test.exs` "global enumeration ..." asserts that a
config containing `password` does not appear in the output. Anonymous
handler closures: only the *number* of captured variables is used (to
compute the function arity), never their values.

## 3. Sensitive metadata handling - verified (fixed in audit)

TeleScope cannot leak values it does not store, but reporters attached to
the same events can. It therefore warns (`sensitive_key`) when a key name
looks sensitive. The pre-audit substring regex produced false positives that
failed `--strict` CI (P1-6). Detection now matches whole key segments
(`password_hint`, `api_key`, `apiKey`, `client_secret`, `session_id`, ...)
and ignores `author_id`, `passenger_count`, `classname`, `otp_app`, ...
Tests: `audit_regressions_test.exs` "sensitive key detection".

## 4. Bounded storage - verified

| Store | Bound | Test |
|---|---|---|
| Observer ETS rows | `max_rows` (100k) + small per-event bookkeeping | "max_rows bounds table growth under shape explosion" |
| Shapes per event | `max_shapes_per_event` (32), overflow counted | "number of distinct shapes per event is bounded" |
| Observed events | `max_events` soft cap (enforced within `check_interval`) | "very high volume ..." |
| Keys per map | `max_keys` (64) -> `{:too_many_keys, n}` | shape_test |
| Attached events | `max_attached_events` (5,000) | - |
| Tracer names | `max_names` (1,000) | "max_names cap" |
| Tracer messages | `max_messages` (200k) | - |
| Tracer mailbox | suppression + gate (1,000) + hard breaker (50,000) | R2 tests, "mailbox circuit breaker ..." |
| Handler-failure rows | one per failing handler id (telemetry detaches it on first failure) | - |
| Persistent terms | one per observer, erased on stop and by janitor on kill | "no persistent_term config leaks ..." |

## 5. Trace messages and memory growth - verified (fixed in audit)

Pre-audit, a single hot new event queued ~240k messages before suppression
landed (P0-1). After the fix, a burst queues 12 messages in a warm path and
1-2.4k in the worst measured case; with suppression disabled, 1.6-2.3k (was
464-565k). Remaining exposure: messages already in flight when the gate
closes (~1.5-2k measured) and, on pathological hosts, the scheduling latency
of a high-priority process. The hard breaker caps the mailbox at 50,000
messages (~8 MB) and stops tracing. Tests: R2 group.

## 6. Untrusted BEAM inputs - partially mitigated, documented

| Risk | Status |
|---|---|
| Arbitrary module invocation via the debug-info backend named in the file | **Fixed** (allowlist `:elixir_erl`, `:erl_abstract_code`; extendable only by explicit config). Test: R6 |
| Garbage / truncated files | Handled: classified `:invalid_beam` (integrity check with `beam_lib:all_chunks/1`), never crash. Tests: "invalid and truncated BEAM files are reported" |
| Missing debug info | Classified `:no_debug_info`, reported as a blind spot |
| Pathological but valid code (combinatorial names) | **Fixed** (R7); analyzer fuzzed over 2,128 modules, 0 crashes |
| Atom table exhaustion | **Accepted, documented.** Decoding debug info uses `binary_to_term` (as `beam_lib` itself does), and metric/prefix names are converted with `String.to_atom/1`. A hostile `.beam` could create many atoms. Mitigation: TeleScope only scans the user's `_build` by default; scanning untrusted directories is unsupported |
| Code execution | TeleScope never loads or executes scanned modules (`beam_lib` only; scanned code is not loaded) |

## 7. VM integrity during runtime capture

* Nothing runs unless explicitly started; every runtime component is
  time-boxed and stops when its owner dies (tests for each).
* The callback running inside the user's processes never raises (wrapped;
  `callback_errors` counted) and is a no-op after its observer dies.
* The tracer modifies VM-global tracing state: on OTP 26, `erlang:trace/3`
  flags on all processes and global patterns on `telemetry:execute/3`
  (exclusive lock); on all versions, one bit of the trace control word. All
  of it is restored on stop and by janitors on `:kill` (tests).
* `:persistent_term` writes trigger a VM-wide literal-area check when
  erased (once per observer).

## 8. Supply chain

Runtime dependency: `:telemetry` only. Dev-only: `:ex_doc` (and its
transitive deps) for documentation. The Hex package ships `lib/`, `mix.exs`
and documentation only (explicit `files` allowlist); the spike application,
experiments and benchmark outputs are not shipped.

## 9. Recommendations

1. Keep the "scan only your own `_build`" stance explicit in README (done in
   LIMITATIONS.md "Trust boundaries").
2. Before 1.0, consider `binary_to_existing_atom`-style handling for metric
   names (ignore unknown atoms) to remove the atom-creation path for metric
   strings.
3. Add a "redact source paths" option for JSON reports that will be shared.
