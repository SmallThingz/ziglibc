#include <signal.h>
#include <stddef.h>

#if defined(__GNUC__) || defined(__clang__)
#define ZIGLIBC_INTERNAL __attribute__((visibility("hidden")))
#else
#define ZIGLIBC_INTERNAL
#endif

ZIGLIBC_INTERNAL size_t _zsignalRaw(int sig, size_t func);

void (*signal(int sig, void (*func)(int)))(int)
{
    return (void (*)(int))_zsignalRaw(sig, (size_t)func);
}
