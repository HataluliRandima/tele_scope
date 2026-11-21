# Benchmarks

TeleScope has non-zero overhead. This document reports what it costs, how
it was measured, and the budgets proposed for the MVP. Raw outputs are in
[bench/results](bench/results) and [experiments/results](experiments/results).

## Methodology

* **Machine:** Linux 6.6 under WSL2, 12 schedulers, 7 GB RAM, shared with
  other containers. Timing noise is high: the same no-handler baseline
  measured between 59 and 480 ns per call across runs.
* **Runtime overhead** (`bench/runtime_overhead.exs`): a tight loop of
  `:telemetry.execute/3` (N = 200,000) in compiled code; each configuration is
  run 7 times and the **minimum** is reported (the most reproducible estimate
  of intrinsic cost on a noisy machine; medians were tried first and varied by
  up to 2x between runs). Overheads are relative to a baseline measured in the
  same run. The concurrent variant runs 12 processes emitting the *same* event
  (worst case for shared state) and reports wall-clock ns per event.
* **Payloads:** "small" = 4 metadata keys; "large" = 30 keys including a
  struct, a 10 KB binary and a 100-element list.
* **Static scan** (`bench/static_scan.exs`): 5 runs over the spike app
  (`_build/dev`, 36 applications, 840 beams); peak memory sampled every 2 ms.
* Versions: OTP 26.1.2 (legacy tracing), 27.0 and 29.0 (trace sessions).
* Variance: treat differences below ~150 ns as noise. The OTP 27
  large-payload observer figure was +2,259 ns in one run and +3,051 ns in
  another.

Reproduce:

```sh
mix run bench/runtime_overhead.exs
(cd spike/demo_app && mix run --no-start ../../bench/static_scan.exs)
mix run experiments/trace_argsize_experiment.exs
mix run experiments/handler_config_experiment.exs
```

## 1. Runtime overhead per `:telemetry.execute/3`

Added nanoseconds per call (single process, minimum of 7 runs):

| Configuration | OTP 26 small | OTP 26 large | OTP 27 small | OTP 27 large | OTP 29 small | OTP 29 large |
|---|---|---|---|---|---|---|
| baseline (absolute, no handlers) | 145 | 151 | 172 | 157 | 190 | 132 |
| reference: one no-op handler | +59 | +59 | +52 | +60 | +55 | +48 |
| **observer** (shape recording) | **+1,144** | **+2,384** | **+1,178** | **+3,051** | **+1,158** | **+2,234** |
| observer, `sample_rate: 0.1` | +372 | +520 | +470 | +618 | +473 | +510 |
| observer after `max_events` (no-op path) | +182 | +197 | +213 | +331 | +218 | +195 |
| **tracer**, name known (suppressed) | **+618** | **+554** | **+655** | **+630** | **+353** | **+434** |
| tracer, 5,000 suppressed names | +594 | +581 | +631 | +689 | +413 | +401 |
| tracer **without** suppression (worst case) | +1,514 | +1,560 | +1,771 | +1,694 | +1,432 | +1,253 |
| no-op handler + `call_count` tracking | +77 | +103 | +79 | +65 | +30 | +78 |
| full capture (observer + tracer) | +1,978 | +4,112 | +2,057 | +3,224 | +1,581 | +3,192 |

Notes:

* **The tracer cost applies to every telemetry call in the VM** while a
  capture is active, including events nobody observes. It does not depend on
  payload size (`experiments/trace_argsize_experiment.exs`: +0.56-1.0 us from
  empty metadata to 1,000-element lists, both backends).
* The observer cost applies only to events it is attached to and grows with
  the number of keys (shape computation + hashing).
* Session and legacy tracing cost about the same.

### Concurrency (12 processes, same event, small metadata; wall-clock ns per event)

| Configuration | OTP 26 | OTP 27 | OTP 29 |
|---|---|---|---|
| baseline | 95 | 75 | 59 |
| one no-op handler | 177 | 121 | 97 |
| observer v1: one ETS row per shape + `:atomics` cap (**rejected**) | **103,670** | - | - |
| observer v2/v3: per-scheduler stripes + `:counters` | 907 | 687 | 531 |
| tracer, name suppressed | 446 | 424 | 259 |

