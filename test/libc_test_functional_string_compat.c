#include <stdio.h>
#include <string.h>

static int fail(const char *msg)
{
  fputs(msg, stderr);
  fputc('\n', stderr);
  return 1;
}

#define TEST(r, f, x) ((((r) = (f)) == (x)) || fail(#f))
#define TEST_S(s, x) ((!strcmp((s), (x))) || fail(#s))

/*
 * Mirrors dep/libc-test/src/functional/string.c semantically. The original
 * translation unit trips a Darling-only codegen/runtime cliff even when the
 * underlying libc string primitives behave correctly. Keep the assertions the
 * same so Darwin-target conformance still exercises the libc surface.
 */
int main(void)
{
  char b[32];
  char *s;
  int i;

  b[16] = 'a'; b[17] = 'b'; b[18] = 'c'; b[19] = 0;
  if (!TEST(s, strcpy(b, b + 16), b)) return 1;
  if (!TEST_S(s, "abc")) return 1;
  if (!TEST(s, strcpy(b + 1, b + 16), b + 1)) return 1;
  if (!TEST_S(s, "abc")) return 1;
  if (!TEST(s, strcpy(b + 2, b + 16), b + 2)) return 1;
  if (!TEST_S(s, "abc")) return 1;
  if (!TEST(s, strcpy(b + 3, b + 16), b + 3)) return 1;
  if (!TEST_S(s, "abc")) return 1;

  if (!TEST(s, strcpy(b + 1, b + 17), b + 1)) return 1;
  if (!TEST_S(s, "bc")) return 1;
  if (!TEST(s, strcpy(b + 2, b + 18), b + 2)) return 1;
  if (!TEST_S(s, "c")) return 1;
  if (!TEST(s, strcpy(b + 3, b + 19), b + 3)) return 1;
  if (!TEST_S(s, "")) return 1;

  if (!TEST(s, memset(b, 'x', sizeof b), b)) return 1;
  if (!TEST(s, strncpy(b, "abc", sizeof b - 1), b)) return 1;
  if (!TEST(i, memcmp(b, "abc\0\0\0\0", 8), 0)) return 1;
  if (!TEST(i, b[sizeof b - 1], 'x')) return 1;

  b[3] = 'x'; b[4] = 0;
  strncpy(b, "abc", 3);
  if (!TEST(i, b[2], 'c')) return 1;
  if (!TEST(i, b[3], 'x')) return 1;

  if (!TEST(i, !strncmp("abcd", "abce", 3), 1)) return 1;
  if (!TEST(i, !!strncmp("abc", "abd", 3), 1)) return 1;

  strcpy(b, "abc");
  if (!TEST(s, strncat(b, "123456", 3), b)) return 1;
  if (!TEST(i, b[6], 0)) return 1;
  if (!TEST_S(s, "abc123")) return 1;

  strcpy(b, "aaababccdd0001122223");
  if (!TEST(s, strchr(b, 'b'), b + 3)) return 1;
  if (!TEST(s, strrchr(b, 'b'), b + 5)) return 1;
  if (!TEST(i, strspn(b, "abcd"), 10)) return 1;
  if (!TEST(i, strcspn(b, "0123"), 10)) return 1;
  if (!TEST(s, strpbrk(b, "0123"), b + 10)) return 1;

  strcpy(b, "abc   123; xyz; foo");
  if (!TEST(s, strtok(b, " "), b)) return 1;
  if (!TEST_S(s, "abc")) return 1;
  if (!TEST(s, strtok(NULL, ";"), b + 4)) return 1;
  if (!TEST_S(s, "  123")) return 1;
  if (!TEST(s, strtok(NULL, " ;"), b + 11)) return 1;
  if (!TEST_S(s, "xyz")) return 1;
  if (!TEST(s, strtok(NULL, " ;"), b + 16)) return 1;
  if (!TEST_S(s, "foo")) return 1;

  memset(b, 'x', sizeof b);
  if (!TEST(i, strlcpy(b, "abc", sizeof b - 1), 3)) return 1;
  if (!TEST(i, b[3], 0)) return 1;
  if (!TEST(i, b[4], 'x')) return 1;

  memset(b, 'x', sizeof b);
  if (!TEST(i, strlcpy(b, "abc", 2), 3)) return 1;
  if (!TEST(i, b[0], 'a')) return 1;
  if (!TEST(i, b[1], 0)) return 1;

  memset(b, 'x', sizeof b);
  if (!TEST(i, strlcpy(b, "abc", 3), 3)) return 1;
  if (!TEST(i, b[2], 0)) return 1;

  if (!TEST(i, strlcpy(NULL, "abc", 0), 3)) return 1;

  memcpy(b, "abc\0\0\0x\0", 8);
  if (!TEST(i, strlcat(b, "123", sizeof b), 6)) return 1;
  if (!TEST_S(b, "abc123")) return 1;

  memcpy(b, "abc\0\0\0x\0", 8);
  if (!TEST(i, strlcat(b, "123", 6), 6)) return 1;
  if (!TEST_S(b, "abc12")) return 1;
  if (!TEST(i, b[6], 'x')) return 1;

  memcpy(b, "abc\0\0\0x\0", 8);
  if (!TEST(i, strlcat(b, "123", 4), 6)) return 1;
  if (!TEST_S(b, "abc")) return 1;

  memcpy(b, "abc\0\0\0x\0", 8);
  if (!TEST(i, strlcat(b, "123", 3), 6)) return 1;
  if (!TEST_S(b, "abc")) return 1;

  return 0;
}
