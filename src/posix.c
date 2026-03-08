// NOTE: contains the implementations of functions for libposix that require varargs
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/time.h>
#include <sys/select.h>
#include <mach/mach_time.h>
extern long syscall(int, ...);
#endif

#if defined(__GNUC__) || defined(__clang__)
#define LIBCGUANA_INTERNAL __attribute__((visibility("hidden")))
#else
#define LIBCGUANA_INTERNAL
#endif

static int zdarwin_errno_value(long rc)
{
    return rc < 0 ? (int)(-rc) : (int)rc;
}

extern char *optarg;
extern int opterr, optind, optopt;
int getopt(int argc, char * const argv[], const char *optstring);

struct option {
    const char *name;
    int has_arg;
    int *flag;
    int val;
};

enum {
    no_argument = 0,
    required_argument = 1,
    optional_argument = 2,
};

static size_t zgnu_long_option_name_len(const char *name)
{
    size_t i = 0;
    while (name[i] != '\0' && name[i] != '=') i += 1;
    return i;
}

static int zgnu_getopt_long_common(
    int argc,
    char * const argv[],
    const char *optstring,
    const struct option *longopts,
    int *longindex,
    int long_only)
{
    const char *arg;
    const char *long_name;
    char *inline_value;
    int single_dash_long = 0;
    size_t name_len;
    size_t i;

    optarg = NULL;
    if (optind < 1) optind = 1;
    if (optind >= argc) return -1;

    arg = argv[optind];
    if (arg[0] == '-' && arg[1] == '-') {
        if (arg[2] == '\0') {
            optind += 1;
            return -1;
        }
        long_name = arg + 2;
    } else if (long_only && arg[0] == '-' && arg[1] != '\0' && arg[1] != '-') {
        long_name = arg + 1;
        single_dash_long = 1;
    } else {
        return getopt(argc, argv, optstring);
    }

    name_len = zgnu_long_option_name_len(long_name);
    inline_value = long_name[name_len] == '=' ? (char *)(long_name + name_len + 1) : NULL;

    for (i = 0; longopts[i].name != NULL; ++i) {
        const struct option *opt = &longopts[i];
        if (strncmp(opt->name, long_name, name_len) != 0 || opt->name[name_len] != '\0') continue;

        if (longindex != NULL) *longindex = (int)i;

        switch (opt->has_arg) {
            case no_argument:
                if (inline_value != NULL) {
                    optind += 1;
                    return '?';
                }
                optarg = NULL;
                break;
            case required_argument:
                if (inline_value != NULL) {
                    optarg = inline_value;
                } else if (optind + 1 < argc) {
                    optind += 1;
                    optarg = argv[optind];
                } else {
                    optind += 1;
                    return optstring[0] == ':' ? ':' : '?';
                }
                break;
            case optional_argument:
                optarg = inline_value;
                break;
            default:
                errno = EINVAL;
                optind += 1;
                return '?';
        }

        optind += 1;
        if (opt->flag != NULL) {
            *opt->flag = opt->val;
            return 0;
        }
        return opt->val;
    }

    if (single_dash_long) return getopt(argc, argv, optstring);

    optind += 1;
    return '?';
}

int __ziglibc_getopt_long(int argc, char * const argv[], const char *optstring, const struct option *longopts, int *longindex)
{
    // Keep the long-option parser in C. This path needs a conservative C ABI
    // surface because the earlier Zig implementation hit target-specific ABI /
    // codegen problems before any parser semantics were observable. Export the
    // standard GNU names for compatibility, but keep the implementation under a
    // private alias so the public symbol remains a thin, stable entry point.
    return zgnu_getopt_long_common(argc, argv, optstring, longopts, longindex, 0);
}

int getopt_long(int argc, char * const argv[], const char *optstring, const struct option *longopts, int *longindex)
{
    return __ziglibc_getopt_long(argc, argv, optstring, longopts, longindex);
}

int __ziglibc_getopt_long_only(int argc, char * const argv[], const char *optstring, const struct option *longopts, int *longindex)
{
    return zgnu_getopt_long_common(argc, argv, optstring, longopts, longindex, 1);
}

int getopt_long_only(int argc, char * const argv[], const char *optstring, const struct option *longopts, int *longindex)
{
    return __ziglibc_getopt_long_only(argc, argv, optstring, longopts, longindex);
}

