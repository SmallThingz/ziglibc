#ifndef _PRIVATE_SUSECONDS_H
#define _PRIVATE_SUSECONDS_H

#ifdef __APPLE__
typedef int suseconds_t;
#else
typedef long suseconds_t;
#endif

#endif /* _PRIVATE_SUSECONDS_H */
