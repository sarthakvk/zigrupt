#define _GNU_SOURCE
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#ifdef JNI
#include <jni.h>
#endif

/** Returns nanoseconds from the selected process or wall clock. */
static uint64_t clock_ns(clockid_t clock) {
    struct timespec ts;
    if (clock_gettime(clock, &ts)) abort();
    return (uint64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}
/** Returns monotonic wall-clock time in nanoseconds. */
uint64_t bench_now(void) { return clock_ns(CLOCK_MONOTONIC); }
/** Returns process CPU time in nanoseconds. */
uint64_t bench_cpu(void) { return clock_ns(CLOCK_PROCESS_CPUTIME_ID); }
/** Returns this executable's peak resident memory in bytes. */
uint64_t bench_rss(void) {
    // VmHWM belongs to this executable's address space. getrusage also retains
    // the Python launcher's resident memory inherited by fork before exec.
    FILE *status = fopen("/proc/self/status", "r");
    if (!status) abort();
    char line[256];
    unsigned long long kib;
    while (fgets(line, sizeof(line), status)) {
        if (sscanf(line, "VmHWM: %llu kB", &kib) == 1) {
            fclose(status);
            return (uint64_t)kib * 1024;
        }
    }
    fclose(status);
    abort();
}
/** Pins the calling thread to one CPU and verifies its affinity. */
void bench_pin(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    if (cpu < 0 || cpu >= CPU_SETSIZE) abort();
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set)) { perror("affinity"); abort(); }
    cpu_set_t actual;
    if (sched_getaffinity(0, sizeof(actual), &actual) || !CPU_EQUAL(&set, &actual)) abort();
}
/** Sleeps briefly while waiting for a benchmark phase transition. */
void bench_sleep(void) {
    struct timespec ts = {0, 1000000};
    nanosleep(&ts, NULL);
}
#ifdef JNI
/** Exposes CPU pinning to the Java benchmark. */
JNIEXPORT void JNICALL Java_Bench_pin(JNIEnv *env, jclass cls, jint cpu) {
    (void)env; (void)cls; bench_pin(cpu);
}
/** Exposes process CPU time to the Java benchmark. */
JNIEXPORT jlong JNICALL Java_Bench_cpu(JNIEnv *env, jclass cls) {
    (void)env; (void)cls; return bench_cpu();
}
/** Exposes peak resident memory to the Java benchmark. */
JNIEXPORT jlong JNICALL Java_Bench_rss(JNIEnv *env, jclass cls) {
    (void)env; (void)cls; return bench_rss();
}
#endif
#ifdef ZIG_MAIN
extern int bench_main(int argc, char **argv);
/** Forwards the native executable's entry point to the Zig benchmark. */
int main(int argc, char **argv) { return bench_main(argc, argv); }
#endif
