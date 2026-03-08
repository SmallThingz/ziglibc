#ifndef _PTHREAD_H
#define _PTHREAD_H

#define PTHREAD_BARRIER_SERIAL_THREAD (-1)
#define PTHREAD_CANCEL_ASYNCHRONOUS 1
#define PTHREAD_CANCEL_ENABLE 0
#define PTHREAD_CANCEL_DEFERRED 0
#define PTHREAD_CANCEL_DISABLE 1
#define PTHREAD_CANCELED ((void *)-1)
#define PTHREAD_CREATE_DETACHED 1
#define PTHREAD_CREATE_JOINABLE 0
#define PTHREAD_EXPLICIT_SCHED 1
#define PTHREAD_INHERIT_SCHED 0
#define PTHREAD_MUTEX_DEFAULT 0
#define PTHREAD_MUTEX_ERRORCHECK 2
#define PTHREAD_MUTEX_NORMAL 0
#define PTHREAD_MUTEX_RECURSIVE 1
#define PTHREAD_MUTEX_ROBUST 1
#define PTHREAD_MUTEX_STALLED 0
#define PTHREAD_ONCE_INIT 0
#define PTHREAD_PRIO_INHERIT 1
#define PTHREAD_PRIO_NONE 0
#define PTHREAD_PRIO_PROTECT 2
#define PTHREAD_PROCESS_SHARED 1
#define PTHREAD_PROCESS_PRIVATE 0
#define PTHREAD_SCOPE_PROCESS 1
#define PTHREAD_SCOPE_SYSTEM 0

typedef int pthread_barrier_t;
typedef int pthread_barrierattr_t;
#ifdef __APPLE__
#if defined(__LP64__)
#define __ZIGLIBC_PTHREAD_MUTEX_SIZE 56
#define __ZIGLIBC_PTHREAD_COND_SIZE 40
#else
#define __ZIGLIBC_PTHREAD_MUTEX_SIZE 40
#define __ZIGLIBC_PTHREAD_COND_SIZE 24
#endif
typedef struct {
  long __sig;
  char __opaque[__ZIGLIBC_PTHREAD_COND_SIZE];
} pthread_cond_t;
#else
typedef int pthread_cond_t;
#endif
typedef int pthread_condattr_t;
typedef int pthread_key_t;
#ifdef __APPLE__
typedef struct {
  long __sig;
  char __opaque[56];
} pthread_attr_t;
typedef void *pthread_t;
typedef struct {
  long __sig;
  char __opaque[__ZIGLIBC_PTHREAD_MUTEX_SIZE];
} pthread_mutex_t;
#else
typedef int pthread_mutex_t;
typedef int pthread_attr_t;
typedef int pthread_t;
#endif
typedef int pthread_mutexattr_t;
typedef int pthread_once_t;
typedef int pthread_rwlock_t;
typedef int pthread_rwlockattr_t;
typedef int pthread_spinlock_t;

#ifdef __APPLE__
#define _PTHREAD_MUTEX_SIG_init 0x32AAABA7L
#define _PTHREAD_COND_SIG_init 0x3CB0B1BBL
#define PTHREAD_MUTEX_INITIALIZER {_PTHREAD_MUTEX_SIG_init, {0}}
int pthread_mutex_init(pthread_mutex_t *restrict, const pthread_mutexattr_t *restrict);
int pthread_mutex_destroy(pthread_mutex_t *);
int pthread_mutex_lock(pthread_mutex_t *);
int pthread_mutex_unlock(pthread_mutex_t *);

#define PTHREAD_COND_INITIALIZER {_PTHREAD_COND_SIG_init, {0}}
#else
#define PTHREAD_MUTEX_INITIALIZER 0
int pthread_mutex_init(pthread_mutex_t *restrict, const pthread_mutexattr_t *restrict);
int pthread_mutex_destroy(pthread_mutex_t *);
int pthread_mutex_lock(pthread_mutex_t *);
int pthread_mutex_unlock(pthread_mutex_t *);

#define PTHREAD_COND_INITIALIZER 0
#endif
int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr);
int pthread_cond_destroy(pthread_cond_t *cond);
int pthread_cond_wait(pthread_cond_t *restrict cond, pthread_mutex_t *restrict mutex);
int pthread_cond_broadcast(pthread_cond_t *cond);
int pthread_cond_signal(pthread_cond_t *cond);

#endif /* _PTHREAD_H */
