#ifndef _PRIVATE_SOCKADDR_H
#define _PRIVATE_SOCKADDR_H

#include "sa_family_t.h"

struct sockaddr {
  sa_family_t sa_family;
  char sa_data[14];
};

#endif /* _PRIVATE_SOCKADDR_H */
