#include <locale.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "expect.h"

#define PANIC_MARK(name) do { if (getenv("ZIGLIBC_TEST_MARKERS") != NULL) { fputs(name, stderr); fputc('\n', stderr); fflush(stderr); } } while (0)

int main(void)
{
  {
    PANIC_MARK("panic_math_locale:block:math");
    double v;
    v = acos(1.0); expect(v > -1e-12 && v < 1e-12);
    v = asin(0.0); expect(v > -1e-12 && v < 1e-12);
    v = atan(0.0); expect(v > -1e-12 && v < 1e-12);
    v = atan2(0.0, 1.0); expect(v > -1e-12 && v < 1e-12);
    v = tan(atan(1.0)); expect(v > 0.999999 && v < 1.000001);
  }

  {
    PANIC_MARK("panic_math_locale:block:locale");
    expect(NULL != setlocale(LC_ALL, "C"));
    expect(0 == strcmp("C", setlocale(LC_ALL, NULL)));
    expect(0 == strcmp("C", setlocale(LC_ALL, "")));
    expect(NULL == setlocale(LC_ALL, "en_US.UTF-8"));
  }

  puts("Success!");
  return 0;
}
