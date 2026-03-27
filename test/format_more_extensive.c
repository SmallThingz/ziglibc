#include <stdarg.h>
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "expect.h"

static int via_vsnprintf(char *buf, size_t len, const char *fmt, ...)
{
  va_list ap;
  int rc;
  va_start(ap, fmt);
  rc = vsnprintf(buf, len, fmt, ap);
  va_end(ap);
  return rc;
}

static int via_vsprintf(char *buf, const char *fmt, ...)
{
  va_list ap;
  int rc;
  va_start(ap, fmt);
  rc = vsprintf(buf, fmt, ap);
  va_end(ap);
  return rc;
}

static int via_vfprintf(FILE *f, const char *fmt, ...)
{
  va_list ap;
  int rc;
  va_start(ap, fmt);
  rc = vfprintf(f, fmt, ap);
  va_end(ap);
  return rc;
}

int main(void)
{
  char buf[256];
  char tiny[3];
  uintptr_t uptr = (uintptr_t)0xabc;

  expect(via_vsnprintf(buf, sizeof(buf), "%08x", 0x123) == 8);
  expect(strcmp(buf, "00000123") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%#08x", 0x23) == 8);
  expect(strcmp(buf, "0x000023") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%#08X", 0x23) == 8);
  expect(strcmp(buf, "0X000023") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%#6o", 9) == 6);
  expect(strcmp(buf, "   011") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%-6s", "xy") == 6);
  expect(strcmp(buf, "xy    ") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%6c", 'A') == 6);
  expect(strcmp(buf, "     A") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%-6c", 'A') == 6);
  expect(strcmp(buf, "A     ") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%.*d", 4, 23) == 4);
  expect(strcmp(buf, "0023") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%*.*d", 7, 4, 23) == 7);
  expect(strcmp(buf, "   0023") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%p", (void *)uptr) == 5);
  expect(strcmp(buf, "0xabc") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%10p", (void *)uptr) == 10);
  expect(strcmp(buf, "     0xabc") == 0);
  expect(via_vsnprintf(buf, sizeof(buf), "%" PRIuPTR, uptr) == 4);
  expect(strcmp(buf, "2748") == 0);
  expect(via_vsprintf(buf, "%s:%d:%X", "zig", -7, 0xbeef) == 11);
  expect(strcmp(buf, "zig:-7:BEEF") == 0);

  expect(via_vsnprintf(tiny, sizeof(tiny), "%d", 12345) == 5);
  expect(strcmp(tiny, "12") == 0);

  {
    FILE *f = fopen("format-more.txt", "w+");
    expect(f != NULL);
    expect(via_vfprintf(f, "%#x:%+d:%s", 0x2a, 7, "ok") == 10);
    expect(fseek(f, 0, SEEK_SET) == 0);
    expect(fread(buf, 1, 10, f) == 10);
    buf[10] = 0;
    expect(strcmp(buf, "0x2a:+7:ok") == 0);
    expect(fclose(f) == 0);
    expect(remove("format-more.txt") == 0);
  }

  errno = 0;
  expect(via_vsnprintf(buf, sizeof(buf), "%#f", 1.0) == -1);
  expect(errno == EINVAL);
  expect(buf[0] == 0);

  puts("Success!");
  return 0;
}
