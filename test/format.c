#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>

#include "expect.h"

int main(void)
{
  char buffer[200];
  char tiny[5];
  char single[1];
  int rc;
  uint32_t u32 = 0xbeef;
  uint64_t u64 = UINT64_C(0xcafe);
  uintptr_t uptr = (uintptr_t)0xabc;
  expect (13 == snprintf(buffer, sizeof(buffer), "Hello %s\n", "World!"));
  expect(0 == strcmp(buffer, "Hello World!\n"));
  expect(13 == snprintf(buffer, 0, "Hello %s\n", "World!"));

  expect(18 == snprintf(buffer, sizeof(buffer), "Hello number %d\n", 1293));
  expect(0 == strcmp(buffer, "Hello number 1293\n"));
  expect(20 == snprintf(buffer, sizeof(buffer), "Hello number 0x%x\n", 0x1fa2));
  expect(0 == strcmp(buffer, "Hello number 0x1fa2\n"));
  expect(3 == snprintf(buffer, sizeof(buffer), "%u", 255u));
  expect(0 == strcmp(buffer, "255"));
  expect(13 == snprintf(buffer, sizeof(buffer), "%lld", 1234567890123LL));
  expect(0 == strcmp(buffer, "1234567890123"));
  expect(13 == snprintf(buffer, sizeof(buffer), "%llu", 1234567890123ULL));
  expect(0 == strcmp(buffer, "1234567890123"));
  expect(14 == snprintf(buffer, sizeof(buffer), "%ld:%lu", -123456L, 123456UL));
  expect(0 == strcmp(buffer, "-123456:123456"));
  expect(4 == snprintf(buffer, sizeof(buffer), "%i", -123));
  expect(0 == strcmp(buffer, "-123"));
  expect(1 == snprintf(buffer, sizeof(buffer), "%%"));
  expect(0 == strcmp(buffer, "%"));
  expect(7 == snprintf(buffer, sizeof(buffer), "[%5d]", 12));
  expect(0 == strcmp(buffer, "[   12]"));
  expect(7 == snprintf(buffer, sizeof(buffer), "[%-5d]", 12));
  expect(0 == strcmp(buffer, "[12   ]"));
  expect(7 == snprintf(buffer, sizeof(buffer), "[%05d]", 12));
  expect(0 == strcmp(buffer, "[00012]"));
  expect(7 == snprintf(buffer, sizeof(buffer), "[%+05d]", 12));
  expect(0 == strcmp(buffer, "[+0012]"));
  expect(7 == snprintf(buffer, sizeof(buffer), "[% 05d]", 12));
  expect(0 == strcmp(buffer, "[ 0012]"));
  expect(7 == snprintf(buffer, sizeof(buffer), "[%.5d]", 12));
  expect(0 == strcmp(buffer, "[00012]"));
  expect(10 == snprintf(buffer, sizeof(buffer), "[%8.5d]", 12));
  expect(0 == strcmp(buffer, "[   00012]"));
  expect(10 == snprintf(buffer, sizeof(buffer), "[%-8.5d]", 12));
  expect(0 == strcmp(buffer, "[00012   ]"));
  expect(2 == snprintf(buffer, sizeof(buffer), "[%.0d]", 0));
  expect(0 == strcmp(buffer, "[]"));
  expect(6 == snprintf(buffer, sizeof(buffer), "[%#x]", 0x2a));
  expect(0 == strcmp(buffer, "[0x2a]"));
  expect(6 == snprintf(buffer, sizeof(buffer), "[%#X]", 0x2a));
  expect(0 == strcmp(buffer, "[0X2A]"));
  expect(5 == snprintf(buffer, sizeof(buffer), "[%#o]", 9));
  expect(0 == strcmp(buffer, "[011]"));
  expect(1 == snprintf(buffer, sizeof(buffer), "%#.0o", 0));
  expect(0 == strcmp(buffer, "0"));
  expect(1 == snprintf(buffer, sizeof(buffer), "%#x", 0));
  expect(0 == strcmp(buffer, "0"));
  expect(10 == snprintf(buffer, sizeof(buffer), "[%08X]", 0x2a));
  expect(0 == strcmp(buffer, "[0000002A]"));
  expect(6 == snprintf(buffer, sizeof(buffer), "[%*d]", 4, 12));
  expect(0 == strcmp(buffer, "[  12]"));
  expect(6 == snprintf(buffer, sizeof(buffer), "[%*d]", -4, 12));
  expect(0 == strcmp(buffer, "[12  ]"));
  expect(5 == snprintf(buffer, sizeof(buffer), "[%.*s]", 3, "abcdef"));
  expect(0 == strcmp(buffer, "[abc]"));
  expect(10 == snprintf(buffer, sizeof(buffer), "[%8.3s]", "abcdef"));
  expect(0 == strcmp(buffer, "[     abc]"));
  expect(10 == snprintf(buffer, sizeof(buffer), "[%-8.3s]", "abcdef"));
  expect(0 == strcmp(buffer, "[abc     ]"));
  expect(4 == snprintf(buffer, sizeof(buffer), "%" PRIi64 " %" PRIu64, INT64_C(-7), UINT64_C(8)));
  expect(0 == strcmp(buffer, "-7 8"));
  expect(9 == snprintf(buffer, sizeof(buffer), "%" PRIX32 " %" PRIX64, u32, u64));
  expect(0 == strcmp(buffer, "BEEF CAFE"));
  expect(4 == snprintf(buffer, sizeof(buffer), "%" PRIuPTR, uptr));
  expect(0 == strcmp(buffer, "2748"));

  expect(4 == snprintf(buffer, sizeof(buffer), "%s", "abcd"));
  expect(0 == strcmp(buffer, "abcd"));
  expect(3 == snprintf(buffer, sizeof(buffer), "%.*s", 3, "abcd"));
  expect(0 == strcmp(buffer, "abc"));
  expect(7 == snprintf(tiny, sizeof(tiny), "hello %d", 7));
  expect(0 == strcmp(tiny, "hell"));
  expect(3 == snprintf(single, sizeof(single), "%d", 123));
  expect(single[0] == 0);
  expect(7 == snprintf(NULL, 0, "[%05d]", 12));

  errno = 0;
  rc = snprintf(buffer, sizeof(buffer), "%f", 1.0);
  expect(-1 == rc);
  expect(EINVAL == errno);
  expect(buffer[0] == 0);
  
  printf("Success!\n");
  return 0;
}
