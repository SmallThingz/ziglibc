#ifndef _SYS_IOCTL_H
#define _SYS_IOCTL_H

int ioctl(int filedes, unsigned long request, ...);

// NOTE: this stuff is defined by linux, not posix, but they need
//       to live in this header
#if 1
    /* Linux/Darwin-compatible nonblocking ioctl request used by current callers. */
    #define FIONBIO 0x5421
#endif


#endif /* SYS_IOCTL_H */
