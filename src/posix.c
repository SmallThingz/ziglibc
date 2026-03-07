// NOTE: contains the implementations of functions for libposix that require varargs
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>

#if defined(__APPLE__)
#include <sys/time.h>
#include <mach/mach_time.h>
#endif

#if defined(__GNUC__) || defined(__clang__)
#define LIBCGUANA_INTERNAL __attribute__((visibility("hidden")))
#else
#define LIBCGUANA_INTERNAL
#endif

// --------------------------------------------------------------------------------
// fcntl
// --------------------------------------------------------------------------------
LIBCGUANA_INTERNAL int _zopen(const char *path, int oflag, unsigned mode);
LIBCGUANA_INTERNAL int _zopenat(int fd, const char *path, int oflag, unsigned mode);

int open(const char *path, int oflag, ...)
{
    unsigned mode = 0;
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode = va_arg(args, unsigned);
        va_end(args);
    }
    return _zopen(path, oflag, mode);
}

int openat(int fd, const char *path, int oflag, ...)
{
    unsigned mode = 0;
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode = va_arg(args, unsigned);
        va_end(args);
    }
    return _zopenat(fd, path, oflag, mode);
}

// --------------------------------------------------------------------------------
// sys/ioctl
// --------------------------------------------------------------------------------
LIBCGUANA_INTERNAL int _ioctlArgPtr(int fd, unsigned long request, void *arg);

int ioctl(int fd, unsigned long request, ...)
{
    va_list args;
    va_start(args, request);
    void *arg_ptr = va_arg(args, void*);
    va_end(args);
    return _ioctlArgPtr(fd, request, arg_ptr);
}

// --------------------------------------------------------------------------------
// time
// --------------------------------------------------------------------------------
int clock_gettime(clockid_t clk_id, struct timespec *tp)
{
#if defined(__APPLE__)
    if (clk_id == CLOCK_REALTIME) {
        struct timeval tv;
        if (gettimeofday(&tv, NULL) != 0) {
            return -1;
        }
        tp->tv_sec = tv.tv_sec;
        tp->tv_nsec = tv.tv_usec * 1000L;
        return 0;
    }
#ifdef CLOCK_MONOTONIC
    if (clk_id == CLOCK_MONOTONIC) {
        mach_timebase_info_data_t timebase;
        uint64_t ticks;
        unsigned __int128 nanos;
        if (mach_timebase_info(&timebase) != 0 || timebase.denom == 0) {
            errno = EINVAL;
            return -1;
        }
        ticks = mach_absolute_time();
        nanos = ((unsigned __int128)ticks * (unsigned __int128)timebase.numer) / (unsigned __int128)timebase.denom;
        tp->tv_sec = (time_t)(nanos / 1000000000ULL);
        tp->tv_nsec = (long)(nanos % 1000000000ULL);
        return 0;
    }
#endif
    errno = EINVAL;
    return -1;
#else
    LIBCGUANA_INTERNAL int _zclock_gettime(clockid_t clk_id, long long parts[2]);
    long long parts[2] = { 0, 0 };
    int rc = _zclock_gettime(clk_id, parts);
    if (rc != 0) {
        return rc;
    }
    tp->tv_sec = (time_t)parts[0];
    tp->tv_nsec = (long)parts[1];
    return 0;
#endif
}
