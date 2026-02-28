#include <argp.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "expect.h"

static int saw_args;
static int saw_no_args;
static int saw_end;

static error_t parser(int key, char *arg, struct argp_state *state)
{
  (void)state;
  switch (key) {
    case ARGP_KEY_ARGS:
      expect(arg != NULL);
      expect(0 == strcmp(arg, "first"));
      saw_args += 1;
      break;
    case ARGP_KEY_NO_ARGS:
      expect(arg == NULL);
      saw_no_args += 1;
      break;
    case ARGP_KEY_END:
      saw_end += 1;
      break;
    default:
      break;
  }
  return 0;
}

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

  {
    struct argp a = {0};
    int arg_index = -1;
    char arg0[] = "prog";
    char arg1[] = "first";
    char arg2[] = "second";
    char *argv[] = {arg0, arg1, arg2, NULL};
    a.parser = parser;
    expect(0 == argp_parse(&a, 3, argv, 0, &arg_index, NULL));
    expect(3 == arg_index);
    expect(1 == saw_args);
    expect(0 == saw_no_args);
    expect(1 == saw_end);
  }

  {
    struct argp a = {0};
    int arg_index = -1;
    char arg0[] = "prog";
    char *argv[] = {arg0, NULL};
    a.parser = parser;
    expect(0 == argp_parse(&a, 1, argv, 0, &arg_index, NULL));
    expect(1 == arg_index);
    expect(1 == saw_args);
    expect(1 == saw_no_args);
    expect(2 == saw_end);
  }

  {
    struct argp_state st = {0};
    argp_usage(&st);
  }

  puts("Success!");
  return 0;
}
