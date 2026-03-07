#ifndef _FD_SET_H
#define _FD_SET_H

#define FD_SETSIZE 1024
typedef struct {
  unsigned long fds_bits[FD_SETSIZE / (sizeof(unsigned long) * 8)];
} fd_set;

#endif /* _FD_SET_H */
