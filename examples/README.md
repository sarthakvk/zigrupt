# Executable usage examples

Use Zig 0.16.0 from the repository root. No Node installation is needed.

```sh
zig build examples                 # compile all six
zig build check-examples           # execute all six, checking results
zig build example-basic            # or run one example
```

| Build step | Source | Expected output |
| --- | --- | --- |
| `example-basic` | [basic.zig](basic.zig) | `basic: sum = 55` |
| `example-broadcast` | [broadcast.zig](broadcast.zig) | `broadcast: both handlers received 100 events` |
| `example-multi_producer` | [multi_producer.zig](multi_producer.zig) | `multi_producer: 300 events, each producer ordered` |
| `example-batching` | [batching.zig](batching.zig) | `batching: 100 events consumed in order after one retry` |
| `example-context` | [context.zig](context.zig) | `context: two handlers counted 100 bytes` |
| `example-waiting_strategy` | [waiting_strategy.zig](waiting_strategy.zig) | `waiting_strategy: 100 events delivered using Yield` |

Each is a standalone program with explicit result checks that remain active in
release builds. Output uses `std.debug.print` (stderr). Concurrent runs may print
in any order. Counts and sums are checked only after `stop()` joins consumers.

The batching example demonstrates bounded prefix processing; actual callback
sizes depend on scheduling. The existing batch tests exercise deterministic
partial-batch boundaries. The waiting example demonstrates a strategy, not a
performance recommendation or a guarantee that the scheduler switches threads.

The [consumer build file](consumer/build.zig) is the canonical installation
configuration. From the repository root, `python3 scripts/check-install.py`
packages the current tree, initializes a separate temporary project, fetches
the archive as a hashed dependency, imports `zigrupt`, and builds/runs `basic.zig`
as its main program. It requires Python 3 and Zig, and uses no network.

Documentation code blocks are generated from these files. After an example
change, run `node docs/scripts/sync-snippets.mjs` and commit the refreshed Markdown.
