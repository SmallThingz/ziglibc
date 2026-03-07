#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if LIBC_PARITY_HAVE_SETITIMER
#include <sys/time.h>
#endif

#if LIBC_PARITY_HAVE_SELECT
#include <sys/select.h>
#endif

#ifdef _WIN32
#define parity_popen _popen
#define parity_pclose _pclose
#define CMD_EXIT7 "exit /b 7"
#define CMD_EXIT5 "exit /b 5"
#define CMD_PRINTF "set /p =popen-ok <nul"
#define CMD_PATH "if defined PATH (set /p =yes <nul) else (set /p =no <nul)"
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
  printf("system-null:%d|", system(NULL));

  printf("system-exit7:%d|", system(CMD_EXIT7));

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

  return 0;
}
