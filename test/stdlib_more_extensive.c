#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "expect.h"

static int int_compare(const void *lhs, const void *rhs)
{
  const int a = *(const int *)lhs;
  const int b = *(const int *)rhs;
  return (a > b) - (a < b);
}

int main(void)
{
  char *end;

  expect(atoi("17") == 17);
  expect(atoi("  -9") == -9);
  expect(atol("123456") == 123456L);
  expect(abs(-11) == 11);
  expect(labs(-1234567L) == 1234567L);

  {
    char *p = malloc(16);
    expect(p != NULL);
    memset(p, 'a', 15);
    p[15] = 0;
    p = realloc(p, 64);
    expect(p != NULL);
    expect(p[0] == 'a' && p[14] == 'a');
    free(p);
  }

  {
    char *p = realloc(NULL, 8);
    expect(p != NULL);
    strcpy(p, "ok");
    expect(strcmp(p, "ok") == 0);
    free(p);
  }

  {
    void *p = calloc(4, 4);
    expect(p != NULL);
    expect(memcmp(p, "\0\0\0\0\0\0\0\0", 8) == 0);
    free(p);
  }

  expect(strtol("0x20", &end, 0) == 32L);
  expect(*end == 0);
  expect(strtoul("077", &end, 0) == 63UL);
  expect(*end == 0);
  expect(strtod("3.25rest", &end) > 3.24 && strtod("3.25rest", NULL) < 3.26);
  expect(strcmp(end, "rest") == 0);

  {
    int values[] = { 5, 1, 9, 1, 3, 7 };
    int key_hit = 7;
    int key_miss = 2;
    qsort(values, 6, sizeof(values[0]), int_compare);
    expect(values[0] == 1);
    expect(values[5] == 9);
    expect(*(int *)bsearch(&key_hit, values, 6, sizeof(values[0]), int_compare) == 7);
    expect(bsearch(&key_miss, values, 6, sizeof(values[0]), int_compare) == NULL);
  }

  {
    div_t d = div(7, 3);
    ldiv_t ld = ldiv(7L, 3L);
    expect(d.quot == 2 && d.rem == 1);
    expect(ld.quot == 2 && ld.rem == 1);
  }

  expect(getenv("__ZIGLIBC_SHOULD_NOT_EXIST__") == NULL);
  expect(mblen("a", 1) == 1);

  expect(tolower('A') == 'a');
  expect(toupper('a') == 'A');
  expect(isalpha('a') != 0);
  expect(isdigit('9') != 0);
  expect(isspace(' ') != 0);
  expect(isxdigit('f') != 0);
  expect(isprint('Z') != 0);
  expect(ispunct('!') != 0);

  expect(fabs(-2.5) == 2.5);
  expect(floor(2.9) == 2.0);
  expect(ceil(2.1) == 3.0);
  expect(sqrt(16.0) == 4.0);
  expect(log10(100.0) > 1.99 && log10(100.0) < 2.01);

  puts("Success!");
  return 0;
}
