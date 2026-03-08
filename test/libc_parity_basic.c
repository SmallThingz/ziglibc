#include <errno.h>
#include <string.h>
#include "test_markers.h"

int main(void)
{
  TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "parity:block:system-null");
  printf("system-null:%d|", system(NULL) != 0);

  TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "parity:block:system-exit7");
  printf("system-exit7:%d|", system("exit 7"));

  TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "parity:block:getenv-path");
  { const char *path = getenv("PATH"); printf("getenv-path:%s|", path ? path : "(null)"); }

  TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "parity:block:popen-read");
  { FILE *p = popen("printf popen-ok", "r"); char buf[64] = {0}; if (!p || !fgets(buf, sizeof(buf), p)) return 1; printf("popen-read:%s:%d|", buf, pclose(p)); }

  TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "parity:block:popen-path");
  { const char *home = getenv("HOME"); if (home && home[0]) { FILE *p = popen("printf yes", "r"); char buf[16] = {0}; if (!p || !fgets(buf, sizeof(buf), p)) return 1; printf("popen-path:%s:%d|", buf, pclose(p)); } else { printf("popen-path:skip|"); } }

  TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "parity:block:popen-exit");
  printf("popen-exit5:%d|", pclose(popen("exit 5", "r")));

  TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "parity:block:fopen-many");
  {
    FILE *files[128]; size_t count = 0;
    while (count < (sizeof(files)/sizeof(files[0]))) {
#ifdef _WIN32
      FILE *f = fopen("NUL", "r");
#else
      FILE *f = fopen("/dev/null", "r");
#endif
      if (!f) break;
      files[count++] = f;
    }
    printf("fopen-many:%d:%zu|", count >= 128, count);
    while (count > 0) fclose(files[--count]);
  }

  return 0;
}
