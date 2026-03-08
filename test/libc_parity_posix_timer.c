#include <errno.h>
#include <string.h>
#ifndef _WIN32
#include <sys/select.h>
#include <sys/time.h>
#include <time.h>
#endif
#include "test_markers.h"

int main(void)
{
  TEST_SET_UNBUFFERED();
  TEST_MARK_ALWAYS("parity_posix_timer:block:setitimer");
#if LIBC_PARITY_HAVE_SETITIMER
  {
    struct itimerval val, old;
    int rc;
    memset(&val, 0, sizeof(val));
    memset(&old, 0, sizeof(old));
    errno = 0;
    rc = setitimer(ITIMER_REAL, &val, &old);
    printf("setitimer-zero:%d:%d:%d|", rc, errno, old.it_value.tv_sec == 0);
  }
#else
  printf("setitimer-zero:skip|");
#endif

  TEST_MARK_ALWAYS("parity_posix_timer:block:select");
#if LIBC_PARITY_HAVE_SELECT
  {
    struct timeval tv = {0,0};
    int rc;
    errno = 0;
    rc = select(0, NULL, NULL, NULL, &tv);
    printf("select-timeout:%d:%d:%d:%d", rc, (int)tv.tv_sec, (int)tv.tv_usec, errno);
  }
#else
  printf("select-timeout:skip");
#endif

  TEST_MARK_ALWAYS("parity_posix_timer:block:pselect");
#if LIBC_PARITY_HAVE_PSELECT
  {
    struct timespec ts = {0,0};
    int rc;
    errno = 0;
    rc = pselect(0, NULL, NULL, NULL, &ts, NULL);
    printf("pselect-timeout:%d:%d|", rc, (int)ts.tv_sec);
  }
#else
  printf("pselect-timeout:skip|");
#endif

  return 0;
}
