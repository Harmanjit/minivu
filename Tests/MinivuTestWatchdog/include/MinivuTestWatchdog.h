#ifndef MINIVU_TEST_WATCHDOG_H
#define MINIVU_TEST_WATCHDOG_H

#include <stdbool.h>

// A watchdog for the test run, started when the test bundle loads, before
// Swift Testing runs a single test, on a plain thread of its own. Neither
// its start nor its checks need a thread from Swift's cooperative pool or
// GCD, so it works in exactly the state that hung the run on macOS 27
// (see docs/feature-notes/coop-starvation.md): every cooperative thread
// blocked, GCD starting nothing at the default QoS, and no test able to
// run, fail or time out.
//
// Once a second it queues a trivial item on GCD's default-QoS global queue
// and waits for it to run. In a healthy run that takes microseconds, even
// on a loaded Mac; while the pool is starved it never runs. If it hasn't
// run within the stall limit, the watchdog prints why on standard error
// and ends the process with a failure, so the run fails instead of
// hanging at 0% CPU for ever.
//
// The limit is 30 seconds times the run's slack (`MINIVU_TEST_SLACK`, 4 in
// debug builds, as in TestTiming.swift): well beyond the longest the
// regression tests hold the pool on purpose. `MINIVU_TEST_WATCHDOG=<seconds>`
// sets it, and `MINIVU_TEST_WATCHDOG=0` turns the watchdog off, for
// attaching `sample` to a hung run.

/// True once the watchdog thread has started (false when turned off).
bool minivu_test_watchdog_is_running(void);

/// The stall limit in seconds, 0 when the watchdog is off.
double minivu_test_watchdog_stall_limit(void);

/// The watchdog's check, from the calling thread: queues a trivial item on
/// GCD's default-QoS global queue and returns whether it ran within
/// `seconds`. An item that hasn't run yet still runs (harmlessly) later.
bool minivu_test_default_queue_runs_within(double seconds);

#endif
