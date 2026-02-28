#include <argp.h>
#include <errno.h>
#include <stdio.h>

#include "expect.h"

static error_t parser(int key, char *arg, struct argp_state *state)
{
  (void)key;
  (void)arg;
  (void)state;
  return 0;
}

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

  {
    struct argp a = {0};
    int arg_index = -1;
    a.parser = parser;
    expect(ARGP_ERR_UNKNOWN == argp_parse(&a, 0, NULL, 0, &arg_index, NULL));
    expect(0 == arg_index);
  }

  {
    struct argp_state st = {0};
    argp_usage(&st);
  }

  puts("Success!");
  return 0;
}
