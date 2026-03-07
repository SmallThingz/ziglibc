#include <assert.h>
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

  assert(DBL_MAX > 1.0);
  assert(FLT_MAX > 1.0f);
  assert(PATH_MAX > 0);
  assert(RAND_MAX > 0);
  assert(FIONBIO != 0);
  assert(FD_ISSET(0, &set) == 1);
  assert(sig_name != NULL);
  assert(sig_name[0] != 0);
  assert(sizeof(sa) >= sizeof(sa.sa_family));
  assert(sizeof(sin) >= sizeof(sin.sin_addr));
  assert(sizeof(st.st_size) >= 8);
  assert((int)PTHREAD_CREATE_JOINABLE != (int)PTHREAD_CREATE_DETACHED);
  assert(errno >= 0);

  (void)mutex;
  (void)cond;

  puts("Success!");
  return 0;
}
