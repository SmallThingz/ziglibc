#ifndef _PRIVATE_DEV_T_H
#define _PRIVATE_DEV_T_H

#ifdef __APPLE__
typedef int dev_t;
#else
typedef unsigned long long dev_t;
#endif

#endif /* _PRIVATE_DEV_T_H */
