#ifndef _PRIVATE_SOCKADDR_H
#define _PRIVATE_SOCKADDR_H

#include "../../libc/private/uint8_t.h"
#include "sa_family_t.h"

struct sockaddr {
#ifdef __APPLE__
  uint8_t sa_len;
#endif
  sa_family_t sa_family;
  char sa_data[14];
};

#endif /* _PRIVATE_SOCKADDR_H */
