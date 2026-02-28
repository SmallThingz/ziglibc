#include <alloca.h>
#include <stdio.h>
#include <string.h>

#include "expect.h"

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

  {
    char *p = (char *)alloca(32);
    expect(p != NULL);
    memcpy(p, "alloca-ok", 10);
    expect(0 == strcmp(p, "alloca-ok"));
  }

  puts("Success!");
  return 0;
}
