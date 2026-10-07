#define _GNU_SOURCE
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#ifdef JNI
#include <jni.h>
#endif

static uint64_t clock_ns(clockid_t clock) {
    struct timespec ts;
    if (clock_gettime(clock, &ts)) abort();
    return (uint64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}
uint64_t bench_now(void) { return clock_ns(CLOCK_MONOTONIC); }
uint64_t bench_cpu(void) { return clock_ns(CLOCK_PROCESS_CPUTIME_ID); }
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
void bench_pin(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    if (cpu < 0 || cpu >= CPU_SETSIZE) abort();
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set)) { perror("affinity"); abort(); }
    cpu_set_t actual;
    if (sched_getaffinity(0, sizeof(actual), &actual) || !CPU_EQUAL(&set, &actual)) abort();
}
void bench_sleep(void) {
    struct timespec ts = {0, 1000000};
    nanosleep(&ts, NULL);
}
#ifdef JNI
JNIEXPORT void JNICALL Java_Bench_pin(JNIEnv *env, jclass cls, jint cpu) {
    (void)env; (void)cls; bench_pin(cpu);
}
JNIEXPORT jlong JNICALL Java_Bench_cpu(JNIEnv *env, jclass cls) {
    (void)env; (void)cls; return bench_cpu();
}
JNIEXPORT jlong JNICALL Java_Bench_rss(JNIEnv *env, jclass cls) {
    (void)env; (void)cls; return bench_rss();
}
#endif
#ifdef ZIG_MAIN
extern int bench_main(int argc, char **argv);
int main(int argc, char **argv) { return bench_main(argc, argv); }
#endif
