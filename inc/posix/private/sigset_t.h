#ifndef _PRIVATE_SIGSET_T_H
#define _PRIVATE_SIGSET_T_H

#ifdef __APPLE__
typedef unsigned int sigset_t;
#else
typedef struct { unsigned long __signals; } sigset_t;
#endif

#endif /* _PRIVATE_SIGSET_T_H */
