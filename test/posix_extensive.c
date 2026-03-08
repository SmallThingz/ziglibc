#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <libgen.h>
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

  {
    const char *needle = "posix-dirent.tmp";
    FILE *f = fopen(needle, "w");
    DIR *dir;
    struct dirent *ent;
    int saw = 0;
    expect(f != NULL);
    expect(0 == fclose(f));
    dir = opendir(".");
    expect(dir != NULL);
    while ((ent = readdir(dir)) != NULL) {
      if (0 == strcmp(ent->d_name, needle)) {
        saw = 1;
        break;
      }
    }
    expect(1 == saw);
    expect(0 == closedir(dir));
    expect(0 == unlink(needle));
  }

  {
    char host[256];
    expect(0 == gethostname(host, sizeof(host)));
    expect(host[0] != '\0');
    errno = 0;
    expect(-1 == gethostname(host, 0));
    expect(EINVAL == errno);
  }

  {
    char path1[] = "/usr/lib";
    char path2[] = "noslash";
    char path3[] = "/";
    expect(0 == strcmp("/usr", dirname(path1)));
    expect(0 == strcmp(".", dirname(path2)));
    expect(0 == strcmp("/", dirname(path3)));
  }

  {
    time_t t = 946684800;
    struct tm *utc = gmtime(&t);
    char *asc;
    char *ct;
    expect(utc != NULL);
    asc = asctime(utc);
    expect(asc != NULL);
    expect(0 == strncmp(asc, "Sat Jan  1 00:00:00 2000\n", 25));
    ct = ctime(&t);
    expect(ct != NULL);
    expect(0 == strcmp(ct, asctime(localtime(&t))));
    expect(0 == sleep(0));
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
    const char *name = "posix-openat.tmp";
    int fd = openat(AT_FDCWD, name, O_CREAT | O_TRUNC | O_RDWR, 0600);
    struct stat st;
    expect(fd >= 0);
    expect(4 == write(fd, "open", 4));
    expect(0 == close(fd));
    expect(0 == stat(name, &st));
    expect(4 == st.st_size);
    expect(0 == unlink(name));
  }

  {
    const char *name = "posix-openat-relative.tmp";
    int dirfd = open(".", O_RDONLY);
    int fd;
    struct stat st;
    expect(dirfd >= 0);
    fd = openat(dirfd, name, O_CREAT | O_TRUNC | O_RDWR, 0600);
    expect(fd >= 0);
    expect(3 == write(fd, "dir", 3));
    expect(0 == close(fd));
    expect(0 == stat(name, &st));
    expect(3 == st.st_size);
    expect(0 == close(dirfd));
    expect(0 == unlink(name));
  }

  {
    const char *name = "posix-fcntl.tmp";
    int fd = open(name, O_CREAT | O_TRUNC | O_RDWR, 0600);
    int flags;
    int dupfd;
    expect(fd >= 0);
    flags = fcntl(fd, F_GETFL);
    expect(flags >= 0);
    expect((flags & 0x3) == O_RDWR);
    expect(0 == fcntl(fd, F_SETFD, FD_CLOEXEC));
    flags = fcntl(fd, F_GETFD);
    expect(flags >= 0);
    expect((flags & FD_CLOEXEC) == FD_CLOEXEC);
    dupfd = fcntl(fd, F_DUPFD, 8);
    expect(dupfd >= 8);
    expect(dupfd != fd);
    expect(0 == close(dupfd));
    expect(0 == close(fd));
    expect(0 == unlink(name));
  }

  {
    mode_t old = umask(077);
    const char *name = "posix-umask.tmp";
    int fd = open(name, O_CREAT | O_TRUNC | O_RDWR, 0666);
    struct stat st;
    expect(fd >= 0);
    expect(0 == close(fd));
    expect(0 == stat(name, &st));
    expect((st.st_mode & 0777) == 0600);
    expect(0 == unlink(name));
    (void)umask(old);
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

  {
    const char *name = "posix-link-src.tmp";
    const char *alias = "posix-link-dst.tmp";
    struct stat st_src;
    struct stat st_alias;
    int fd = open(name, O_CREAT | O_TRUNC | O_RDWR, 0600);
    expect(fd >= 0);
    expect(4 == write(fd, "link", 4));
    expect(0 == close(fd));
    expect(0 == link(name, alias));
    expect(0 == stat(name, &st_src));
    expect(0 == stat(alias, &st_alias));
    expect(st_src.st_size == st_alias.st_size);
    expect(0 == unlink(alias));
    expect(0 == unlink(name));
  }

  {
    const char *name = "posix-writev.tmp";
    int fd = open(name, O_CREAT | O_TRUNC | O_RDWR, 0600);
    struct iovec outv[2];
    char a[4];
    char b[4];
    struct iovec inv[2];
    expect(fd >= 0);
    outv[0].iov_base = (void *)"ab";
    outv[0].iov_len = 2;
    outv[1].iov_base = (void *)"cd";
    outv[1].iov_len = 2;
    expect(4 == writev(fd, outv, 2));
    expect(0 == close(fd));

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
    expect(0 == unlink(name));
  }

  {
    FILE *fa = fopen("posix-dirent-a.tmp", "w");
    FILE *fb = fopen("posix-dirent-b.tmp", "w");
    DIR *dir;
    struct dirent *ent;
    int saw_a = 0;
    int saw_b = 0;
    expect(fa != NULL);
    expect(fb != NULL);
    expect(0 == fclose(fa));
    expect(0 == fclose(fb));
    dir = opendir(".");
    expect(dir != NULL);
    while ((ent = readdir(dir)) != NULL) {
      if (0 == strcmp(ent->d_name, "posix-dirent-a.tmp")) saw_a = 1;
      if (0 == strcmp(ent->d_name, "posix-dirent-b.tmp")) saw_b = 1;
    }
    expect(0 == closedir(dir));
    expect(saw_a);
    expect(saw_b);
    expect(0 == unlink("posix-dirent-a.tmp"));
    expect(0 == unlink("posix-dirent-b.tmp"));
  }

  {
    FILE *f = fopen("posix-pathconf.tmp", "w");
    int fd;
    expect(pathconf(".", _PC_LINK_MAX) > 0);
    errno = 0;
    expect(-1 == pathconf(".", -1));
    expect(EINVAL == errno);
    expect(f != NULL);
    fd = fileno(f);
    expect(fpathconf(fd, _PC_LINK_MAX) > 0);
    errno = 0;
    expect(-1 == fpathconf(-1, _PC_LINK_MAX));
    expect(errno != 0);
    errno = 0;
    expect(-1 == fpathconf(12345, _PC_LINK_MAX));
    expect(EBADF == errno);
    expect(0 == fclose(f));
    expect(0 == unlink("posix-pathconf.tmp"));
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
    FILE *p = popen("for /l %i in (1,1,1024) do @<nul set /p =x", "r");
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

  {
    const char *name = "posix-openat-win.tmp";
    const char *alias = "posix-link-win.tmp";
    int fd = openat(AT_FDCWD, name, O_CREAT | O_TRUNC | O_RDWR, 0600);
    struct stat st;
    struct iovec outv[2];
    char a[4];
    char b[4];
    struct iovec inv[2];
    char host[256];
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
  }
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
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
