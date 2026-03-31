#ifndef _SYS_SELECT_H
#define _SYS_SELECT_H

// According to POSIX.1-2001
#if 1
    #include "../../libc/private/timespec.h"
    #include "../../libc/private/restrict.h"
    #include "../private/fd_set.h"
    #include "../private/sigset_t.h"
    #include "../private/timeval.h"

    void FD_CLR(int fd, fd_set *fdset);
    int FD_ISSET(int fd, fd_set *fdset);
    void FD_SET(int fd, fd_set *fdset);
    void FD_ZERO(fd_set *fdset);

    int pselect(int, fd_set *__zrestrict, fd_set *__zrestrict, fd_set *__zrestrict,
        const struct timespec *__zrestrict, const sigset_t *__zrestrict);
    int select(int, fd_set *__zrestrict, fd_set *__zrestrict, fd_set *__zrestrict,
        struct timeval *__zrestrict);
#endif

#endif /* _SYS_SELECT_H */
