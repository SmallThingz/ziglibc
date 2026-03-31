#ifndef _SYS_TIME_H
#define _SYS_TIME_H

#include "../private/suseconds_t.h"
#include "../private/fd_set.h"

#include "../../libc/private/time_t.h"
#include "../../libc/private/restrict.h"
#include "../private/timeval.h"

#define ITIMER_REAL 0
#define ITIMER_VIRTUAL 1
#define ITIMER_PROF 2

struct itimerval {
  struct timeval it_interval;
  struct timeval it_value;
};

int getitimer(int, struct itimerval *);
int setitimer(int, const struct itimerval *__zrestrict, struct itimerval *__zrestrict);
int gettimeofday(struct timeval *__zrestrict, void *__zrestrict);
int select(int, fd_set *__zrestrict, fd_set *__zrestrict, fd_set *__zrestrict, struct timeval *__zrestrict);
int utimes(const char *, const struct timeval [2]);

#endif /* _SYS_TIME_H */
