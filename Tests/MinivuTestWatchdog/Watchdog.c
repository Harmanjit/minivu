#include "MinivuTestWatchdog.h"

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static double stallLimit = 0;
static atomic_bool running = false;

/// A positive number from the environment, or `fallback`. With
/// `allowZero`, 0 counts too (it turns the watchdog off).
static double environmentNumber(const char *name, double fallback, bool allowZero) {
    const char *text = getenv(name);
    if (text == NULL || *text == '\0') return fallback;
    char *end = NULL;
    double value = strtod(text, &end);
    if (end == text || *end != '\0') return fallback;
    if (value > 0 || (allowZero && value == 0)) return value;
    return fallback;
}

static void signalAndRelease(void *context) {
    dispatch_semaphore_t semaphore = context;
    dispatch_semaphore_signal(semaphore);
    dispatch_release(semaphore);
}

bool minivu_test_default_queue_runs_within(double seconds) {
    dispatch_semaphore_t ran = dispatch_semaphore_create(0);
    // The item holds its own reference: after a timeout it still runs
    // later, once GCD has a thread for it, and must find the semaphore.
    dispatch_retain(ran);
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ran, signalAndRelease);
    bool inTime = dispatch_semaphore_wait(ran, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;
    dispatch_release(ran);
    return inTime;
}

bool minivu_test_watchdog_is_running(void) {
    return atomic_load(&running);
}

double minivu_test_watchdog_stall_limit(void) {
    return atomic_load(&running) ? stallLimit : 0;
}

static void *watch(void *unused) {
    (void)unused;
    pthread_setname_np("minivu test watchdog");
    for (;;) {
        sleep(1);
        if (!minivu_test_default_queue_runs_within(stallLimit)) {
            fprintf(stderr,
                "\nminivu test watchdog: GCD ran nothing at the default QoS for %.0f s. The cooperative pool is\n"
                "starved: every one of its threads is blocked, most likely in Vision, a HEIF or AVIF encode or an\n"
                "AVFoundation wait called from a test without BlockingWork or the .offCooperativePool trait.\n"
                "Ending the run instead of hanging; see docs/feature-notes/coop-starvation.md. Look for\n"
                "\"minivu: ... blocked a cooperative thread\" above, or run again with MINIVU_TEST_WATCHDOG=0\n"
                "and take a `sample` of the hung process.\n", stallLimit);
            fflush(stderr);
            _exit(EXIT_FAILURE);
        }
    }
    return NULL;
}

__attribute__((constructor))
static void startWatchdog(void) {
#ifdef DEBUG
    double slack = environmentNumber("MINIVU_TEST_SLACK", 4, false);
#else
    double slack = environmentNumber("MINIVU_TEST_SLACK", 1, false);
#endif
    stallLimit = environmentNumber("MINIVU_TEST_WATCHDOG", 30 * slack, true);
    if (stallLimit == 0) return;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    if (pthread_create(&thread, &attributes, watch, NULL) == 0) atomic_store(&running, true);
    pthread_attr_destroy(&attributes);
}
