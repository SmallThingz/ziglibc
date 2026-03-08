#include <argp.h>
#include <errno.h>
#include <getopt.h>
#include <glob.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "expect.h"

static void gnu_mark(const char *label)
{
  if (getenv("ZIGLIBC_TEST_MARKERS") != NULL) {
    fputs(label, stderr);
    fputc('\n', stderr);
    fflush(stderr);
  }
}

#define GNU_MARK(label) gnu_mark(label)

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
    GNU_MARK("gnu:1");
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
    GNU_MARK("gnu:2");
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
    GNU_MARK("gnu:3");
    struct argp_state st = {0};
    argp_usage(&st);
  }

  {
    GNU_MARK("gnu:4");
    int flag = 0;
    int long_index = -1;
    char arg0[] = "prog";
    char arg1[] = "--alpha";
    char *argv[] = {arg0, arg1, NULL};
    struct option opts[] = {
      {"alpha", no_argument, &flag, 7},
      {0, 0, 0, 0}
    };
    optind = 1;
    GNU_MARK("gnu:4a");
    expect(0 == getopt_long(2, argv, "", opts, &long_index));
    GNU_MARK("gnu:4b");
    expect(7 == flag);
    expect(0 == long_index);
    GNU_MARK("gnu:4c");
    expect(-1 == getopt_long(2, argv, "", opts, &long_index));
    GNU_MARK("gnu:4d");
  }

  {
    GNU_MARK("gnu:5");
    int long_index = -1;
    char arg0[] = "prog";
    char arg1[] = "--beta=value";
    char *argv[] = {arg0, arg1, NULL};
    struct option opts[] = {
      {"beta", required_argument, 0, 'b'},
      {0, 0, 0, 0}
    };
    optind = 1;
    expect('b' == getopt_long(2, argv, "", opts, &long_index));
    expect(0 == strcmp(optarg, "value"));
    expect(0 == long_index);
  }

  {
    GNU_MARK("gnu:6");
    int long_index = -1;
    char arg0[] = "prog";
    char arg1[] = "-gamma";
    char *argv[] = {arg0, arg1, NULL};
    struct option opts[] = {
      {"gamma", no_argument, 0, 'g'},
      {0, 0, 0, 0}
    };
    optind = 1;
    expect('g' == getopt_long_only(2, argv, "", opts, &long_index));
    expect(0 == long_index);
  }

 #ifndef __APPLE__
  {
    GNU_MARK("gnu:7");
    FILE *fa = fopen("gnu-glob-a.tmp", "w");
    FILE *fb = fopen("gnu-glob-b.tmp", "w");
    glob_t g = {0};
    int saw_a = 0;
    int saw_b = 0;
    size_t i;
    expect(fa != NULL);
    expect(fb != NULL);
    expect(0 == fclose(fa));
    expect(0 == fclose(fb));
    expect(0 == glob("gnu-glob-*.tmp", 0, NULL, &g));
    for (i = 0; i < g.gl_pathc; ++i) {
      if (0 == strcmp(g.gl_pathv[i], "gnu-glob-a.tmp")) saw_a = 1;
      if (0 == strcmp(g.gl_pathv[i], "gnu-glob-b.tmp")) saw_b = 1;
    }
    expect(saw_a);
    expect(saw_b);
    globfree(&g);
    expect(0 == remove("gnu-glob-a.tmp"));
    expect(0 == remove("gnu-glob-b.tmp"));
  }
 #endif

  GNU_MARK("gnu:puts");
  puts("Success!");
  return 0;
}
