#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "expect.h"

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

  {
    void *p = malloc(0);
    free(p);
  }

  {
    unsigned char *p = calloc(16, 1);
    size_t i;
    expect(p != NULL);
    for (i = 0; i < 16; ++i) {
      expect(0 == p[i]);
    }
    free(p);
  }

  {
    char *p = malloc(8);
    expect(p != NULL);
    strcpy(p, "abc");
    p = realloc(p, 32);
    expect(p != NULL);
    expect(0 == strcmp(p, "abc"));
    expect(p == strcat(p, "def"));
    expect(0 == strcmp(p, "abcdef"));
    free(p);
  }

  {
    const char *path = getenv("PATH");
    const char *home = getenv("HOME");
    const char *pwd = getenv("PWD");
    expect(NULL == getenv(""));
    expect(NULL == getenv("A=B"));
    expect(NULL == getenv("__ZIGLIBC_MISSING_VAR__"));
#ifdef __linux__
    expect(path != NULL || home != NULL || pwd != NULL);
#else
    (void)path;
    (void)home;
    (void)pwd;
#endif
  }

#ifndef _WIN32
  {
    int status = system(NULL);
    expect(status != 0);
    status = system("exit 7");
    expect(status != -1);
    expect((status & 0x7f) == 0);
    expect(7 == ((status >> 8) & 0xff));
  }

  {
    const char *home = getenv("HOME");
    if (home != NULL && home[0] != '\0') {
      int status = system("test -n \"$HOME\"");
      expect(status != -1);
      expect((status & 0x7f) == 0);
      expect(0 == ((status >> 8) & 0xff));
    }
  }
#else
  errno = 0;
  expect(-1 == system(NULL));
  expect(ENOSYS == errno);
#endif

  puts("Success!");
  return 0;
}
