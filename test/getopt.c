#include <assert.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>

static void getopt_mark(const char *label)
{
  if (getenv("ZIGLIBC_TEST_MARKERS") != NULL) {
    fputs(label, stderr);
    fputc('\n', stderr);
    fflush(stderr);
  }
}

int main(int argc, char *argv[])
{
  int aflag = 0;
  char *c_arg = NULL;
  {
    int c;
    getopt_mark("getopt:block:parse");
    while ((c = getopt(argc, argv, "abc:")) != -1) {
      switch (c) {
      case 'a':
        aflag = 1;
        break;
      case 'c':
        c_arg = optarg;
        break;
      case '?':
        fprintf(stderr, "Unrecognized option: '-%c'\n", optopt);
        return 1;
      default:
        assert(0);
      }
    }
  }
  getopt_mark("getopt:block:print");
  printf("aflag=%d, c_arg='%s'\n", aflag, c_arg);
  return 0;
}
