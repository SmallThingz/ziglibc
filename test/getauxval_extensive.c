#include <errno.h>
#include <stdio.h>

#include "expect.h"

extern unsigned long getauxval(unsigned long);

#ifndef AT_PAGESZ
#define AT_PAGESZ 6
#endif

#ifndef AT_PHNUM
#define AT_PHNUM 5
#endif

int main(void)
{
#ifdef __linux__
  expect(getauxval(AT_PAGESZ) >= 4096UL);
  expect(getauxval(AT_PHNUM) != 0);
  errno = 0;
  expect(getauxval(~0UL) == 0);
  expect(errno != 0);
#else
  expect(getauxval(AT_PAGESZ) == 0);
#endif

  puts("Success!");
  return 0;
}
