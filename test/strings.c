#include <assert.h>
#include <string.h>
#include <stdio.h>

#include "expect.h"

int main(int argc, char *argv[])
{
  expect(16 == strlen("this is a string"));
  expect(0 == strncmp("a", "b", 0));

  expect(0 == strcmp("abc", "abc"));
  expect(0 > strcmp("abc", "abd"));
  expect(0 < strcmp("abd", "abc"));
  expect(0 == strcoll("abc", "abc"));
  expect(0 > strcoll("abc", "abd"));
  expect(0 < strcoll("abd", "abc"));

  expect(0 == strncmp("abc", "abc", 3));
  expect(0 == strncmp("abc", "abc", 2));
  expect(0 == strncmp("abc", "abd", 2));
  expect(0 > strncmp("abc", "abd", 3));
  expect(0 == strncmp("abd", "abc", 2));
  expect(0 < strncmp("abd", "abc", 3));

  expect(NULL == strchr("hello", 'z'));
  {
    const char *s = "abcdef";
    expect(s + 4 == strchr(s, 'e'));
    expect(s + 6 == strchr(s, '\0'));
  }

  {
    const char *s = "abcdef";
    expect(s+1 == strstr(s, "bcde"));
    expect(NULL == strstr(s, "bcdeg"));
  }

  {
    const char *s = "abcbda";
    expect(s + 5 == strrchr(s, 'a'));
    expect(s + strlen(s) == strrchr(s, '\0'));
  }

  {
    const char bytes[] = { 1, 2, 3, 4, 5, 6 };
    expect(bytes + 3 == memchr(bytes, 4, sizeof(bytes)));
    expect(NULL == memchr(bytes, 9, sizeof(bytes)));
  }

  {
    char dst[64];
    expect(dst == strcpy(dst, "hello"));
    expect(0 == strcmp(dst, "hello"));
    expect(dst == strcat(dst, " world"));
    expect(0 == strcmp(dst, "hello world"));
  }

  puts("Success!");
  return 0;
}
