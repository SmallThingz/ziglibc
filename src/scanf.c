// Thin C vararg shims that forward to Zig v* implementations.
#include <stdarg.h>
#include <stdio.h>

#if defined(__GNUC__) || defined(__clang__)
#define ZIGLIBC_INTERNAL __attribute__((visibility("hidden")))
#else
#define ZIGLIBC_INTERNAL
#endif

ZIGLIBC_INTERNAL int _zvsscanf(const char *s, const char *fmt, va_list *args);

int sscanf(const char *s, const char *fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  int result = _zvsscanf(s, fmt, &args);
  va_end(args);
  return result;
}

int vsscanf(const char *s, const char *fmt, va_list args)
{
  va_list copy;
  __builtin_va_copy(copy, args);
  int result = _zvsscanf(s, fmt, &copy);
  va_end(copy);
  return result;
}
