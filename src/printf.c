// Thin C vararg shims that forward to Zig v* implementations.
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#include <errno.h>

enum FormatLength {
  FORMAT_NONE,
  FORMAT_LONG,
  FORMAT_LONG_LONG,
};

enum WriterKind {
  WRITER_STREAM,
  WRITER_BOUNDED,
  WRITER_UNBOUNDED,
};

struct FormatWriter {
  enum WriterKind kind;
  union {
    FILE *stream;
    struct {
      char *buf;
      size_t len;
      int overflow;
    } bounded;
    struct {
      char *buf;
    } unbounded;
  } as;
};

static size_t writer_write(struct FormatWriter *writer, const char *bytes, size_t len)
{
  if (len == 0) {
    return 0;
  }
  if (writer->kind == WRITER_STREAM) {
    return fwrite(bytes, 1, len, writer->as.stream);
  }
  if (writer->kind == WRITER_BOUNDED) {
    if (!writer->as.bounded.overflow) {
      if (len > writer->as.bounded.len) {
        writer->as.bounded.overflow = 1;
      } else {
        memcpy(writer->as.bounded.buf, bytes, len);
        writer->as.bounded.buf += len;
        writer->as.bounded.len -= len;
      }
    }
    return len;
  }
  memcpy(writer->as.unbounded.buf, bytes, len);
  writer->as.unbounded.buf += len;
  return len;
}

static int is_format_flag(char ch)
{
  return ch == '-' || ch == '+' || ch == ' ' || ch == '#' || ch == '0';
}

static size_t string_print_len(const char *s, size_t precision)
{
  size_t len = 0;
  while (s[len] != 0 && len < precision) {
    len++;
  }
  return len;
}

static size_t format_unsigned(char *buf, unsigned long long value, unsigned base)
{
  static const char digits[] = "0123456789abcdef";
  char tmp[64];
  size_t i = 0;
  if (value == 0) {
    buf[0] = '0';
    return 1;
  }
  while (value != 0) {
    tmp[i++] = digits[value % base];
    value /= base;
  }
  for (size_t j = 0; j < i; j++) {
    buf[j] = tmp[i - 1 - j];
  }
  return i;
}

static size_t format_signed(char *buf, long long value)
{
  if (value < 0) {
    const unsigned long long mag = 0ull - (unsigned long long)value;
    buf[0] = '-';
    return 1 + format_unsigned(buf + 1, mag, 10);
  }
  return format_unsigned(buf, (unsigned long long)value, 10);
}

static int vformat(size_t *out_written, struct FormatWriter *writer, const char *fmt, va_list args)
{
  *out_written = 0;
  const char *p = fmt;

  while (1) {
    const char *percent = p;
    while (*percent != 0 && *percent != '%') {
      percent++;
    }
    if (percent > p) {
      const size_t len = (size_t)(percent - p);
      const size_t written = writer_write(writer, p, len);
      *out_written += written;
      if (written != len) {
        return 0;
      }
    }
    if (*percent == 0) {
      return 1;
    }

    p = percent + 1;
    if (*p == 0) {
      return 0;
    }

    if (is_format_flag(*p)) {
      return 0;
    }
    if (*p == '*') {
      return 0;
    } else if (*p >= '0' && *p <= '9') {
      return 0;
    }

    int precision = -1;
    if (*p == '.') {
      p++;
      if (*p == 0) {
        return 0;
      }
      if (*p == '*') {
        precision = va_arg(args, int);
        p++;
      } else {
        return 0;
      }
      if (*p == 0) {
        return 0;
      }
    }

    enum FormatLength spec_length = FORMAT_NONE;
    if (*p == 'l') {
      if (*(p + 1) == 'l') {
        spec_length = FORMAT_LONG_LONG;
        p += 2;
      } else {
        spec_length = FORMAT_LONG;
        p += 1;
      }
      if (*p == 0) {
        return 0;
      }
    }

    switch (*p) {
      case 's': {
        if (spec_length != FORMAT_NONE) {
          return 0;
        }
        const char *s = va_arg(args, const char *);
        if (s == NULL) {
          s = "(null)";
        }
        size_t len;
        if (precision < 0) {
          len = strlen(s);
        } else {
          len = string_print_len(s, (size_t)precision);
        }
        const size_t written = writer_write(writer, s, len);
        *out_written += written;
        if (written != len) {
          return 0;
        }
        break;
      }
      case 'c': {
        if (spec_length != FORMAT_NONE || precision != -1) {
          return 0;
        }
        const int value = va_arg(args, int);
        const char ch = (char)(value & 0xff);
        const size_t written = writer_write(writer, &ch, 1);
        *out_written += written;
        if (written != 1) {
          return 0;
        }
        break;
      }
      case 'd': {
        if (precision != -1) {
          return 0;
        }
        char buf[128];
        size_t len = 0;
        switch (spec_length) {
          case FORMAT_NONE:
            len = format_signed(buf, (long long)va_arg(args, int));
            break;
          case FORMAT_LONG:
            len = format_signed(buf, (long long)va_arg(args, long));
            break;
          case FORMAT_LONG_LONG:
            len = format_signed(buf, va_arg(args, long long));
            break;
        }
        const size_t written = writer_write(writer, buf, len);
        *out_written += written;
        if (written != len) {
          return 0;
        }
        break;
      }
      case 'u':
      case 'x': {
        if (precision != -1) {
          return 0;
        }
        const unsigned base = (*p == 'u') ? 10u : 16u;
        char buf[128];
        size_t len = 0;
        switch (spec_length) {
          case FORMAT_NONE:
            len = format_unsigned(buf, (unsigned long long)va_arg(args, unsigned int), base);
            break;
          case FORMAT_LONG:
            len = format_unsigned(buf, (unsigned long long)va_arg(args, unsigned long), base);
            break;
          case FORMAT_LONG_LONG:
            len = format_unsigned(buf, va_arg(args, unsigned long long), base);
            break;
        }
        const size_t written = writer_write(writer, buf, len);
        *out_written += written;
        if (written != len) {
          return 0;
        }
        break;
      }
      default:
        return 0;
    }

    p++;
  }
}

int vfprintf(FILE *stream, const char *format, va_list arg)
{
  struct FormatWriter writer;
  writer.kind = WRITER_STREAM;
  writer.as.stream = stream;

  size_t written = 0;
  if (vformat(&written, &writer, format, arg)) {
    return (int)written;
  }
  stream->errno = errno;
  return -1;
}

int vprintf(const char *format, va_list arg)
{
  return vfprintf(stdout, format, arg);
}

int vsnprintf(char * restrict s, size_t n, const char * restrict format, va_list arg)
{
  struct FormatWriter writer;
  writer.kind = WRITER_BOUNDED;
  writer.as.bounded.buf = s;
  writer.as.bounded.len = n;
  writer.as.bounded.overflow = 0;

  size_t written = 0;
  if (!vformat(&written, &writer, format, arg)) {
    return -1;
  }
  if (written < n) {
    s[written] = 0;
  }
  return (int)written;
}

int vsprintf(char * restrict s, const char * restrict format, va_list arg)
{
  struct FormatWriter writer;
  writer.kind = WRITER_UNBOUNDED;
  writer.as.unbounded.buf = s;

  size_t written = 0;
  if (!vformat(&written, &writer, format, arg)) {
    return -1;
  }
  s[written] = 0;
  return (int)written;
}
#endif

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
