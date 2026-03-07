#include <errno.h>
#include <float.h>
#include <limits.h>
#include <paths.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
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

  memset(&sa, 0, sizeof(sa));
  memset(&sin, 0, sizeof(sin));
  memset(&st, 0, sizeof(st));
  FD_ZERO(&set);
  FD_SET(0, &set);

  expect(DBL_MAX > 1.0);
  expect(FLT_MAX > 1.0f);
  expect(PATH_MAX > 0);
  expect(RAND_MAX > 0);
  expect(FIONBIO != 0);
  expect(FD_ISSET(0, &set) == 1);
  expect(sig_name != NULL);
  expect(sig_name[0] != 0);
  expect(sizeof(sa) >= sizeof(sa.sa_family));
  expect(sizeof(sin) >= sizeof(sin.sin_addr));
  expect(sizeof(st.st_size) >= 8);
  expect((int)PTHREAD_CREATE_JOINABLE != (int)PTHREAD_CREATE_DETACHED);

  (void)mutex;
  (void)cond;

  puts("Success!");
  return 0;
}
