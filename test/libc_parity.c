#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if LIBC_PARITY_HAVE_POSIX_IO
#include <fcntl.h>
#include <sys/uio.h>
#endif

#if LIBC_PARITY_HAVE_SETITIMER
#include <sys/time.h>
#endif

#if LIBC_PARITY_HAVE_SELECT
#include <sys/select.h>
#endif

#if LIBC_PARITY_HAVE_PSELECT
#include <sys/select.h>
#endif

#ifdef _WIN32
#define parity_popen _popen
#define parity_pclose _pclose
#define CMD_EXIT7 "exit /b 7"
#define CMD_EXIT5 "exit /b 5"
/*
 * Native cmd.exe and Wine's cmd disagree about the residual errorlevel from
 * `set /p ... <nul>`. Force an explicit shell exit code here so parity checks
 * exercise popen/pclose itself instead of emulator-specific shell behavior.
 */
#define CMD_PRINTF "(set /p =popen-ok <nul) & exit /b 0"
#define CMD_PATH "(if defined PATH (set /p =yes <nul) else (set /p =no <nul)) & exit /b 0"
#else
#define parity_popen popen
#define parity_pclose pclose
#define CMD_EXIT7 "exit 7"
#define CMD_EXIT5 "exit 5"
#define CMD_PRINTF "printf popen-ok"
#define CMD_PATH "if [ -n \"$PATH\" ]; then printf yes; else printf no; fi"
#endif

static void parity_handler(int sig)
{
  (void)sig;
}

static void read_all(FILE *stream, char *buf, size_t len)
{
  size_t n = fread(buf, 1, len - 1, stream);
  buf[n] = 0;
}

