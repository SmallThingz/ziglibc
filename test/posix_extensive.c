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
#include <time.h>
#include <unistd.h>

#include "expect.h"

static volatile sig_atomic_t timer_hits;

static void alarm_handler(int sig)
{
  (void)sig;
  timer_hits++;
}

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
    mode_t old = umask(022);
    mode_t prev = umask(old);
    expect(022 == prev);
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

  {
    const char *home = getenv("HOME");
    if (home != NULL && home[0] != '\0') {
      FILE *p = popen("printf %s \"$HOME\"", "r");
      char buf[512];
      expect(p != NULL);
      expect(NULL != fgets(buf, sizeof(buf), p));
      expect(0 == strcmp(buf, home));
      expect(0 == pclose(p));
    }
  }

#else
  {
    const char *name = "posix-win-chmod.tmp";
    struct stat st;
    FILE *f = fopen(name, "w");
    expect(f != NULL);
    expect(0 == fclose(f));
    expect(0 == fstat(STDOUT_FILENO, &st));
    expect(0 == chmod(name, 0600));
    expect(0 == chmod(name, 0400));
    expect(0 == unlink(name));
    errno = 0;
    expect(-1 == chmod(name, 0600));
    expect(errno == ENOENT || errno == EACCES || errno == EINVAL);
  }

  {
    char templ[] = "mkostemp-win-XXXXXX";
    int fd = mkostemp(templ, 0, 0);
    expect(fd >= 0);
    expect(0 == close(fd));
    expect(0 == unlink(templ));
  }

  {
    FILE *p = popen("set /p =popen-ok <nul", "r");
    char buf[64];
    expect(p != NULL);
    expect(NULL != fgets(buf, sizeof(buf), p));
    expect(0 == strncmp(buf, "popen-ok", 8));
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
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
  {
    struct itimerval val;
    struct itimerval old;
    memset(&val, 0, sizeof(val));
    memset(&old, 0, sizeof(old));
    expect(0 == setitimer(ITIMER_REAL, &val, &old));
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

#if defined(__linux__) || defined(_WIN32)
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
#endif

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
#endif

#if !defined(__APPLE__)
  {
    const char *name = "posix-utimes.tmp";
    struct timeval times[2];
    struct stat st;
    FILE *f = fopen(name, "w");
    expect(f != NULL);
    expect(0 == fclose(f));

    times[0].tv_sec = 946684800;
    times[0].tv_usec = 123456;
    times[1].tv_sec = 946684801;
    times[1].tv_usec = 654321;
    expect(0 == utimes(name, times));
    expect(0 == stat(name, &st));
    expect(st.st_mtime == times[1].tv_sec);

    times[0].tv_usec = 1000000;
    errno = 0;
    expect(-1 == utimes(name, times));
    expect(EINVAL == errno);
    expect(0 == unlink(name));
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
