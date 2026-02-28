#include <errno.h>
#include <locale.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "expect.h"

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

  {
    clock_t c1 = clock();
    clock_t c2 = clock();
    expect(c1 >= 0);
    expect(c2 >= c1);
  }

  expect(7.0 == difftime((time_t)10, (time_t)3));

  {
    double v;
    v = acos(1.0);
    expect(v > -1e-12 && v < 1e-12);
    v = asin(0.0);
    expect(v > -1e-12 && v < 1e-12);
    v = atan(0.0);
    expect(v > -1e-12 && v < 1e-12);
    v = atan2(0.0, 1.0);
    expect(v > -1e-12 && v < 1e-12);
    v = tan(atan(1.0));
    expect(v > 0.999999 && v < 1.000001);
  }

  expect(NULL != setlocale(LC_ALL, "C"));
  expect(0 == strcmp("C", setlocale(LC_ALL, "")));
  expect(NULL == setlocale(LC_ALL, "en_US.UTF-8"));

  {
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

  {
    const char *name = "panic-repl.tmp";
    const char *renamed = "panic-repl-renamed.tmp";
    FILE *f = fopen(name, "w");
    expect(f != NULL);

    expect(0 == setvbuf(f, NULL, _IONBF, 0));
    errno = 0;
    expect(-1 == setvbuf(f, NULL, 12345, 0));
    expect(EINVAL == errno);

    expect(1 == fputs("abc", f));
    expect(3 == ftell(f));
    expect(0 == fseek(f, 0, SEEK_SET));
    expect(0 == fclose(f));

    expect(0 == rename(name, renamed));
    expect(-1 == remove(name));
    expect(0 == remove(renamed));
    expect(-1 == remove(renamed));
  }

#ifndef _WIN32
  {
    FILE *files[128];
    size_t count = 0;
    while (count < (sizeof(files) / sizeof(files[0]))) {
      FILE *f = fopen("/dev/null", "r");
      if (f == NULL) {
        break;
      }
      files[count++] = f;
    }
    expect(count > 0);
    errno = 0;
    expect(NULL == fopen("/dev/null", "r"));
    expect(ENOMEM == errno);
    while (count > 0) {
      --count;
      expect(0 == fclose(files[count]));
    }
  }
#endif

  errno = ENOENT;
  perror("panic_replacements");

  puts("Success!");
  return 0;
}
