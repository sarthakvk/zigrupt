---
title: Performance comparison
description: A measured comparison of zigrupt with Java Disruptor, disruptor-rs, and Ziggy.
---

**At a glance:** zigrupt had the highest median throughput in all four measured
one-producer, one-consumer workloads. Across all measured workloads it recorded
8 clear throughput wins, 2 losses, and 10 inconclusive comparisons. Its p99
latency was lower in 15 of 20 comparisons at 50% load and 14 of 20 at 90% load,
with no clear latency losses. Both throughput losses were to Rust with three
consumers and the larger ring.

This is a snapshot of zigrupt at commit
[`f9391aeaaaae9306ea93380b9f071508133aaa61`](https://github.com/sarthakvk/zigrupt/commit/f9391aeaaaae9306ea93380b9f071508133aaa61),
measured on October 8, 2026. Later versions may perform differently.

## Workload

The run compared zigrupt with [Java Disruptor 4.0.0](https://github.com/LMAX-Exchange/disruptor),
[disruptor-rs 4.4.0](https://github.com/nicholassm/disruptor-rs), and
[Ziggy](https://github.com/nubskr/ziggy). It measured one producer with either
one consumer or three consumers,
using ring capacities of 2,048 and 32,768 and event payloads of 8 and 64 bytes.
With three consumers, **every consumer received every event**. Ziggy was included
only in the one-consumer cases because its channel shares work between consumers
instead of broadcasting it.

Each producer published one event per call. Every consumer checked event order,
added every payload word to a checksum, and updated an order hash. The adapters
used each library's normal publication, batching, and waiting behavior while
doing the same application work. Throughput was timed until the last consumer
finished its events, after warmup and startup.

The run used four physical CPU cores, one worker per core, with five independent
processes per measurement. Each process targeted three seconds of warmup and two
seconds of measurement. Configurations needing five or six worker cores were not
measured on this machine.

## Throughput

The plot shows **millions of unique events completed per second**. Bars are the
median of five runs; whiskers show their observed minimum and maximum. In the
three-consumer cases, each published event produced three deliveries.

![Throughput for the eight measured workloads, showing median unique events per second and observed minimum-to-maximum ranges for zigrupt, Java Disruptor, disruptor-rs, and Ziggy where applicable.](assets/performance-throughput-2026-10-08.svg)

| Producers → consumers | Ring | Payload | zigrupt | Java | Rust | Ziggy | zigrupt factor vs Java / Rust / Ziggy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1 → 1 | 2,048 | 8 B | **180.5** | 55.5 | 117.1 | 38.5 | 3.25×† / 1.54× / 4.69× |
| 1 → 1 | 2,048 | 64 B | **98.9** | 32.4 | 87.1 | 22.0 | 3.05×† / 1.13×† / 4.50× |
| 1 → 1 | 32,768 | 8 B | **206.9** | 76.3 | 119.2 | 59.8 | 2.71× / 1.74× / 3.46× |
| 1 → 1 | 32,768 | 64 B | **103.3** | 53.0 | 99.3 | 55.7 | 1.95× / 1.04×† / 1.86× |
| 1 → 3 | 2,048 | 8 B | 17.4 | 17.9 | **45.9** | — | 0.97×† / 0.38×† / — |
| 1 → 3 | 2,048 | 64 B | 8.8 | **14.8** | 7.3 | — | 0.59×† / 1.21×† / — |
| 1 → 3 | 32,768 | 8 B | 40.4 | 33.7 | **77.9** | — | 1.20×† / 0.52× / — |
| 1 → 3 | 32,768 | 64 B | 11.0 | 15.8 | **26.4** | — | 0.69×† / 0.42× / — |

Numbers in the table are median millions of unique events per second; bold
marks the highest median in each row. Throughput factor is zigrupt's median
divided by the competitor's median, so **greater than 1× favors zigrupt**. A †
marks an inconclusive comparison: the observed ranges overlapped or the run did
not meet the report's ranking rule. The factor still describes the medians.

## Latency

The latency runs offered events at common rates set to 50% and 90% of the
slowest implementation's measured throughput for each workload. Latency ran
from the scheduled arrival of an event to completion of its consumer's work,
including producer delays, backpressure, and queueing. For three consumers,
the comparison used the slowest consumer in each run.

Zigrupt had lower p99 latency with non-overlapping observed ranges in **15 of
20 comparisons at 50% load** and **14 of 20 at 90% load**. The other p99
comparisons were inconclusive; none was a measured latency loss for zigrupt.

The plot shows median p99 latency and the observed minimum and maximum across
five runs. The horizontal scale is logarithmic so both microsecond and
second-scale results remain visible; farther left means lower latency.

![Two-panel p99 latency plot for the eight measured workloads at 50% and 90% offered rates. Median markers and min–max whiskers show zigrupt, Java Disruptor, disruptor-rs, and Ziggy where applicable. The latency axis is logarithmic and lower values are better.](assets/performance-latency-2026-10-08.svg)

| Producers → consumers | Ring | Payload | Load | zigrupt p99 (µs) | zigrupt latency factor vs Java / Rust / Ziggy |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 → 1 | 2,048 | 8 B | 50% | 3.955 | 8.46× / 1.19× / 113,342× |
| 1 → 1 | 2,048 | 8 B | 90% | 230,424.6 | 5.24×† / 2.42× / 8.69× |
| 1 → 1 | 2,048 | 64 B | 50% | 2.919 | 1.32× / 1.08× / 36,686× |
| 1 → 1 | 2,048 | 64 B | 90% | 65.7 | 15.31× / 0.09×† / 26,061× |
| 1 → 1 | 32,768 | 8 B | 50% | 554.0 | 1,465×† / 345× / 559× |
| 1 → 1 | 32,768 | 8 B | 90% | 1,428,160.5 | 2.09×† / 1.36× / 1.52× |
| 1 → 1 | 32,768 | 64 B | 50% | 433.2 | 1,360×† / 54.01× / 323× |
| 1 → 1 | 32,768 | 64 B | 90% | 1,212,153.9 | 2.20×† / 1.33× / 1.50× |
| 1 → 3 | 2,048 | 8 B | 50% | 3.359 | 4.44× / 1.12× / — |
| 1 → 3 | 2,048 | 8 B | 90% | 4.671 | 481× / 1.23× / — |
| 1 → 3 | 2,048 | 64 B | 50% | 2.331 | 2.35×† / 1.20× / — |
| 1 → 3 | 2,048 | 64 B | 90% | 4.391 | 1,582× / 100× / — |
| 1 → 3 | 32,768 | 8 B | 50% | 5.279 | 520,415×† / 1.32× / — |
| 1 → 3 | 32,768 | 8 B | 90% | 473,956.4 | 15.63×† / 1.93× / — |
| 1 → 3 | 32,768 | 64 B | 50% | 2.919 | 1.47×† / 3.84× / — |
| 1 → 3 | 32,768 | 64 B | 90% | 12.6 | 8.32×† / 102× / — |

Latency factor is the competitor's median p99 divided by zigrupt's median p99,
so **greater than 1× means zigrupt had lower latency**. A † again marks an
inconclusive comparison. Large factors here reflect backlogs at the scheduled
arrival rate; they are ratios of measured medians, not speedups at every load.

These results describe this workload and machine at the linked commit. The
one-consumer throughput lead and the latency results are strong points of this
run; three-consumer throughput has a different shape, particularly against Rust
with the larger ring.
