#include <inttypes.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <paths.h>
#include <pthread.h>
#include <stddef.h>
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>

#include "expect.h"

int main(void)
{
  struct sockaddr sa;
  struct sockaddr_in sin;
  struct stat st;
  fd_set set;
  pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
  pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
  const char *sig_name = strsignal(SIGINT);
  char format_buf[128];
  char format_hex_buf[128];
  char format_ptr_buf[128];
  int64_t i64 = -123;
  uint64_t u64 = 456;
  int32_t i32 = -77;
  uint32_t u32 = 99;
  intptr_t iptr = (intptr_t)-42;
  uintptr_t uptr = (uintptr_t)0xabc;
  size_t max_size = SIZE_MAX;

  memset(&sa, 0, sizeof(sa));
  memset(&sin, 0, sizeof(sin));
  memset(&st, 0, sizeof(st));
  FD_ZERO(&set);
  FD_SET(0, &set);
  snprintf(format_buf, sizeof(format_buf),
           "%" PRIi64 " %" PRIu64 " %" PRIuPTR,
           i64, u64, uptr);
  snprintf(format_hex_buf, sizeof(format_hex_buf),
           "%" PRIX32 " %" PRIX64 " %" PRIXPTR,
           (uint32_t)0xbeef, (uint64_t)0xcafe, uptr);
  snprintf(format_ptr_buf, sizeof(format_ptr_buf),
           "%" PRIi32 " %" PRIu32 " %" PRIdPTR,
           i32, u32, iptr);

  expect(DBL_MAX > 1.0);
  expect(FLT_MAX > 1.0f);
  expect(PATH_MAX > 0);
  expect(RAND_MAX > 0);
  expect(FIONBIO != 0);
  expect(FD_ISSET(0, &set) == 1);
  expect(sig_name != NULL);
  expect(sig_name[0] != 0);
  expect(strcmp(format_buf, "-123 456 2748") == 0);
  expect(strcmp(format_hex_buf, "BEEF CAFE ABC") == 0);
  expect(strcmp(format_ptr_buf, "-77 99 -42") == 0);
  expect(sizeof(sa) >= sizeof(sa.sa_family));
  expect(sizeof(sin) >= sizeof(sin.sin_addr));
  expect(sizeof(st.st_size) >= 8);
  expect((int)PTHREAD_CREATE_JOINABLE != (int)PTHREAD_CREATE_DETACHED);
  expect(max_size == (size_t)-1);

  (void)mutex;
  (void)cond;

  puts("Success!");
  return 0;
}