int main(void)
{
  setvbuf(stdout, NULL, _IONBF, 0);

  printf("system-null:%d|", system(NULL));

  printf("system-exit7:%d|", system(CMD_EXIT7));
  printf("getenv-path:%s|", getenv("PATH") ? getenv("PATH") : "null");

  {
    FILE *p = parity_popen(CMD_PRINTF, "r");
    char buf[64];
    int status = -1;
    memset(buf, 0, sizeof(buf));
    if (p != NULL) {
      read_all(p, buf, sizeof(buf));
      status = parity_pclose(p);
    }
    printf("popen-read:%s:%d|", p != NULL ? buf : "null", status);
  }

  {
    FILE *p = parity_popen(CMD_PATH, "r");
    char buf[64];
    int status = -1;
    memset(buf, 0, sizeof(buf));
    if (p != NULL) {
      read_all(p, buf, sizeof(buf));
      status = parity_pclose(p);
    }
    printf("popen-path:%s:%d|", p != NULL ? buf : "null", status);
  }

  {
    FILE *p = parity_popen(CMD_EXIT5, "r");
    int status = -1;
    if (p != NULL) {
      char buf[8];
      read_all(p, buf, sizeof(buf));
      status = parity_pclose(p);
    }
    printf("popen-exit5:%d|", status);
  }

  {
    FILE *files[128];
    size_t count = 0;
    while (count < (sizeof(files) / sizeof(files[0]))) {
#ifdef _WIN32
      FILE *f = fopen("NUL", "r");
#else
      FILE *f = fopen("/dev/null", "r");
#endif
      if (f == NULL) {
        break;
      }
      files[count++] = f;
    }
    printf("fopen-many:%d:%zu|", count >= 128, count);
    while (count > 0) {
      --count;
      fclose(files[count]);
    }
  }

  {
    void (*old_handler)(int) = signal(SIGINT, parity_handler);
    void (*prev_handler)(int) = signal(SIGINT, old_handler);
    printf("signal-basic:%d:%d|", old_handler != SIG_ERR, prev_handler == parity_handler);
  }

  {
    const char *s = "abc";
    char *endptr = NULL;
    errno = 123;
    printf("strtol-nodigits:%ld:%d:%ld|", strtol(s, &endptr, 10), errno, (long)(endptr - s));
  }

  {
    const char *s = "abc";
    char *endptr = NULL;
    double value;
    errno = 123;
    value = strtod(s, &endptr);
    printf("strtod-nodigits:%d:%d:%ld|", value == 0.0, errno, (long)(endptr - s));
  }

#if LIBC_PARITY_HAVE_STRSIGNAL
  {
    const char *name = strsignal(SIGINT);
    printf("strsignal-int:%s|", name ? name : "null");
  }
#else
  printf("strsignal-int:skip|");
#endif

#if LIBC_PARITY_HAVE_SIGACTION
  {
    struct sigaction act;
    struct sigaction old;
    struct sigaction restore;
    memset(&act, 0, sizeof(act));
    memset(&old, 0, sizeof(old));
    memset(&restore, 0, sizeof(restore));
    act.sa_handler = parity_handler;
    errno = 0;
    printf(
      "sigaction-basic:%d:%d:%d:%d|",
      sigaction(SIGINT, &act, &old),
      errno,
      sigaction(SIGINT, &old, &restore),
      restore.sa_handler == parity_handler
    );
  }
#else
  printf("sigaction-basic:skip|");
#endif

#if LIBC_PARITY_HAVE_SETITIMER
  {
    struct itimerval val;
    struct itimerval old;
    memset(&val, 0, sizeof(val));
    memset(&old, 0, sizeof(old));
    errno = 0;
    printf("setitimer-zero:%d:%d|", setitimer(ITIMER_REAL, &val, &old), errno);
  }
#else
  printf("setitimer-zero:skip|");
#endif

#if LIBC_PARITY_HAVE_SELECT
  {
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 0;
    errno = 0;
    printf("select-timeout:%d:%d:%ld:%ld", select(0, NULL, NULL, NULL, &tv), errno, (long)tv.tv_sec, (long)tv.tv_usec);
  }
#else
  printf("select-timeout:skip");
#endif

#if LIBC_PARITY_HAVE_PSELECT
  {
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 0;
    errno = 0;
    printf("pselect-timeout:%d:%d|", pselect(0, NULL, NULL, NULL, &ts, NULL), errno);
  }
#else
  printf("pselect-timeout:skip|");
#endif

#if LIBC_PARITY_HAVE_UTIMES
  {
    const char *path = "libc-parity-utimes.tmp";
    struct timeval tv[2];
    struct stat st;
    FILE *f = fopen(path, "w");
    tv[0].tv_sec = 946684800;
    tv[0].tv_usec = 0;
    tv[1].tv_sec = 946684801;
    tv[1].tv_usec = 0;
    if (f != NULL) {
      fclose(f);
      errno = 0;
      printf("utimes-basic:%d:%d:", utimes(path, tv), errno);
      if (stat(path, &st) == 0) {
        printf("%ld|", (long)st.st_mtime);
      } else {
        printf("stat-failed|");
      }
      unlink(path);
    } else {
      printf("utimes-basic:open-failed|");
    }
  }
#else
  printf("utimes-basic:skip|");
#endif

#if LIBC_PARITY_HAVE_POSIX_IO
  {
    char host[256];
    memset(host, 0, sizeof(host));
    if (gethostname(host, sizeof(host)) == 0) {
      printf("gethostname:%s|", host);
    } else {
      printf("gethostname:err:%d|", errno);
    }
  }

  {
    const char *path = "libc-parity-openat.tmp";
    int fd = openat(AT_FDCWD, path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    struct stat st;
    if (fd >= 0) {
      write(fd, "xy", 2);
      close(fd);
      if (stat(path, &st) == 0) {
        printf("openat-size:%ld|", (long)st.st_size);
      } else {
        printf("openat-size:stat-failed|");
      }
      unlink(path);
    } else {
      printf("openat-size:open-failed:%d|", errno);
    }
  }

  {
    const char *src = "libc-parity-link-src.tmp";
    const char *dst = "libc-parity-link-dst.tmp";
    FILE *f = fopen(src, "w");
    if (f != NULL) {
      fclose(f);
      errno = 0;
      printf("link-basic:%d:%d|", link(src, dst), errno);
      unlink(dst);
      unlink(src);
    } else {
      printf("link-basic:open-failed|");
    }
  }

  {
    const char *path = "libc-parity-fcntl.tmp";
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd >= 0) {
      int getfl = fcntl(fd, F_GETFL);
      int setfd = fcntl(fd, F_SETFD, FD_CLOEXEC);
      int getfd = fcntl(fd, F_GETFD);
      int dupfd = fcntl(fd, F_DUPFD, 8);
      printf(
        "fcntl-basic:%d:%d:%d:%d:%d|",
        getfl >= 0 ? (getfl & 0x3) : -1,
        setfd,
        getfd,
        dupfd >= 0,
        dupfd >= 0 ? (dupfd >= 8) : errno
      );
      if (dupfd >= 0) close(dupfd);
      close(fd);
      unlink(path);
    } else {
      printf("fcntl-basic:open-failed:%d|", errno);
    }
  }

  {
    const char *path = "libc-parity-uio.tmp";
    struct iovec out[2];
    struct iovec in[2];
    char left[3];
    char right[3];
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    out[0].iov_base = (void *)"ab";
    out[0].iov_len = 2;
    out[1].iov_base = (void *)"cd";
    out[1].iov_len = 2;
    memset(left, 0, sizeof(left));
    memset(right, 0, sizeof(right));
    if (fd >= 0) {
      printf("writev-basic:%ld:", (long)writev(fd, out, 2));
      close(fd);
      fd = open(path, O_RDONLY);
      in[0].iov_base = left;
      in[0].iov_len = 2;
      in[1].iov_base = right;
      in[1].iov_len = 2;
      printf("%ld:%s%s|", fd >= 0 ? (long)readv(fd, in, 2) : -1L, left, right);
      if (fd >= 0) close(fd);
      unlink(path);
    } else {
      printf("writev-basic:open-failed|");
    }
  }

  {
    FILE *f = fopen("libc-parity-pathconf.tmp", "w");
    if (f != NULL) {
      long pc = pathconf(".", _PC_LINK_MAX);
      long fpc = fpathconf(fileno(f), _PC_LINK_MAX);
      printf("pathconf-basic:%d:%d|", pc > 0, fpc > 0);
      fclose(f);
      unlink("libc-parity-pathconf.tmp");
    } else {
      printf("pathconf-basic:open-failed|");
    }
  }
#else
  printf("gethostname:skip|openat-size:skip|link-basic:skip|fcntl-basic:skip|writev-basic:skip|pathconf-basic:skip|");
#endif

  return 0;
}
