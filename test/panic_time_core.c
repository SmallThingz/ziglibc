#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "expect.h"

#define PANIC_MARK(name) do { if (getenv("ZIGLIBC_TEST_MARKERS") != NULL) { fputs(name, stderr); fputc('\n', stderr); fflush(stderr); } } while (0)

int main(void)
{
  {
    PANIC_MARK("panic_time_core:block:clock");
    clock_t c1 = clock();
    clock_t c2 = clock();
    expect(c1 >= 0);
    expect(c2 >= c1);
  }

  PANIC_MARK("panic_time_core:block:difftime");
  expect(7.0 == difftime((time_t)10, (time_t)3));

  {
    PANIC_MARK("panic_time_core:block:time-convert");
    time_t t0 = 0;
    struct tm *utc = gmtime(&t0);
    struct tm *local = localtime(&t0);
    expect(utc != NULL);
    expect(local != NULL);
    expect(70 == utc->tm_year);
    expect(0 == utc->tm_mon);
    expect(1 == utc->tm_mday);
    expect(70 == local->tm_year);
  }

  {
    PANIC_MARK("panic_time_core:block:mktime");
    struct tm tm = {0};
    tm.tm_year = 70;
    tm.tm_mon = 0;
    tm.tm_mday = 1;
    expect((time_t)0 == mktime(&tm));

    tm.tm_year = 70;
    tm.tm_mon = 0;
    tm.tm_mday = 2;
    tm.tm_hour = 0;
    tm.tm_min = 0;
    tm.tm_sec = 0;
    expect((time_t)86400 == mktime(&tm));
  }

  puts("Success!");
  return 0;
}
