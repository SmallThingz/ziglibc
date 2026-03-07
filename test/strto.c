#include <errno.h>
#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#include "expect.h"

static void test_l(const char *str, int base, int expected_errno, size_t parse_len, long expected)
{
  char *endptr;
  errno = 0;
  expect(expected == strtol(str, &endptr, base));
  expect(errno == expected_errno);
  expect(endptr == str + parse_len);
}
static void test_ul(const char *str, int base, int expected_errno, size_t parse_len, unsigned long expected)
{
  char *endptr;
  errno = 0;
  expect(expected == strtoul(str, &endptr, base));
  expect(errno == expected_errno);
  expect(endptr == str + parse_len);
}
static void test_d(const char *str, int expected_errno, size_t parse_len, double expected_min, double expected_max)
{
  char *endptr;
  errno = 0;
  {
    const double value = strtod(str, &endptr);
    expect(value >= expected_min);
    expect(value <= expected_max);
  }
  expect(errno == expected_errno);
  expect(endptr == str + parse_len);
}

int main(int argc, char *argv[])
{
#ifdef __APPLE__
  const int no_digit_errno = EINVAL;
#else
  const int no_digit_errno = 123;
#endif
  test_l("2147483647", 0, 0, 10, 2147483647L);
  test_ul("4294967295", 0, 0, 10, 4294967295UL);

  test_l("z", 36, 0, 1, 35);
  test_l("00010010001101000101011001111000", 2, 0, 32, 0x12345678);
  test_l("0F5F", 16, 0, 4, 0xf5f);

  //test_l("0xz", 16, EINVAL, 2, 0);

  test_l("0x1234", 16, 0, 6, 0x1234);

  test_l("123", 37, EINVAL, 0, 0);
  {
    const char *s = "abc";
    char *endptr;
    errno = 123;
    expect(0 == strtol(s, &endptr, 10));
    expect(errno == no_digit_errno);
    expect(endptr == s);
  }
  {
    const char *s = "  x";
    char *endptr;
    errno = 123;
    expect(0 == strtol(s, &endptr, 10));
    expect(errno == no_digit_errno);
    expect(endptr == s);
  }

  test_l("  15437", 8, 0, 7, 015437);
  test_l("  1", 0, 0, 3, 1);

  test_d("12.5xyz", 0, 4, 12.499, 12.501);
  test_d("  -1.25e2x", 0, 9, -125.001, -124.999);
  test_d("1e+", 0, 1, 0.999, 1.001);
  test_d("abc", 0, 0, -0.001, 0.001);

  puts("Success!");
  return 0;
}
