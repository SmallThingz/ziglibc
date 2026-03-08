#ifndef TEST_MARKERS_H
#define TEST_MARKERS_H

#include <stdio.h>
#include <stdlib.h>

#define TEST_SET_UNBUFFERED() \
  do { \
    setvbuf(stdout, NULL, _IONBF, 0); \
    setvbuf(stderr, NULL, _IONBF, 0); \
  } while (0)

#define TEST_MARK_IF_ENV(env_name, name) \
  do { \
    if (getenv(env_name) != NULL) { \
      fputs(name, stderr); \
      fputc('\n', stderr); \
      fflush(stderr); \
    } \
  } while (0)

#define TEST_MARK_ALWAYS(name) \
  do { \
    fputs(name, stderr); \
    fputc('\n', stderr); \
    fflush(stderr); \
  } while (0)

#endif
