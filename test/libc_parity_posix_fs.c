#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#ifndef _WIN32
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/uio.h>
#endif
#include <unistd.h>

static void parity_mark(const char *name)
{
  fputs(name, stderr);
  fputc('\n', stderr);
  fflush(stderr);
}

int main(void)
{
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);

#if LIBC_PARITY_HAVE_POSIX_IO
  {
    char host[256];
    parity_mark("parity_posix_fs:block:gethostname");
    if (gethostname(host, sizeof(host)) != 0) return 1;
    printf("gethostname:%s|", host);
  }
  {
    int fd;
    struct stat st;
    parity_mark("parity_posix_fs:block:openat");
    fd = openat(AT_FDCWD, "parity-openat.tmp", O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) return 1;
    if (write(fd, "hi", 2) != 2) return 1;
    close(fd);
    if (stat("parity-openat.tmp", &st) != 0) return 1;
    printf("openat-size:%lld|", (long long)st.st_size);
    unlink("parity-openat.tmp");
  }
  {
    int fd, rc;
    struct stat a, b;
    parity_mark("parity_posix_fs:block:link");
    fd = open("parity-link-src.tmp", O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) return 1;
    if (write(fd, "xy", 2) != 2) return 1;
    close(fd);
    errno = 0;
    rc = link("parity-link-src.tmp", "parity-link-dst.tmp");
    printf("link-basic:%d:%d|", rc, errno);
    stat("parity-link-src.tmp", &a);
    stat("parity-link-dst.tmp", &b);
    if (a.st_size != b.st_size) return 1;
    unlink("parity-link-dst.tmp");
    unlink("parity-link-src.tmp");
  }
  {
    int fd, flags, dupfd, getfd_flags;
    parity_mark("parity_posix_fs:block:fcntl");
    fd = open("parity-fcntl.tmp", O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) return 1;
    flags = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    dupfd = fcntl(fd, F_DUPFD, 8);
    getfd_flags = fcntl(fd, F_GETFD);
    printf("fcntl-basic:%d:%d:%d:%d:%d|", flags & 0x3, errno, getfd_flags == FD_CLOEXEC, dupfd >= 8, dupfd != fd);
    close(dupfd);
    close(fd);
    unlink("parity-fcntl.tmp");
  }
  {
    int fd, read_ok, write_rc;
    struct iovec outv[2], inv[2];
    char a[3] = {0}, b[3] = {0};
    parity_mark("parity_posix_fs:block:writev");
    fd = open("parity-writev.tmp", O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) return 1;
    outv[0].iov_base = (void *)"ab"; outv[0].iov_len = 2;
    outv[1].iov_base = (void *)"cd"; outv[1].iov_len = 2;
    if (writev(fd, outv, 2) != 4) return 1;
    close(fd);
    fd = open("parity-writev.tmp", O_RDONLY);
    inv[0].iov_base = a; inv[0].iov_len = 2;
    inv[1].iov_base = b; inv[1].iov_len = 2;
    read_ok = (readv(fd, inv, 2) == 4);
    write_rc = writev(fd, outv, 2);
    printf("writev-basic:%d:%d:%s%s|", read_ok, write_rc, a, b);
    close(fd);
    unlink("parity-writev.tmp");
  }
  {
    parity_mark("parity_posix_fs:block:pathconf");
    printf("pathconf-basic:%d:%d|", pathconf(".", _PC_LINK_MAX) > 0, fpathconf(STDIN_FILENO, _PC_LINK_MAX) > 0 || errno != 0);
  }
#else
  printf("gethostname:skip|openat-size:skip|link-basic:skip|fcntl-basic:skip|writev-basic:skip|pathconf-basic:skip|");
#endif

  return 0;
}
