// NOTE: contains the implementations of functions for libposix that require varargs
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>

#if defined(__GNUC__) || defined(__clang__)
#define LIBCGUANA_INTERNAL __attribute__((visibility("hidden")))
#else
#define LIBCGUANA_INTERNAL
#endif

// --------------------------------------------------------------------------------
// fcntl
// --------------------------------------------------------------------------------
LIBCGUANA_INTERNAL int _zopen(const char *path, int oflag, unsigned mode);

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
