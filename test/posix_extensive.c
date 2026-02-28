#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "expect.h"

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

  {
    const char *name = "posix-ext.tmp";
    FILE *f = fopen(name, "w");
    expect(f != NULL);
#ifndef _WIN32
    expect(fileno(f) >= 0);
#else
    (void)fileno(f);
#endif
    expect(0 == fclose(f));

    expect(0 == access(name, R_OK));
    expect(-1 == access("missing-posix-ext.tmp", R_OK));
    expect(0 == unlink(name));
    expect(-1 == unlink(name));
  }

  {
    char ch;
    errno = 0;
    expect(-1 == read(-1, &ch, 1));
    expect(0 != errno);
    errno = 0;
    expect(-1 == write(-1, "x", 1));
    expect(0 != errno);
  }

#ifndef _WIN32
  {
    const char *name = "posix-stat.tmp";
    int fd = open(name, O_CREAT | O_TRUNC | O_RDWR, 0600);
    struct stat st;
    expect(fd >= 0);
    expect(3 == write(fd, "abc", 3));
    expect(0 == fstat(fd, &st));
    expect(3 == st.st_size);
    expect(0 == chmod(name, 0600));
    expect(0 == close(fd));
    expect(0 == unlink(name));
  }

  {
    FILE *p = popen("printf popen-ok", "r");
    char buf[64];
    expect(p != NULL);
    expect(NULL != fgets(buf, sizeof(buf), p));
    expect(0 == strcmp(buf, "popen-ok"));
    expect(0 == pclose(p));
  }

  {
    FILE *p = popen("cat > /dev/null", "w");
    expect(p != NULL);
    expect(fputs("payload\n", p) >= 0);
    expect(0 == pclose(p));
  }

  {
    errno = 0;
    expect(NULL == popen("echo invalid", "x"));
    expect(EINVAL == errno);
  }
#endif

  {
    struct timeval tv;
    expect(0 == gettimeofday(&tv, NULL));
    expect(tv.tv_usec >= 0);
    expect(tv.tv_usec < 1000000);
  }

  {
    struct timespec ts;
    expect(0 == clock_gettime(CLOCK_REALTIME, &ts));
    expect(ts.tv_nsec >= 0);
    expect(ts.tv_nsec < 1000000000L);
  }

  expect(0 == strcasecmp("HeLLo", "hEllO"));
  expect(strcasecmp("abc", "abd") < 0);
  expect(strcasecmp("abD", "abc") > 0);

  {
    int tty = isatty(STDOUT_FILENO);
    expect(tty == 0 || tty == 1);
  }

  puts("Success!");
  return 0;
}
