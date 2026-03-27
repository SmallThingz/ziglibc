#include <stdio.h>
#include <string.h>

static int fail(const char *name)
{
  fputs(name, stderr);
  fputc('\n', stderr);
  return 1;
}

int main(void)
{
  char b[32];
  const char mem_src[] = { 'a', 'b', '\0', 'c', 'd' };
  char *s;
  int i;

  b[16] = 'a';
  b[17] = 'b';
  b[18] = 'c';
  b[19] = 0;
  s = strcpy(b, b + 16);
  if (s != b) return fail("strcpy-ret-0");
  if (strcmp(s, "abc") != 0) return fail("strcpy-val-0");
  s = strcpy(b + 1, b + 16);
  if (s != b + 1) return fail("strcpy-ret-1");
  if (strcmp(s, "abc") != 0) return fail("strcpy-val-1");
  s = strcpy(b + 2, b + 18);
  if (s != b + 2) return fail("strcpy-ret-2");
  if (strcmp(s, "c") != 0) return fail("strcpy-val-2");

  s = memset(b, 'x', sizeof b);
  if (s != b) return fail("memset-ret");
  s = strncpy(b, "abc", sizeof b - 1);
  if (s != b) return fail("strncpy-ret");
  if (memcmp(b, "abc\0\0\0\0", 8) != 0) return fail("strncpy-zeropad");
  if (b[sizeof b - 1] != 'x') return fail("strncpy-overrun");

  b[3] = 'x';
  b[4] = 0;
  strncpy(b, "abc", 3);
  if (b[2] != 'c') return fail("strncpy-last");
  if (b[3] != 'x') return fail("strncpy-nullterm");

  if (!strncmp("abcd", "abce", 3)) {
  } else return fail("strncmp-n");
  if (!!strncmp("abc", "abd", 3) != 1) return fail("strncmp-byte");

  strcpy(b, "abc");
  s = strncat(b, "123456", 3);
  if (s != b) return fail("strncat-ret");
  if (b[6] != 0) return fail("strncat-null");
  if (strcmp(s, "abc123") != 0) return fail("strncat-val");

  strcpy(b, "aaababccdd0001122223");
  if (strchr(b, 'b') != b + 3) return fail("strchr");
  if (strrchr(b, 'b') != b + 5) return fail("strrchr");
  if (strchr(b, '\0') != b + strlen(b)) return fail("strchr-nul");
  if (strrchr(b, '\0') != b + strlen(b)) return fail("strrchr-nul");
  if (memchr(mem_src, '\0', sizeof mem_src) != mem_src + 2) return fail("memchr-nul");
  if (memchr(mem_src, 'z', sizeof mem_src) != NULL) return fail("memchr-miss");
  if (strspn(b, "abcd") != 10) return fail("strspn");
  if (strcspn(b, "0123") != 10) return fail("strcspn");
  if (strpbrk(b, "0123") != b + 10) return fail("strpbrk");

  strcpy(b, "foo");
  if (strcmp(strcat(b, ""), "foo") != 0) return fail("strcat-empty");
  if (strcmp(strcat(b, "bar"), "foobar") != 0) return fail("strcat-append");

  strcpy(b, "abc   123; xyz; foo");
  s = strtok(b, " ");
  if (s != b) return fail("strtok-0-ret");
  if (strcmp(s, "abc") != 0) return fail("strtok-0-val");
  s = strtok(NULL, ";");
  if (s != b + 4) return fail("strtok-1-ret");
  if (strcmp(s, "  123") != 0) return fail("strtok-1-val");
  s = strtok(NULL, " ;");
  if (s != b + 11) return fail("strtok-2-ret");
  if (strcmp(s, "xyz") != 0) return fail("strtok-2-val");
  s = strtok(NULL, " ;");
  if (s != b + 16) return fail("strtok-3-ret");
  if (strcmp(s, "foo") != 0) return fail("strtok-3-val");

  memset(b, 'x', sizeof b);
  if (strlcpy(b, "abc", sizeof b - 1) != 3) return fail("strlcpy-len-0");
  if (b[3] != 0) return fail("strlcpy-null-0");
  if (b[4] != 'x') return fail("strlcpy-extra-0");

  memset(b, 'x', sizeof b);
  if (strlcpy(b, "abc", 2) != 3) return fail("strlcpy-len-1");
  if (b[0] != 'a') return fail("strlcpy-copy-1");
  if (b[1] != 0) return fail("strlcpy-null-1");

  memset(b, 'x', sizeof b);
  if (strlcpy(b, "abc", 3) != 3) return fail("strlcpy-len-2");
  if (b[2] != 0) return fail("strlcpy-null-2");
  if (strlcpy(NULL, "abc", 0) != 3) return fail("strlcpy-null-size0");

  memcpy(b, "abc\0\0\0x\0", 8);
  if (strlcat(b, "123", sizeof b) != 6) return fail("strlcat-len-0");
  if (strcmp(b, "abc123") != 0) return fail("strlcat-val-0");

  memcpy(b, "abc\0\0\0x\0", 8);
  if (strlcat(b, "123", 6) != 6) return fail("strlcat-len-1");
  if (strcmp(b, "abc12") != 0) return fail("strlcat-val-1");
  if (b[6] != 'x') return fail("strlcat-overrun");

  memcpy(b, "abc\0\0\0x\0", 8);
  if (strlcat(b, "123", 4) != 6) return fail("strlcat-len-2");
  if (strcmp(b, "abc") != 0) return fail("strlcat-val-2");

  memcpy(b, "abc\0\0\0x\0", 8);
  if (strlcat(b, "123", 3) != 6) return fail("strlcat-len-3");
  if (strcmp(b, "abc") != 0) return fail("strlcat-val-3");

  puts("Success!");
  return 0;
}
