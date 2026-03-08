#include <errno.h>
#ifndef _WIN32
#include <sys/stat.h>
#include <sys/time.h>
#endif
#include <unistd.h>
#include "test_markers.h"

int main(void)
{
  TEST_SET_UNBUFFERED();

  TEST_MARK_ALWAYS("parity_posix_utimes:block:utimes");
#if LIBC_PARITY_HAVE_UTIMES
  {
    struct timeval tv[2];
    struct stat st;
    int rc;
    FILE *f = fopen("parity-utimes.tmp", "w");
    if (!f) return 1;
    fclose(f);
    tv[0].tv_sec = 946684801;
    tv[0].tv_usec = 0;
    tv[1] = tv[0];
    errno = 0;
    rc = utimes("parity-utimes.tmp", tv);
    printf("utimes-basic:%d:%d:", rc, errno);
    if (stat("parity-utimes.tmp", &st) == 0) printf("%lld|", (long long)st.st_mtime);
    else printf("statfail|");
    unlink("parity-utimes.tmp");
  }
#else
  printf("utimes-basic:skip|");
#endif
  return 0;
}
