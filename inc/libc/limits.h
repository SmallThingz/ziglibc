#ifndef _LIMITS_H
#define _LIMITS_H

#include "private/limits_and_float_shared.h"

#if __STDC_VERSION__ >= 199901L
    #define LLONG_MAX __LONG_LONG_MAX__
    #define LLONG_MIN (-__LONG_LONG_MAX__ - 1LL)
    #define ULLONG_MAX (__LONG_LONG_MAX__ * 2ULL + 1ULL)
#endif

#ifdef _WIN32
    #define PATH_MAX 260
#else
    #define PATH_MAX 4096
#endif

#endif /* _LIMITS_H */
