#include <limits.h>
#include <stdio.h>

#include "expect.h"

int main(int argc, char **argv)
{
  char buf[PATH_MAX];
  int n = snprintf(buf, sizeof(buf), "%s", argv[0]);
  if (argc != 1) {
    fputs("startup:argc!=1\n", stderr);
    return 1;
  }
  if (argv == NULL) {
    fputs("startup:argv-null\n", stderr);
    return 1;
  }
  if (argv[0] == NULL) {
    fputs("startup:argv0-null\n", stderr);
    return 1;
  }
  if (argv[1] != NULL) {
    fputs("startup:argv1-not-null\n", stderr);
    return 1;
  }
  if (argv[0][0] == '\0') {
    fputs("startup:argv0-empty\n", stderr);
    return 1;
  }
  if (n >= (int)sizeof(buf)) {
    fputs("startup:argv0-not-valid-path\n", stderr);
    return 1;
  }

  puts("Success!");
  return 0;
}
