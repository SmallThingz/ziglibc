#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "expect.h"

static int write_with_vfprintf(FILE *stream, const char *fmt, ...)
{
  va_list ap;
  int ret;
  va_start(ap, fmt);
  ret = vfprintf(stream, fmt, ap);
  va_end(ap);
  return ret;
}

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

  const char *path = "stdio-extensive.txt";
  FILE *f = fopen64(path, "w");
  expect(f != NULL);
  expect(5 == fprintf(f, "hello"));
  expect(4 == write_with_vfprintf(f, " %s", "zig"));
  expect(3 == fwrite("abc", 1, 3, f));
  expect(0 == fwrite("drop", 0, 4, f));
  expect(0 == fwrite("drop", 4, 0, f));
#ifndef _WIN32
  expect('!' == fputc('!', f));
#endif
  expect(0 == fclose(f));

  f = fopen(path, "r");
  expect(f != NULL);
  {
    char buf[64];
    const size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    buf[n] = 0;
#ifdef _WIN32
    expect(0 == strcmp("hello zigabc", buf));
#else
    expect(0 == strcmp("hello zigabc!", buf));
#endif
  }
  expect(0 == fclose(f));

  puts("Success!");
  return 0;
}
