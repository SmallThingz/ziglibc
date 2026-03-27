#include <stdio.h>
#include <string.h>
#include <strings.h>

#include "expect.h"

static int fail(const char *msg)
{
  fputs(msg, stderr);
  fputc('\n', stderr);
  return 1;
}

int main(void)
{
  char buf[64];
  char copy[64];
  const char *hay = "abcabcabcd";

  expect(strlen("") == 0);
  expect(strlen("z") == 1);
  expect(strlen("hello world") == 11);

  expect(strcmp("", "") == 0);
  expect(strcmp("abc", "abc") == 0);
  expect(strcmp("abc", "abd") < 0);
  expect(strcmp("abd", "abc") > 0);
  expect(strcmp("abc", "abc\0junk") == 0);

  expect(strncmp("abcdef", "abcxyz", 3) == 0);
  expect(strncmp("abcdef", "abcxyz", 4) < 0);
  expect(strncmp("abc", "abc", 99) == 0);

  expect(strcasecmp("AbC", "aBc") == 0);
  expect(strcasecmp("abc", "abd") < 0);
  expect(strncasecmp("AbCd", "aBcZ", 3) == 0);
  expect(strncasecmp("AbCd", "aBcZ", 4) < 0);

  expect(strchr(hay, 'd') == hay + 9);
  expect(strchr(hay, '\0') == hay + strlen(hay));
  expect(strchr(hay, 'z') == NULL);
  expect(strrchr(hay, 'a') == hay + 6);
  expect(strrchr(hay, '\0') == hay + strlen(hay));
  expect(strrchr(hay, 'z') == NULL);

  expect(strstr(hay, "abcabcd") == hay + 3);
  expect(strstr(hay, "") == hay);
  expect(strstr(hay, "zzz") == NULL);

  strcpy(buf, "foo");
  expect(strcmp(strcat(buf, "bar"), "foobar") == 0);
  expect(strcmp(strcat(buf, ""), "foobar") == 0);

  memset(copy, 'x', sizeof(copy));
  strncpy(copy, "abc", 6);
  expect(memcmp(copy, "abc\0\0\0", 6) == 0);
  copy[3] = 'x';
  strncpy(copy, "abcdef", 3);
  expect(copy[0] == 'a' && copy[1] == 'b' && copy[2] == 'c' && copy[3] == 'x');

  strcpy(buf, "foo");
  expect(strncat(buf, "barbaz", 3) == buf);
  expect(strcmp(buf, "foobar") == 0);
  expect(strncat(buf, "", 3) == buf);
  expect(strcmp(buf, "foobar") == 0);

  expect(strspn("abcde123", "abcde") == 5);
  expect(strspn("zzz", "abc") == 0);
  expect(strcspn("abcde123", "123") == 5);
  expect(strcspn("abcde", "xyz") == 5);
  expect(strpbrk("abcdef", "xzey") == (char *)"abcdef" + 4);
  expect(strpbrk("abcdef", "xyz") == NULL);

  strcpy(buf, "one,,two;three");
  expect(strcmp(strtok(buf, ",;"), "one") == 0);
  expect(strcmp(strtok(NULL, ",;"), "two") == 0);
  expect(strcmp(strtok(NULL, ",;"), "three") == 0);
  expect(strtok(NULL, ",;") == NULL);

  if (strlcpy(copy, "abcdef", 4) != 6) return fail("strlcpy-len");
  if (strcmp(copy, "abc") != 0) return fail("strlcpy-copy");
  strcpy(copy, "abc");
  if (strlcat(copy, "defgh", 6) != 8) return fail("strlcat-len");
  if (strcmp(copy, "abcde") != 0) return fail("strlcat-copy");

  expect(strcoll("abc", "abc") == 0);
  expect(strcoll("abc", "abd") < 0);
  expect(strxfrm(copy, "zig", sizeof(copy)) == 3);
  expect(strcmp(copy, "zig") == 0);

  puts("Success!");
  return 0;
}
