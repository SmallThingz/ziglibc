#include <errno.h>
#include <stdio.h>
#include <strings.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "expect.h"

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

  {
    const char *name = "posix-ext.tmp";
    FILE *f = fopen(name, "w");
    expect(f != NULL);
#ifndef _WIN32
    expect(fileno(f) >= 0);
#else
    (void)fileno(f);
#endif
    expect(0 == fclose(f));

    expect(0 == access(name, R_OK));
    expect(-1 == access("missing-posix-ext.tmp", R_OK));
    expect(0 == unlink(name));
    expect(-1 == unlink(name));
  }

  {
    struct timeval tv;
    expect(0 == gettimeofday(&tv, NULL));
    expect(tv.tv_usec >= 0);
    expect(tv.tv_usec < 1000000);
  }

  {
    struct timespec ts;
    expect(0 == clock_gettime(CLOCK_REALTIME, &ts));
    expect(ts.tv_nsec >= 0);
    expect(ts.tv_nsec < 1000000000L);
  }

  expect(0 == strcasecmp("HeLLo", "hEllO"));
  expect(strcasecmp("abc", "abd") < 0);
  expect(strcasecmp("abD", "abc") > 0);

  puts("Success!");
  return 0;
}
