#ifndef _PRIVATE_SA_FAMILY_T_H
#define _PRIVATE_SA_FAMILY_T_H

#ifdef __APPLE__
#include "../../libc/private/uint8_t.h"
typedef uint8_t sa_family_t;
#else
typedef unsigned short sa_family_t;
#endif

#endif /* _PRIVATE_SA_FAMILY_T_H */
