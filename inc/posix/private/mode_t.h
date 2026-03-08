#ifndef _PRIVATE_MODE_T_H
#define _PRIVATE_MODE_T_H

#ifdef __APPLE__
typedef unsigned short mode_t;
#else
typedef unsigned int mode_t;
#endif

#endif /* _PRIVATE_MODE_T_H */
