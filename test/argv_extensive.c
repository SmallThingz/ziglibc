#include <limits.h>
#include <stdio.h>

static int fail(const char *name)
{
  fputs(name, stderr);
  fputc('\n', stderr);
  return 1;
}

int main(int argc, char **argv)
{
  char buf[PATH_MAX];
  int n;

  if (argc != 1) return fail("argc");
  if (argv == NULL) return fail("argv-null");
  if (argv[0] == NULL) return fail("argv0-null");
  if (argv[1] != NULL) return fail("argv1-nonnull");
  if (argv[0][0] == '\0') return fail("argv0-empty");
  n = snprintf(buf, sizeof buf, "%s", argv[0]);
  if (n < 0) return fail("snprintf-neg");
  if (n >= (int)sizeof(buf)) return fail("snprintf-path");

  puts("Success!");
  return 0;
}
