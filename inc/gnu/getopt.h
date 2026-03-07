#ifndef _GETOPT_H
#define _GETOPT_H

/* GNU Make getopt.h checks for this define and will change the definition of getopt depending on it */
#define __GNU_LIBRARY__

#include "../posix/private/getopt.h"

struct option {
  const char *name;
  int has_arg;
  int *flag;
  int val;
};

#define no_argument 0
#define required_argument 1
#define optional_argument 2

int getopt_long(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longindex);
int getopt_long_only(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longindex);
int __ziglibc_getopt_long(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longindex);
int __ziglibc_getopt_long_only(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longindex);

#ifdef __APPLE__
/*
 * Darling is sensitive to same-image resolution of some public libc symbols.
 * Keep exporting the standard names for ABI compatibility, but route source
 * built against our headers through stable private aliases so the call target is
 * unambiguous in macOS-target tests.
 */
#define getopt_long __ziglibc_getopt_long
#define getopt_long_only __ziglibc_getopt_long_only
#endif

#endif /* _GETOPT_H */
