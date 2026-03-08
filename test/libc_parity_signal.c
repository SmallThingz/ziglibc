#include <errno.h>
#include <signal.h>
#include <string.h>
#include "test_markers.h"

static void parity_handler(int sig) { (void)sig; }

int main(void)
{
  {
    TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "parity:block:signal");
    void (*old_handler)(int) = signal(SIGINT, parity_handler);
    void (*prev_handler)(int) = signal(SIGINT, old_handler);
    printf("signal-basic:%d:%d:%d:%d|", old_handler != SIG_ERR, prev_handler == parity_handler, old_handler == SIG_DFL, prev_handler == SIG_DFL);
  }

  {
    TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "parity:block:strtol");
    const char *s = "abc"; char *endptr = NULL; long value; long dist;
    errno = 123; value = strtol(s, &endptr, 10); dist = (long)(endptr - s);
    printf("strtol-nodigits:%ld:%d:%ld|", value, errno, dist);
  }

  {
    TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "parity:block:strtod");
    const char *s = "abc"; char *endptr = NULL; double value; long dist;
    errno = 123; value = strtod(s, &endptr); dist = (long)(endptr - s);
    printf("strtod-nodigits:%d:%d:%ld|", value == 0.0, errno, dist);
  }

#if LIBC_PARITY_HAVE_STRSIGNAL
  {
    const char *name = strsignal(SIGINT);
    printf("strsignal-int:%s|", name ? name : "null");
  }
#else
  printf("strsignal-int:skip|");
#endif

#if LIBC_PARITY_HAVE_SIGACTION
  {
    struct sigaction act; struct sigaction old; struct sigaction restore;
    memset(&act, 0, sizeof(act));
    memset(&old, 0, sizeof(old));
    memset(&restore, 0, sizeof(restore));
    act.sa_handler = parity_handler;
    printf("sigaction-basic:%d:%d:%d:%d|", sigaction(SIGINT, &act, &old), old.sa_handler == SIG_DFL, sigaction(SIGINT, &old, &restore), restore.sa_handler == parity_handler);
  }
#else
  printf("sigaction-basic:skip|");
#endif

  return 0;
}
