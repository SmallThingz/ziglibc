// Thin C vararg shims that forward to Zig v* implementations.
#include <stdarg.h>
#include <stdio.h>

extern int _zvsscanf(const char *s, const char *fmt, va_list args);

int vsscanf(const char *s, const char *fmt, va_list args)
{
  return _zvsscanf(s, fmt, args);
}

int sscanf(const char *s, const char *fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  int result = vsscanf(s, fmt, args);
  va_end(args);
  return result;
}
