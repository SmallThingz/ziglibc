#ifndef _FD_SET_H
#define _FD_SET_H

#define FD_SETSIZE 1024
typedef struct {
#ifdef __APPLE__
  /* Darwin's public fd_set uses 32-bit words even on 64-bit targets. Using
     `unsigned long` here breaks FD_SET bit placement for real descriptors while
     still letting timeout-only select(0, ...) appear correct. */
  int fds_bits[FD_SETSIZE / (sizeof(int) * 8)];
#else
  unsigned long fds_bits[FD_SETSIZE / (sizeof(unsigned long) * 8)];
#endif
} fd_set;

#endif /* _FD_SET_H */