// --------------------------------------------------------------------------------
// fcntl
// --------------------------------------------------------------------------------
LIBCGUANA_INTERNAL int _zopen(const char *path, int oflag, unsigned mode);
LIBCGUANA_INTERNAL int _zopenat(int fd, const char *path, int oflag, unsigned mode);
LIBCGUANA_INTERNAL int _fcntlArgInt(int fildes, int cmd, int arg);

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

int fcntl(int fildes, int cmd, ...)
{
    int arg = 0;
    switch (cmd) {
        case F_DUPFD:
        case F_SETFD:
        case F_SETFL:
        case F_SETOWN:
        case F_GETOWN:
            {
                va_list args;
                va_start(args, cmd);
                arg = va_arg(args, int);
                va_end(args);
            }
            break;
        default:
            break;
    }
    return _fcntlArgInt(fildes, cmd, arg);
}

// --------------------------------------------------------------------------------
// sys/ioctl
// --------------------------------------------------------------------------------
LIBCGUANA_INTERNAL int _ioctlArgPtr(int fd, unsigned long request, void *arg);

#if defined(__APPLE__) && defined(__aarch64__)
LIBCGUANA_INTERNAL int _zdarwin_fstat64(int fd, void *buf)
{
    register long x0 __asm("x0") = (long)fd;
    register void *x1 __asm("x1") = buf;
    unsigned int carry;

    /*
     * Native Apple Silicon exposed a real ABI bug in the generic variadic
     * `syscall()` path for `fstat`. Keep this on a fixed-arity trap so the
     * kernel sees the exact register layout that libsyscall uses for
     * `___fstat64`.
     */
    __asm__ volatile(
        "mov x16, #339\n"
        "svc #0x80\n"
        "cset %w2, cs\n"
        : "+r"(x0), "+r"(x1), "=r"(carry)
        :
        : "x16", "cc", "memory");

    if (carry != 0) {
        errno = zdarwin_errno_value(x0);
        return -1;
    }
    return (int)x0;
}
#endif

#if defined(__APPLE__)
LIBCGUANA_INTERNAL int _zdarwin_select(int nfds, void *readfds, void *writefds, void *errorfds, void *timeout)
{
#if defined(__aarch64__)
    register long x0 __asm("x0") = (long)nfds;
    register void *x1 __asm("x1") = readfds;
    register void *x2 __asm("x2") = writefds;
    register void *x3 __asm("x3") = errorfds;
    register void *x4 __asm("x4") = timeout;
    unsigned int carry;

    __asm__ volatile(
        "mov x16, #93\n"
        "svc #0x80\n"
        "cset %w5, cs\n"
        : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x4), "=r"(carry)
        :
        : "x16", "cc", "memory");

    if (carry != 0) {
        errno = zdarwin_errno_value(x0);
        return -1;
    }
    return (int)x0;
#elif defined(__x86_64__)
    long rc = syscall(93, nfds, readfds, writefds, errorfds, timeout);
    return (int)rc;
#else
    return -1;
#endif
}

LIBCGUANA_INTERNAL int _zdarwin_pselect(int nfds, void *readfds, void *writefds, void *errorfds, const struct timespec *timeout, const void *sigmask)
{
#if defined(__aarch64__)
    register long x0 __asm("x0") = (long)nfds;
    register void *x1 __asm("x1") = readfds;
    register void *x2 __asm("x2") = writefds;
    register void *x3 __asm("x3") = errorfds;
    register const struct timespec *x4 __asm("x4") = timeout;
    register const void *x5 __asm("x5") = sigmask;
    unsigned int carry;

    __asm__ volatile(
        "mov x16, #394\n"
        "svc #0x80\n"
        "cset %w6, cs\n"
        : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x4), "+r"(x5), "=r"(carry)
        :
        : "x16", "cc", "memory");

    if (carry != 0) {
        errno = zdarwin_errno_value(x0);
        return -1;
    }
    return (int)x0;
#elif defined(__x86_64__)
    long rc = syscall(394, nfds, readfds, writefds, errorfds, timeout, sigmask);
    return (int)rc;
#else
    return -1;
#endif
}
#endif

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
