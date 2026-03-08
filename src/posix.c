// NOTE: contains the implementations of functions for libposix that require varargs
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/select.h>
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
LIBCGUANA_INTERNAL int _zdarwin_access(const char *path, int amode);

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
LIBCGUANA_INTERNAL int _zdarwin_access(const char *path, int amode)
{
#if defined(__aarch64__)
    register const char *x0 __asm("x0") = path;
    register long x1 __asm("x1") = (long)amode;
    register long x16 __asm("x16") = 33;
    unsigned int carry;

    __asm__ volatile(
        "svc #0x80\n"
        "cset %w3, cs\n"
        : "+r"(x0), "+r"(x1), "+r"(x16), "=r"(carry)
        :
        : "cc", "memory");

    if (carry != 0) {
        errno = zdarwin_errno_value((long)x0);
        return -1;
    }
    return 0;
#elif defined(__x86_64__)
    long rc = syscall(33, path, amode);
    if (rc < 0) {
        errno = zdarwin_errno_value(rc);
        return -1;
    }
    return (int)rc;
#else
    errno = ENOSYS;
    return -1;
#endif
}

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
