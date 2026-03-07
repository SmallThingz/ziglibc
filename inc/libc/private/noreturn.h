#ifndef _NORETURN_H_
#define _NORETURN_H_

#if defined(__cplusplus)
    #define __znoreturn [[noreturn]]
#elif __STDC_VERSION__ >= 201112L
    #define __znoreturn _Noreturn
#elif defined(__GNUC__) || defined(__clang__)
    #define __znoreturn __attribute__((__noreturn__))
#else
    #define __znoreturn
#endif

#endif /* _NORETURN_H_ */
