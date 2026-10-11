---
title: Startup, shutdown, and restart
description: Lifecycle ownership, draining, failure cleanup, and restart semantics.
---

The thread that calls `init()` owns `start()` and `stop()`. Moving the bus to
another thread does not transfer ownership; calls from that thread return
`error.NotLifecycleOwner`. Keep the bus at a stable address while it is running.

## Startup and failure cleanup

`init()` allocates ring slots, publication markers, consumer progress, and thread
handles. It returns an idle bus and frees partial allocations if initialization
fails. Call `deinit()` exactly once on a successfully initialized bus.

`start()` creates the handler threads and returns with the bus running. Publish
only after it returns successfully. If thread creation fails, `start()` stops and
joins any threads it already created, then leaves the bus idle. Propagate the
error without calling `stop()`; the initialized bus still needs `deinit()`.

The [first program](/getting-started/#try-it) places its error-path
stop after successful startup and its deinitialization immediately after init.

## Safe shutdown

1. Prevent new work from starting in application producers.
2. Let all active `produce()` calls finish and join every producer thread.
3. Call `stop()` on the initializing thread. It drains completed publications,
   joins handler threads, and returns with the bus idle.
4. Read handler-owned results and call `deinit()` when finished with the bus.

If producers are still publishing when `stop()` begins, events may be missed.
`stop()` does not cancel producers. It can wait indefinitely for a blocked handler
or one that never acknowledges progress. There is no drain timeout.

Do not hold an application lock needed by a handler while joining it. Similarly,
a handler waiting for the owner to finish `stop()` creates a shutdown cycle.

## Restart

After successful stop, the owner can call `start()` again on the same bus.
Consumer and producer progress is preserved, so acknowledged events are not
replayed. Handler threads are recreated. Retain or reset application state only
after the old threads have joined. To change type-level configuration, define a
new bus type; to change runtime capacity, initialize a new bus.

`start()` and `stop()` are not idempotent. Starting a running bus returns
`BusRunning`; stopping an idle bus returns `BusIdle`.
