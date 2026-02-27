// Thin C vararg shims that forward to Zig v* implementations.
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>

extern int _zvfprintf(FILE *stream, const char *format, va_list args);
extern int _zvprintf(const char *format, va_list args);
extern int _zvsnprintf(char *s, size_t n, const char *format, va_list args);
extern int _zvsprintf(char *s, const char *format, va_list args);

int vfprintf(FILE *stream, const char *format, va_list args)
{
  return _zvfprintf(stream, format, args);
}

int vprintf(const char *format, va_list args)
{
  return _zvprintf(format, args);
}

int vsnprintf(char * restrict s, size_t n, const char * restrict format, va_list args)
{
  return _zvsnprintf(s, n, format, args);
}

int vsprintf(char * restrict s, const char * restrict format, va_list args)
{
  return _zvsprintf(s, format, args);
}

int fprintf(FILE *stream, const char *format, ...)
{
  va_list args;
  va_start(args, format);
  int result = vfprintf(stream, format, args);
  va_end(args);
  return result;
}

int printf(const char *format, ...)
{
  va_list args;
  va_start(args, format);
  int result = vfprintf(stdout, format, args);
  va_end(args);
  return result;
}

int snprintf(char * restrict s, size_t n, const char * restrict format, ...)
{
  va_list args;
  va_start(args, format);
  int result = vsnprintf(s, n, format, args);
  va_end(args);
  return result;
}

int sprintf(char * restrict s, const char * restrict format, ...)
{
  va_list args;
  va_start(args, format);
  int result = vsprintf(s, format, args);
  va_end(args);
  return result;
}