The final observer's concurrent/baseline ratio (9.2-9.5x) matches its
single-process ratio (8.9x), so no measurable contention remains. The absolute
concurrent figures mostly reflect this machine's poor parallel scaling (the
baseline itself scales poorly).

### Handler config copying (`experiments/handler_config_experiment.exs`)

`:telemetry` copies the handler record, config included, out of ETS on every
execute. Added ns per event with 12 concurrent emitters (min of 5):

| Handler config | Added |
|---|---|
| `nil` | +27 |
| map of 7 integers | +53 |
| map with ETS tid + `:counters` + `:atomics` refs | **+184** |
| small key + `:persistent_term.get/2` (adopted) | +56 |

## 2. Tracer messages and mailbox

| Scenario | Messages | Peak tracer mailbox |
|---|---|---|
| Spike capture (825 events, 79 distinct names, ground-truth mode) | 234-238 | 0 |
| Benchmark, name suppressed | ~0 per call | 0 |
| Benchmark, suppression disabled, 1.4 M calls | 1,414,000 | **464,000-565,000** |
| Size per message (`arity` + name only) | 14-16 words | - |
| Size per message without `arity` (10 KB metadata) | 2,044 words | - |

Without suppression, a single busy event can grow the tracer mailbox by
hundreds of thousands of messages within a second. Hence: suppression is
always on in normal use, and the circuit breaker (default `max_mailbox:
10_000`) stops tracing; a test floods 20 processes x 5,000 events to verify it
trips.

## 3. Memory

| Component | Measurement |
|---|---|
| Observer ETS, 200 events x 5 shapes (1,000 shapes) | 596 KB (~600 B per shape incl. stripes and registry) |
| Growth after +100,000 events of existing shapes | +1.8 KB (one new shape; counters are updated in place) |
| Observer ETS, spike capture (80 observed events) | 103-125 KB |
| Default bound | `max_rows: 100_000` (+ small per-event bookkeeping) -> roughly 60 MB worst case; `max_shapes_per_event: 32` |
| Tracer state | one small map per discovered name; bounded by `max_names: 1_000` |
| Static scan peak extra memory (840 beams) | 47 MB (forms of the 48 decoded modules + index) |
| Static scan, 1,263 OTP/Elixir beams (no candidates) | 14 MB |

## 4. Static scanning time

| Corpus | Beams | Decoded | Wall time (min / median / max of 5) | Peak memory |
|---|---|---|---|---|
| Spike app `_build/dev` (36 apps) | 840 | 48 | 524 / 596 / 998 ms | +47 MB |
| Whole OTP + Elixir install (37 apps) | 1,263 | 0 | 416 / 442 / 1,117 ms (3 runs) | +14 MB |

History: the first implementation took **6.7 s** on the spike app because
every parallel task's closure captured the whole forms cache. Passing each
task only its own forms brought it to 0.56 s.

## 5. Budgets (proposed for the MVP)

| Area | Budget | Status in spike |
|---|---|---|
| Static scan, 1,000-module app | < 2 s, < 150 MB | 0.6 s, 47 MB (840 modules) |
| Observer, typical event (<= 10 keys) | <= 2 us/event | ~1.1-1.2 us |
| Observer, large event (30 keys) | <= 4 us/event; recommend sampling above 50k events/s | 2.2-3.1 us |
| Tracer while active | <= 1 us per telemetry call, VM-wide | 0.35-0.69 us |
| Tracer mailbox | <= 10,000 messages (breaker) | 0 in practice |
| Observer memory | <= 100,000 rows | bounded by design and tests |
| Capture duration | tracer 10 s default, 10 min max | enforced |

In practical terms: an application emitting 10,000 events per second under
a full capture (observer + tracer) spends about 20-40 ms of CPU per second,
2-4 % of one core. With `sample_rate: 0.1` and tracing off, about 4-6 ms.
Capture is meant for dev, staging and short, sampled production sessions. It
is not meant to run permanently.
