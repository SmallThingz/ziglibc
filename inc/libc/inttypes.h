#ifndef _INTTYPES_H
#define _INTTYPES_H

#if __STDC_VERSION__ < 199901L
    #error inttypes.h requires at least c99 I think
#endif

// most headers don't include other headers, but, this one by definition
// also includes stdint.h and extends it
#include "stdint.h"

#define PRId32 __INT32_FMTd__
#define PRIi32 __INT32_FMTi__
#define PRIu32 __UINT32_FMTu__
#define PRIx32 __UINT32_FMTx__
#define PRIX32 __UINT32_FMTX__

#define PRId64 "lld"
#define PRIi64 "lli"
#define PRIu64 "llu"
#define PRIx64 "llx"
#define PRIX64 "llX"

#define PRIdPTR __INTPTR_FMTd__
#define PRIiPTR __INTPTR_FMTi__
#define PRIuPTR __UINTPTR_FMTu__
#define PRIxPTR __UINTPTR_FMTx__
#define PRIXPTR __UINTPTR_FMTX__

#endif /* _INTTYPES_H */
