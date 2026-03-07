#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>

#include "expect.h"

static void test_handler(int sig)
{
  (void)sig;
}

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

#ifndef _WIN32
  {
    void (*old_handler)(int) = signal(SIGINT, test_handler);
    expect(old_handler != SIG_ERR);

    void (*prev_handler)(int) = signal(SIGINT, old_handler);
    expect(prev_handler == test_handler);
  }

  {
    errno = 0;
    expect(SIG_ERR == signal(-1, test_handler));
    expect(EINVAL == errno);
  }

#ifdef __linux__
  {
    struct sigaction act;
    struct sigaction old;
    struct sigaction restore;
    memset(&act, 0, sizeof(act));
    act.sa_handler = test_handler;
    act.sa_flags = 0;
    expect(0 == sigaction(SIGINT, &act, &old));

    expect(0 == sigaction(SIGINT, &old, &restore));
    expect(restore.sa_handler == test_handler);
  }

  {
    struct sigaction act;
    struct sigaction old;
    memset(&act, 0, sizeof(act));
    act.sa_handler = test_handler;
    errno = 0;
    expect(-1 == sigaction(-1, &act, &old));
    expect(EINVAL == errno);
  }
#endif
#else
  expect(signal(SIGINT, test_handler) != SIG_ERR);
#endif

  puts("Success!");
  return 0;
}
