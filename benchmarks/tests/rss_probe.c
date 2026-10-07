#include <stdint.h>
#include <stdio.h>
extern uint64_t bench_rss(void);
int main(void) {
    printf("%llu\n", (unsigned long long)bench_rss());
    return 0;
}
