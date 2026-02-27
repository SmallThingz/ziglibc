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

  errno = 0;
  expect(-1 == system(NULL));
  expect(ENOSYS == errno);

  puts("Success!");
  return 0;
}
