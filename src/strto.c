// Thin C ABI shims for strto* functions. Keep the parsing logic in Zig, but
// route the public char** ABI through C so Darwin-target pointer-to-pointer
// calls do not depend on target-specific Zig lowering details.
#include <stddef.h>
#include <stdlib.h>

#if defined(__GNUC__) || defined(__clang__)
#define ZIGLIBC_INTERNAL __attribute__((visibility("hidden")))
#else
#define ZIGLIBC_INTERNAL
#endif

ZIGLIBC_INTERNAL double _zstrtod(const char *nptr, const void *endptr);
ZIGLIBC_INTERNAL long _zstrtol(const char *nptr, const void *endptr, int base);
ZIGLIBC_INTERNAL long long _zstrtoll(const char *nptr, const void *endptr, int base);
ZIGLIBC_INTERNAL unsigned long _zstrtoul(const char *nptr, const void *endptr, int base);
ZIGLIBC_INTERNAL unsigned long long _zstrtoull(const char *nptr, const void *endptr, int base);

double strtod(const char *nptr, char **endptr)
{
  return _zstrtod(nptr, endptr);
}

long strtol(const char *nptr, char **endptr, int base)
{
  return _zstrtol(nptr, endptr, base);
}

long long strtoll(const char *nptr, char **endptr, int base)
{
  return _zstrtoll(nptr, endptr, base);
}

unsigned long strtoul(const char *nptr, char **endptr, int base)
{
  return _zstrtoul(nptr, endptr, base);
}

unsigned long long strtoull(const char *nptr, char **endptr, int base)
{
  return _zstrtoull(nptr, endptr, base);
}
