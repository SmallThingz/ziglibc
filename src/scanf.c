// Thin C vararg shims that forward to Zig v* implementations.
#include <stdarg.h>
#include <stdio.h>

int sscanf(const char *s, const char *fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  int result = vsscanf(s, fmt, args);
  va_end(args);
  return result;
}
