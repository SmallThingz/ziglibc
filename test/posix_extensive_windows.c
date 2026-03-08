#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#include "expect.h"

static volatile sig_atomic_t timer_hits;

static void alarm_handler(int sig)
{
  (void)sig;
  timer_hits++;
}

int main(void)
{
  const char *name = "posix-openat-win.tmp";
  const char *alias = "posix-link-win.tmp";
  struct stat st;
  struct iovec outv[2];
  struct iovec inv[2];
  char a[4];
  char b[4];
  char host[256];
  int fd;

  {
    const char *chmod_name = "posix-win-chmod.tmp";
    FILE *f = fopen(chmod_name, "w");
    expect(f != NULL);
    expect(0 == fclose(f));
    expect(0 == fstat(STDOUT_FILENO, &st));
    expect(0 == chmod(chmod_name, 0600));
    expect(0 == chmod(chmod_name, 0400));
    expect(0 == unlink(chmod_name));
    errno = 0;
    expect(-1 == chmod(chmod_name, 0600));
    expect(errno == ENOENT || errno == EACCES || errno == EINVAL);
  }

  {
    char templ[] = "mkostemp-win-XXXXXX";
    fd = mkostemp(templ, 0, 0);
    expect(fd >= 0);
    expect(0 == close(fd));
    expect(0 == unlink(templ));
  }

  {
    FILE *p = popen("(set /p =popen-ok <nul) & exit /b 0", "r");
    char buf[64];
    expect(p != NULL);
    expect(NULL != fgets(buf, sizeof(buf), p));
    expect(0 == strncmp(buf, "popen-ok", 8));
    expect(0 == pclose(p));
  }

  {
    FILE *p = popen("(for /l %i in (1,1,1024) do @<nul set /p =x) & exit /b 0", "r");
    char buf[8];
    expect(p != NULL);
    expect(NULL != fgets(buf, sizeof(buf), p));
    expect(buf[0] == 'x');
    expect(0 == pclose(p));
  }

  {
    FILE *p = popen("exit /b 5", "r");
    expect(p != NULL);
    expect(5 == pclose(p));
  }

  {
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 0;
    expect(0 == select(0, NULL, NULL, NULL, &tv));
  }

  {
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 0;
    errno = 0;
    expect(-1 == select(-1, NULL, NULL, NULL, &tv));
    expect(EINVAL == errno);
  }

  fd = openat(AT_FDCWD, name, O_CREAT | O_TRUNC | O_RDWR, 0600);
  expect(fd >= 0);
  outv[0].iov_base = (void *)"ab";
  outv[0].iov_len = 2;
  outv[1].iov_base = (void *)"cd";
  outv[1].iov_len = 2;
  expect(4 == writev(fd, outv, 2));
  expect(0 == close(fd));
  expect(0 == link(name, alias));
  expect(0 == stat(alias, &st));
  expect(4 == st.st_size);

  fd = open(name, O_RDONLY);
  expect(fd >= 0);
  memset(a, 0, sizeof(a));
  memset(b, 0, sizeof(b));
  inv[0].iov_base = a;
  inv[0].iov_len = 2;
  inv[1].iov_base = b;
  inv[1].iov_len = 2;
  expect(4 == readv(fd, inv, 2));
  expect(0 == memcmp(a, "ab", 2));
  expect(0 == memcmp(b, "cd", 2));
  expect(0 == close(fd));

  expect(0 == gethostname(host, sizeof(host)));
  expect(host[0] != '\0');
  expect(0 == unlink(alias));
  expect(0 == unlink(name));

  {
    struct itimerval val;
    struct itimerval old;
    memset(&val, 0, sizeof(val));
    memset(&old, 0, sizeof(old));
    expect(0 == setitimer(ITIMER_REAL, &val, &old));
    expect(0 == setitimer(ITIMER_REAL, &val, NULL));
  }

  {
    struct itimerval val;
    struct itimerval old;
    memset(&val, 0, sizeof(val));
    memset(&old, 0, sizeof(old));
    errno = 0;
    expect(-1 == setitimer(-1, &val, &old));
    expect(EINVAL == errno);
  }

  {
    struct itimerval val;
    struct itimerval old;
    struct itimerval cur;
    struct itimerval zero;
    int i;

    timer_hits = 0;
    expect(signal(SIGALRM, alarm_handler) != SIG_ERR);

    memset(&val, 0, sizeof(val));
    memset(&old, 0, sizeof(old));
    memset(&cur, 0, sizeof(cur));
    memset(&zero, 0, sizeof(zero));
    val.it_value.tv_sec = 0;
    val.it_value.tv_usec = 50000;

    expect(0 == setitimer(ITIMER_REAL, &val, &old));
    expect(0 == getitimer(ITIMER_REAL, &cur));
    expect(cur.it_value.tv_sec >= 0);
    expect(cur.it_value.tv_usec >= 0);

    for (i = 0; i < 50 && timer_hits == 0; ++i) {
      struct timeval wait_tv;
      int rc;
      wait_tv.tv_sec = 0;
      wait_tv.tv_usec = 10000;
      rc = select(0, NULL, NULL, NULL, &wait_tv);
      expect(rc == 0 || (rc == -1 && errno == EINTR));
    }

    expect(timer_hits >= 1);
    expect(0 == setitimer(ITIMER_REAL, &zero, &old));
  }

  {
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 0;
    expect(0 == pselect(0, NULL, NULL, NULL, &ts, NULL));
  }

  {
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 0;
    errno = 0;
    expect(-1 == pselect(-1, NULL, NULL, NULL, &ts, NULL));
    expect(EINVAL == errno);
  }

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
