// Thin C vararg shims that forward to Zig v* implementations.
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>

#if defined(__GNUC__) || defined(__clang__)
#define ZIGLIBC_INTERNAL __attribute__((visibility("hidden")))
#else
#define ZIGLIBC_INTERNAL
#endif

ZIGLIBC_INTERNAL int _zvfprintf(FILE *stream, const char *format, va_list *args);
ZIGLIBC_INTERNAL int _zvsnprintf(char *s, size_t n, const char *format, va_list *args);
ZIGLIBC_INTERNAL int _zvsprintf(char *s, const char *format, va_list *args);

int fprintf(FILE *stream, const char *format, ...)
{
  va_list args;
  va_start(args, format);
  int result = _zvfprintf(stream, format, &args);
  va_end(args);
  return result;
}

int printf(const char *format, ...)
{
  va_list args;
  va_start(args, format);
  int result = _zvfprintf(stdout, format, &args);
  va_end(args);
  return result;
}

int vfprintf(FILE *stream, const char *format, va_list args)
{
  va_list copy;
  __builtin_va_copy(copy, args);
  int result = _zvfprintf(stream, format, &copy);
  va_end(copy);
  return result;
}

int vprintf(const char *format, va_list args)
{
  va_list copy;
  __builtin_va_copy(copy, args);
  int result = _zvfprintf(stdout, format, &copy);
  va_end(copy);
  return result;
}

int snprintf(char * restrict s, size_t n, const char * restrict format, ...)
{
  va_list args;
  va_start(args, format);
  int result = _zvsnprintf(s, n, format, &args);
  va_end(args);
  return result;
}

int sprintf(char * restrict s, const char * restrict format, ...)
{
  va_list args;
  va_start(args, format);
  int result = _zvsprintf(s, format, &args);
  va_end(args);
  return result;
}

int vsnprintf(char * restrict s, size_t n, const char * restrict format, va_list args)
{
  va_list copy;
  __builtin_va_copy(copy, args);
  int result = _zvsnprintf(s, n, format, &copy);
  va_end(copy);
  return result;
}

int vsprintf(char * restrict s, const char * restrict format, va_list args)
{
  va_list copy;
  __builtin_va_copy(copy, args);
  int result = _zvsprintf(s, format, &copy);
  va_end(copy);
  return result;
}
