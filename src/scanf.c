// Thin C vararg shims that forward to Zig v* implementations.
#include <stdarg.h>
#include <stdio.h>

#ifdef _WIN32
static int is_space(unsigned char ch)
{
  return ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' || ch == '\v' || ch == '\f';
}

static int hex_value(unsigned char ch)
{
  if (ch >= '0' && ch <= '9') return (int)(ch - '0');
  if (ch >= 'a' && ch <= 'f') return (int)(ch - 'a') + 10;
  if (ch >= 'A' && ch <= 'F') return (int)(ch - 'A') + 10;
  return -1;
}

int vsscanf(const char * restrict s, const char * restrict fmt, va_list args)
{
  const unsigned char *sp = (const unsigned char *)s;
  const unsigned char *fp = (const unsigned char *)fmt;
  int scan_count = 0;

  while (*fp != 0) {
    if (*fp == '%') {
      fp++;
      if (*fp == 0) return -1;

      int width = -1;
      if (*fp >= '0' && *fp <= '9') {
        width = 0;
        while (*fp >= '0' && *fp <= '9') {
          width = (width * 10) + (int)(*fp - '0');
          fp++;
        }
      }

      int is_long = 0;
      if (*fp == 'l') {
        is_long = 1;
        fp++;
      }
      if (*fp == 0) return -1;

      if (*fp == 's') {
        char *out = va_arg(args, char *);
        int total = 0;

        while (is_space(*sp)) sp++;
        while (*sp != 0 && !is_space(*sp)) {
          if (width != -1 && total >= width) break;
          out[total++] = (char)*sp;
          sp++;
        }
        if (total == 0) {
          return (scan_count == 0) ? -1 : scan_count;
        }
        out[total] = 0;
        scan_count++;
        fp++;
        continue;
      }

      if (*fp == 'x' || *fp == 'X') {
        if (width != -1) {
          return -1;
        }
        while (is_space(*sp)) sp++;

        int read_any = 0;
        if (is_long) {
          long value = 0;
          while (1) {
            const int v = hex_value(*sp);
            if (v == -1) break;
            read_any = 1;
            value *= 16;
            value += (long)v;
            sp++;
          }
          if (!read_any) {
            return (scan_count == 0) ? -1 : scan_count;
          }
          *va_arg(args, long *) = value;
        } else {
          int value = 0;
          while (1) {
            const int v = hex_value(*sp);
            if (v == -1) break;
            read_any = 1;
            value *= 16;
            value += v;
            sp++;
          }
          if (!read_any) {
            return (scan_count == 0) ? -1 : scan_count;
          }
          *va_arg(args, int *) = value;
        }
        scan_count++;
        fp++;
        continue;
      }

      return -1;
    }

    if (is_space(*fp)) {
      while (is_space(*fp)) fp++;
      while (is_space(*sp)) sp++;
      continue;
    }

    if (*sp != *fp) {
      return (scan_count == 0) ? -1 : scan_count;
    }
    sp++;
    fp++;
  }

  return scan_count;
}
#else
int vsscanf(const char * restrict s, const char * restrict fmt, va_list args);
#endif

int sscanf(const char *s, const char *fmt, ...)
{
  va_list args;
  va_start(args, fmt);
  int result = vsscanf(s, fmt, args);
  va_end(args);
  return result;
}
