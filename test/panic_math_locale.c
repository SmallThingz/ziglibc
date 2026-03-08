#include <locale.h>
#include <math.h>
#include <string.h>
#include "expect.h"
#include "test_markers.h"

int main(void)
{
  {
    TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "panic_math_locale:block:math");
    double v;
    v = acos(1.0); expect(v > -1e-12 && v < 1e-12);
    v = asin(0.0); expect(v > -1e-12 && v < 1e-12);
    v = atan(0.0); expect(v > -1e-12 && v < 1e-12);
    v = atan2(0.0, 1.0); expect(v > -1e-12 && v < 1e-12);
    v = tan(atan(1.0)); expect(v > 0.999999 && v < 1.000001);
  }

  {
    TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "panic_math_locale:block:locale");
    expect(NULL != setlocale(LC_ALL, "C"));
    expect(0 == strcmp("C", setlocale(LC_ALL, NULL)));
    expect(0 == strcmp("C", setlocale(LC_ALL, "")));
    expect(NULL == setlocale(LC_ALL, "en_US.UTF-8"));
  }

  puts("Success!");
  return 0;
}
