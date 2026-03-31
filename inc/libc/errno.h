#ifndef _ERRNO_H
#define _ERRNO_H

extern int errno;

#if __STDC_VERSION__ >= 199901L
    #ifdef _WIN32
        #define EILSEQ 42
    #elif defined(__APPLE__)
        #define EILSEQ 92
    #else
        #define EILSEQ 84
    #endif
#endif

/* NOTE: these are defined by posix */
#if 1
    #define EPERM 1
    #define ENOENT 2
    #define E2BIG 7
    #define EINTR 4
    #define EBADF 9
    #ifdef __APPLE__
        #define EAGAIN 35
    #else
        #define EAGAIN 11
    #endif
    #define ENOMEM 12
    #define EACCES 13
    #define EEXIST 17
    #define EINVAL 22
    #define ENOTTY 25
    #define EPIPE 32
    #define EDOM 33
    #define ERANGE 34
    #ifdef _WIN32
        #define ENOSYS 40
        #define EWOULDBLOCK 140
        #define ECONNREFUSED 107
    #elif defined(__APPLE__)
        #define ENOSYS 78
        #define EWOULDBLOCK EAGAIN
        #define ECONNREFUSED 61
    #else
        #define ENOSYS 38
        #define EWOULDBLOCK EAGAIN
        #define ECONNREFUSED 111
    #endif
#endif

#endif /* _ERRNO_H */
