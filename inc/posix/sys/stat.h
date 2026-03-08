#ifndef _SYS_STAT_H
#define _SYS_STAT_H

#include "../../libc/private/restrict.h"
#include "../../libc/private/time_t.h"
#include "../../libc/private/timespec.h"

#include "../private/dev_t.h"
#include "../private/ino_t.h"
#include "../private/mode_t.h"
#include "../private/nlink_t.h"
#include "../private/uid_t.h"
#include "../private/gid_t.h"
#include "../private/off_t.h"
#include "../private/blksize_t.h"
#include "../private/blkcnt_t.h"

#define S_IXUSR 0100
#define S_IWUSR 0200
#define S_IRUSR 0400
#define S_IRWXG 0070
#define S_IRWXO 0007

#ifdef __APPLE__
struct stat {
  int st_dev;
  mode_t st_mode;
  unsigned short st_nlink;
  ino_t st_ino;
  uid_t st_uid;
  gid_t st_gid;
  int st_rdev;
  struct timespec st_atimespec;
  struct timespec st_mtimespec;
  struct timespec st_ctimespec;
  struct timespec st_birthtimespec;
  off_t st_size;
  blkcnt_t st_blocks;
  int st_blksize;
  unsigned int st_flags;
  unsigned int st_gen;
  int st_lspare;
  long long st_qspare[2];
};
#define st_atime st_atimespec.tv_sec
#define st_mtime st_mtimespec.tv_sec
#define st_ctime st_ctimespec.tv_sec
#else
struct stat {
  dev_t st_dev;
  ino_t st_ino;
  mode_t st_mode;
  nlink_t st_nlink;
  uid_t st_uid;
  gid_t st_gid;
  dev_t st_rdev;
  off_t st_size;
  time_t st_atime;
  time_t st_mtime;
  time_t st_ctime;
  blksize_t st_blksize;
  blkcnt_t st_blocks;
};
#endif

int stat(const char *__zrestrict path, struct stat *__zrestrict buf);
int chmod(const char *path, mode_t mode);
int fstat(int fildes, struct stat *buf);
mode_t umask(mode_t);

#endif /* _SYS_STAT_H */
