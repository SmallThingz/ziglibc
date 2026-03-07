#include <errno.h>
#include <math.h>
#include <signal.h>
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

static int approx_eq(double lhs, double rhs, double eps)
{
  double diff = lhs - rhs;
  if (diff < 0) diff = -diff;
  return diff <= eps;
}

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

  {
    void *p = malloc(0);
    free(p);
  }

  {
    unsigned char *p = calloc(16, 1);
    size_t i;
    expect(p != NULL);
    for (i = 0; i < 16; ++i) {
      expect(0 == p[i]);
    }
    free(p);
  }

  {
    char *p = malloc(8);
    expect(p != NULL);
    strcpy(p, "abc");
    p = realloc(p, 32);
    expect(p != NULL);
    expect(0 == strcmp(p, "abc"));
    expect(p == strcat(p, "def"));
    expect(0 == strcmp(p, "abcdef"));
    free(p);
  }

  {
    const char *path = getenv("PATH");
    const char *home = getenv("HOME");
    const char *pwd = getenv("PWD");
    expect(NULL == getenv(""));
    expect(NULL == getenv("A=B"));
    expect(NULL == getenv("__ZIGLIBC_MISSING_VAR__"));
#ifdef _WIN32
    expect(path != NULL);
#elif defined(__linux__) || defined(__APPLE__)
    expect(path != NULL || home != NULL || pwd != NULL);
#else
    (void)path;
    (void)home;
    (void)pwd;
#endif
  }

  {
    int i;
    srand(1234);
    for (i = 0; i < 1024; ++i) {
      int value = rand();
      expect(value >= 0);
      expect(value <= RAND_MAX);
    }
  }

  {
    ldiv_t qr = ldiv(-7, 3);
    div_t small_qr = div(-7, 3);
    wchar_t wide[8];
    char bytes[8];
    wchar_t ch = 0;
    expect(12.5 == atof("12.5"));
    expect(-42 == atol("-42"));
    expect(1234L == labs(-1234L));
    expect(-2 == small_qr.quot);
    expect(-1 == small_qr.rem);
    expect(-2 == qr.quot);
    expect(-1 == qr.rem);
    expect(0 == mblen(NULL, 4));
    expect(1 == mblen("a", 1));
    expect(1 == mbtowc(&ch, "z", 1));
    expect((wchar_t)'z' == ch);
    expect(1 == wctomb(bytes, L'Q'));
    expect('Q' == bytes[0]);
    expect(2 == mbstowcs(wide, "hi", 8));
    expect((wchar_t)'h' == wide[0]);
    expect((wchar_t)'i' == wide[1]);
    expect(2 == wcstombs(bytes, wide, sizeof(bytes)));
    expect(0 == strcmp("hi", bytes));
  }

  {
    int values[] = { 4, 1, 3, 2 };
    int key = 3;
    int *found;
    qsort(values, 4, sizeof(values[0]), int_compare);
    expect(values[0] == 1);
    expect(values[1] == 2);
    expect(values[2] == 3);
    expect(values[3] == 4);
    found = bsearch(&key, values, 4, sizeof(values[0]), int_compare);
    expect(found != NULL);
    expect(*found == 3);
  }

  {
    double ipart = 0.0;
    expect(1.0 == cos(0.0));
    expect(0.0 == sin(0.0));
    expect(1.0 == cosh(0.0));
    expect(0.0 == sinh(0.0));
    expect(0.0 == tanh(0.0));
    expect(approx_eq(log(exp(1.0)), 1.0, 1e-12));
    expect(approx_eq(log10(1000.0), 3.0, 1e-12));
    expect(approx_eq(log2(8.0), 3.0, 1e-12));
    expect(approx_eq(log2f(8.0f), 3.0, 1e-6));
    expect(approx_eq((double)log2l(8.0L), 3.0, 1e-12));
    expect(3.0 == sqrt(9.0));
    expect(3.0 == ceil(2.1));
    expect(2.0 == floor(2.9));
    expect(3.5 == fabs(-3.5));
    expect(approx_eq(fmod(7.5, 2.0), 1.5, 1e-12));
    expect(approx_eq(modf(2.75, &ipart), 0.75, 1e-12));
    expect(ipart == 2.0);
  }

  {
    int status = system(NULL);
    expect(status != 0);
    status = system(
#ifdef _WIN32
      "exit /b 7"
#else
      "exit 7"
#endif
    );
    expect(status != -1);
#ifndef _WIN32
    expect((status & 0x7f) == 0);
    expect(7 == ((status >> 8) & 0xff));
#endif
  }

#ifndef _WIN32
  {
    const char *home = getenv("HOME");
    if (home != NULL && home[0] != '\0') {
      int status = system("test -n \"$HOME\"");
      expect(status != -1);
      expect((status & 0x7f) == 0);
      expect(0 == ((status >> 8) & 0xff));
    }
  }
#endif

  puts("Success!");
  return 0;
}
