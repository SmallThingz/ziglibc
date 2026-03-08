#include <errno.h>
#include <stdio.h>
#include <time.h>
#include "expect.h"
#include "test_markers.h"

int main(void)
{
  {
    TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "panic_stdio:block:stdio-file");
    const char *name = "panic-repl.tmp";
    const char *renamed = "panic-repl-renamed.tmp";
    FILE *f = fopen(name, "w");
    expect(f != NULL);
    expect(0 == setvbuf(f, NULL, _IONBF, 0));
    errno = 0;
    expect(-1 == setvbuf(f, NULL, 12345, 0));
    expect(EINVAL == errno);
    expect(1 == fputs("abc", f));
    expect(3 == ftell(f));
    expect(0 == fseek(f, 0, SEEK_SET));
    expect(0 == fclose(f));
    expect(0 == rename(name, renamed));
    expect(-1 == remove(name));
    expect(0 == remove(renamed));
    expect(-1 == remove(renamed));
  }
#ifndef _WIN32
  {
    TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "panic_stdio:block:fopen-many");
    FILE *files[256];
    size_t count = 0;
    while (count < (sizeof(files) / sizeof(files[0]))) {
      FILE *f = fopen("/dev/null", "r");
      if (f == NULL) break;
      files[count++] = f;
    }
    expect(count == (sizeof(files) / sizeof(files[0])));
    while (count > 0) {
      --count;
      expect(0 == fclose(files[count]));
    }
  }
#endif
  TEST_MARK_IF_ENV("ZIGLIBC_TEST_MARKERS", "panic_stdio:block:perror");
  errno = ENOENT;
  perror("panic_stdio");
  puts("Success!");
  return 0;
}
