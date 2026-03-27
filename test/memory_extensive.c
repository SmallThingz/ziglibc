#include <stdio.h>
#include <string.h>

#include "expect.h"

static int fail(const char *msg)
{
  fputs(msg, stderr);
  fputc('\n', stderr);
  return 1;
}

int main(void)
{
  unsigned char a[32];
  unsigned char b[32];
  unsigned char overlap[32];
  unsigned char zeros[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };

  expect(memset(a, 0xaa, sizeof(a)) == a);
  for (size_t i = 0; i < sizeof(a); ++i) expect(a[i] == 0xaa);

  expect(memcpy(b, a, sizeof(a)) == b);
  expect(memcmp(a, b, sizeof(a)) == 0);

  b[10] = 0xab;
  expect(memcmp(a, b, sizeof(a)) < 0);
  b[10] = 0xa9;
  expect(memcmp(a, b, sizeof(a)) > 0);
  b[10] = 0xaa;

  for (size_t i = 0; i < sizeof(overlap); ++i) overlap[i] = (unsigned char)i;
  expect(memmove(overlap + 4, overlap, 12) == overlap + 4);
  for (size_t i = 0; i < 12; ++i) expect(overlap[4 + i] == (unsigned char)i);

  for (size_t i = 0; i < sizeof(overlap); ++i) overlap[i] = (unsigned char)i;
  expect(memmove(overlap, overlap + 4, 12) == overlap);
  for (size_t i = 0; i < 12; ++i) expect(overlap[i] == (unsigned char)(i + 4));

  expect(memmove(a, a, sizeof(a)) == a);
  expect(memcpy(a, a, sizeof(a)) == a);

  expect(memchr(a, 0xaa, sizeof(a)) == a);
  expect(memchr(a, 0xbb, sizeof(a)) == NULL);
  expect(memchr(zeros, 0, sizeof(zeros)) == zeros);

  {
    const char src[] = "0123456789";
    char dst[32];
    memset(dst, 0, sizeof(dst));
    memcpy(dst, src, 0);
    expect(dst[0] == 0);
    memcpy(dst, src, 10);
    expect(memcmp(dst, src, 10) == 0);
  }

  {
    char text[32] = "abcdef";
    memmove(text + 1, text, 7);
    if (strcmp(text, "aabcdef") != 0) return fail("memmove-overlap-right");
  }

  {
    char text[32] = "abcdef";
    memmove(text, text + 1, 6);
    if (strcmp(text, "bcdef") != 0) return fail("memmove-overlap-left");
  }

  puts("Success!");
  return 0;
}
