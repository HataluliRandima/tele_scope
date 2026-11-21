# Benchmarks

TeleScope has non-zero overhead. This document reports what it costs, how
it was measured, and the budgets proposed for the MVP. Raw outputs are in
[bench/results](https://github.com/HataluliRandima/tele_scope/tree/main/bench/results) and [experiments/results](https://github.com/HataluliRandima/tele_scope/tree/main/experiments/results).

## Methodology

* **Machine:** Linux 6.6 under WSL2, 12 schedulers, 7 GB RAM, shared with
  other containers. Timing noise is high: the same no-handler baseline
  measured between 59 and 480 ns per call across runs.
* **Runtime overhead** (`bench/runtime_overhead.exs`): a tight loop of
  `:telemetry.execute/3` (N = 200,000) in compiled code; each configuration is
  run 7 times and **min / median / max** are reported. The minimum is the
  most reproducible estimate of intrinsic cost on a noisy machine but is a
  best case; read the median for typical cost. Overheads are relative to a baseline measured in the
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

Re-measured after the pre-release audit (tracer gate, async installer), with
**minimum and median** of 7 runs (the original spike reported minimums only,
which understates typical cost). Added nanoseconds per call:

| Configuration | OTP 26 small min / median | OTP 26 large min / median | OTP 27 small min / median | OTP 27 large min / median |
|---|---|---|---|---|
| baseline (absolute, no handlers) | 151 / 167 | 134 / 144 | 180 / 216 | 151 / 156 |
| reference: one no-op handler | +54 / +299* | +35 / +41 | +25 / +3 | +69 / +83 |
| **observer** (shape recording) | +2,243 / +4,271* | **+2,393 / +2,455** | **+1,101 / +1,461** | **+2,740 / +3,137** |
| observer, `sample_rate: 0.1` | +485 / +616 | +542 / +840 | +638 / +693 | +531 / +619 |
| observer after `max_events` (no-op path) | +333 / +428 | +307 / +334 | +396 / +647 | +275 / +311 |
| **tracer**, name known (suppressed) | **+715 / +787** | **+695 / +739** | **+1,035 / +1,287** | **+829 / +894** |
| tracer, 5,000 suppressed names | +734 / +797 | +903 / +961 | +1,474 / +1,508 | +646 / +666 |
| tracer **without** suppression | +1,168 / +1,238 | +1,369 / +1,467 | +1,771 / +2,518 | +955 / +1,240 |
| no-op handler + `call_count` tracking | +59 / +71 | +134 / +156 | +88 / +116 | +70 / +84 |
| full capture (observer + tracer) | +1,934 / +2,206 | +3,063 / +3,681 | +2,245 / +2,685 | +4,411 / +5,311 |

\* noisy rows: the no-op handler median (+299 ns) and the small-metadata
observer (+4.3 us median, higher than the 30-key case) are interference on
the WSL2 host, not intrinsic cost. Earlier runs of the same code measured the
small-metadata observer at +1.1-1.2 us on OTP 26, 27 and 29.

Summary ranges used elsewhere in the docs:

* observer: **~1.1-2.5 us** per observed event (4 keys), **~2.2-3.2 us** (30 keys);
  **~0.5-0.85 us** with `sample_rate: 0.1`;
* tracer: **~0.35-1.5 us per telemetry call, VM-wide**, independent of payload;
  the gate guard added by the audit costs nothing measurable
  (`experiments/trace_gate_cost_experiment.exs`: median -77 ns / -10 ns, within noise);
* `call_count` tracking: ~0.03-0.16 us per handler call.

Earlier spike measurements (pre-audit code, minimum only, including OTP 29)
are kept in git history; they are consistent with the ranges above.

Notes:

* **The tracer cost applies to every telemetry call in the VM** while a
  capture is active, including events nobody observes. It does not depend on
  payload size (`experiments/trace_argsize_experiment.exs`).
* The observer cost applies only to events it is attached to and grows with
  the number of keys.
* Session and legacy tracing cost about the same.

### Concurrency (12 processes, same event, small metadata; wall-clock ns per event, min / median)

| Configuration | OTP 26 | OTP 27 |
|---|---|---|
| baseline | 47 / 61 | 51 / 65 |
| one no-op handler | 77 / 83 | 87 / 98 |
| observer v1: one ETS row per shape + `:atomics` cap (**rejected in the spike**) | **103,670** (min) | - |
| observer: per-scheduler stripes + `:counters` | 455 / 532 | 386 / 432 |
| tracer, name suppressed | 237 / 267 | 264 / 330 |

The striped observer's concurrent/baseline ratio is in the same range as its
single-process ratio, i.e. no contention of the magnitude seen in v1. This is
a ratio argument on a noisy machine, not proof of zero contention.

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
| Size per message (`arity` + name only) | 14-16 words | - |
| Size per message without `arity` (10 KB metadata) | 2,044 words | - |
| **Burst of ONE new hot name**, 12 schedulers x 20,000 calls, *before* the audit fix | 240,000 | **239,746** (breaker tripped) |
| same, after the fix, first burst in a fresh VM (OTP 26) | 12 | 0 |
| same, after the fix, subsequent bursts (OTP 26) | 1,500-3,700 | 1,100-2,400 (gate closed once, 20-110 ms) |
| same, after the fix (OTP 27) | 1,300-4,200 | 1,200-1,800 (gate 57-80 ms) |
| Suppression disabled, 1M calls, before the fix | 1,414,000 | 464,000-565,000 |
| Suppression disabled, 1M calls, after the fix (gate cycles) | 840,000-1,060,000 | **1,650-2,310** |

Why the fix was needed (`experiments/trace_gate_experiment.exs`): re-installing
a trace pattern while all schedulers emit takes **53-166 ms** (thread-progress
barrier); a hot new name leaks one message per call during that window.
Closing the trace-control-word gate takes **1-2 us** and stops the growth
(~1.5-1.9k messages already in flight). A second contributor was lazy code
loading of the tracer's message path in a fresh VM (first burst: 7k-87k queued
messages before preloading, 12 after).

The circuit breaker (default `max_mailbox: 50_000`, ~8 MB of messages) is a
last resort; a test floods 20 processes x 5,000 events with suppression
disabled and a tiny limit to verify that it still trips.

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
| Observer, typical event (<= 10 keys) | <= 2 us/event | 1.1-1.5 us typical; one noisy run at 2.2-4.3 us |
| Observer, large event (30 keys) | <= 4 us/event; recommend sampling above 50k events/s | 2.2-3.2 us |
| Tracer while active | <= 1 us per telemetry call, VM-wide | 0.35-0.9 us at the minimum; medians up to 1.5 us on OTP 27 on this host: **at risk**, re-measure on bare metal |
| Tracer mailbox | <= 50,000 messages hard limit; gate at 1,000 | 0 in practice; <= 2.4k in synthetic bursts after the audit fix |
| Observer memory | <= 100,000 rows | bounded by design and tests |
| Capture duration | tracer 10 s default, 10 min max | enforced |

In practical terms: an application emitting 10,000 events per second under
a full capture (observer + tracer) spends about 20-55 ms of CPU per second,
2-5.5 % of one core (min-median range above). With `sample_rate: 0.1` and tracing off, about 4-6 ms.
Capture is meant for dev, staging and short, sampled production sessions. It
is not meant to run permanently.
