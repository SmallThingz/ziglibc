#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#define expect(x) do { if (!(x)) { fprintf(stderr, "expect fail: %s line %d errno=%d\n", #x, __LINE__, errno); fflush(stderr); return 1; } } while (0)
#define POSIX_MARK(name) do { if (getenv("ZIGLIBC_TEST_MARKERS") != NULL) { fputs(name, stderr); fputc('\n', stderr); fflush(stderr); } } while (0)

/*
 * Keep this test in the compact form below. Native macOS already found real
 * ABI bugs here, and Darling also reacts badly to some larger Debug codegen
 * shapes even when the exercised libc behavior is correct. This version keeps
 * the same Unix libc coverage while avoiding those translation-unit artifacts.
 */
int main(void) {
  const char *name;
  int fd;
  struct stat st;

  POSIX_MARK("posix:block:access");
  FILE *f = fopen("posix-ext.tmp", "w"); expect(f != NULL); expect(fileno(f) >= 0); expect(0 == fclose(f)); expect(0 == access("posix-ext.tmp", R_OK)); expect(-1 == access("missing-posix-ext.tmp", R_OK)); expect(0 == unlink("posix-ext.tmp")); expect(-1 == unlink("posix-ext.tmp"));
  POSIX_MARK("posix:block:readwrite-errors");
  { char ch; errno = 0; expect(-1 == read(-1,&ch,1)); expect(0 != errno); errno = 0; expect(-1 == write(-1,"x",1)); expect(0 != errno); }
  POSIX_MARK("posix:block:dirent-single");
  { FILE *df = fopen("posix-dirent.tmp", "w"); DIR *dir; struct dirent *ent; int saw=0; expect(df!=NULL); expect(0==fclose(df)); dir=opendir("."); expect(dir!=NULL); while((ent=readdir(dir))!=NULL){ if(strcmp(ent->d_name,"posix-dirent.tmp")==0){ saw=1; break; } } expect(saw); expect(0==closedir(dir)); expect(0==unlink("posix-dirent.tmp")); }
  POSIX_MARK("posix:block:gethostname");
  { char host[256]; expect(0==gethostname(host,sizeof(host))); expect(host[0] != '\0'); errno = 0; expect(-1 == gethostname(host, 0)); expect(EINVAL == errno); }
  POSIX_MARK("posix:block:dirname");
  { char path1[]="/usr/lib"; char path2[]="noslash"; char path3[]="/"; expect(strcmp("/usr",dirname(path1))==0); expect(strcmp(".",dirname(path2))==0); expect(strcmp("/",dirname(path3))==0); }
  POSIX_MARK("posix:block:time");
  { time_t t=946684800; struct tm *utc=gmtime(&t); char *asc; char *ct; expect(utc!=NULL); asc=asctime(utc); expect(asc!=NULL); expect(0==strncmp(asc,"Sat Jan  1 00:00:00 2000\n",25)); ct=ctime(&t); expect(ct!=NULL); expect(0==strcmp(ct, asctime(localtime(&t)))); expect(0 == sleep(0)); }
  POSIX_MARK("posix:block:stat");
  POSIX_MARK("posix:block:stat-open");
  fd=open("posix-stat.tmp", O_CREAT|O_TRUNC|O_RDWR, 0600); expect(fd>=0);
  POSIX_MARK("posix:block:stat-write");
  expect(3==write(fd,"abc",3));
  POSIX_MARK("posix:block:stat-fstat");
  expect(0==fstat(fd,&st)); expect(3==st.st_size);
  POSIX_MARK("posix:block:stat-chmod");
  expect(0==chmod("posix-stat.tmp",0600));
  POSIX_MARK("posix:block:stat-close");
  expect(0==close(fd));
  POSIX_MARK("posix:block:stat-unlink");
  expect(0==unlink("posix-stat.tmp"));
  POSIX_MARK("posix:block:openat");
  { mode_t old=umask(022); mode_t prev=umask(old); expect(022==prev); }
  fd=openat(AT_FDCWD,"posix-openat.tmp",O_CREAT|O_TRUNC|O_RDWR,0600); expect(fd>=0); expect(4==write(fd,"open",4)); expect(0==close(fd)); expect(0==stat("posix-openat.tmp",&st)); expect(4==st.st_size); expect(0==unlink("posix-openat.tmp"));
  { int dirfd=open(".",O_RDONLY); expect(dirfd>=0); fd=openat(dirfd,"posix-openat-relative.tmp",O_CREAT|O_TRUNC|O_RDWR,0600); expect(fd>=0); expect(3==write(fd,"dir",3)); expect(0==close(fd)); expect(0==stat("posix-openat-relative.tmp",&st)); expect(3==st.st_size); expect(0==close(dirfd)); expect(0==unlink("posix-openat-relative.tmp")); }
  POSIX_MARK("posix:block:fcntl");
  { int flags, dupfd; fd=open("posix-fcntl.tmp",O_CREAT|O_TRUNC|O_RDWR,0600); expect(fd>=0); flags=fcntl(fd,F_GETFL); expect(flags>=0); expect((flags&0x3)==O_RDWR); expect(0==fcntl(fd,F_SETFD,FD_CLOEXEC)); flags=fcntl(fd,F_GETFD); expect(flags>=0); expect((flags&FD_CLOEXEC)==FD_CLOEXEC); dupfd=fcntl(fd,F_DUPFD,8); expect(dupfd>=8); expect(dupfd != fd); expect(0==close(dupfd)); expect(0==close(fd)); expect(0==unlink("posix-fcntl.tmp")); }
  { mode_t old=umask(077); fd=open("posix-umask.tmp",O_CREAT|O_TRUNC|O_RDWR,0666); expect(fd>=0); expect(0==close(fd)); expect(0==stat("posix-umask.tmp",&st)); expect((st.st_mode & 0777)==0600); expect(0==unlink("posix-umask.tmp")); (void)umask(old); }
  POSIX_MARK("posix:block:popen");
  { FILE *p=popen("printf popen-ok","r"); char buf[64]; expect(p!=NULL); expect(NULL!=fgets(buf,sizeof(buf),p)); expect(0==strcmp(buf,"popen-ok")); expect(0==pclose(p)); }
  { FILE *p=popen("cat > /dev/null","w"); expect(p!=NULL); expect(fputs("payload\n",p)>=0); expect(0==pclose(p)); }
  { errno=0; expect(NULL==popen("echo invalid","x")); expect(EINVAL==errno); }
  { const char *home=getenv("HOME"); if(home&&home[0]){ FILE *p=popen("printf %s \"$HOME\"","r"); char buf[512]; expect(p!=NULL); expect(NULL!=fgets(buf,sizeof(buf),p)); expect(0==strcmp(buf,home)); expect(0==pclose(p)); } }
  POSIX_MARK("posix:block:link");
  { struct stat st_src, st_alias; fd=open("posix-link-src.tmp",O_CREAT|O_TRUNC|O_RDWR,0600); expect(fd>=0); expect(4==write(fd,"link",4)); expect(0==close(fd)); expect(0==link("posix-link-src.tmp","posix-link-dst.tmp")); expect(0==stat("posix-link-src.tmp",&st_src)); expect(0==stat("posix-link-dst.tmp",&st_alias)); expect(st_src.st_size==st_alias.st_size); expect(0==unlink("posix-link-dst.tmp")); expect(0==unlink("posix-link-src.tmp")); }
  POSIX_MARK("posix:block:writev");
  { struct iovec outv[2], inv[2]; char a[4]={0}, b[4]={0}; fd=open("posix-writev.tmp",O_CREAT|O_TRUNC|O_RDWR,0600); expect(fd>=0); outv[0].iov_base=(void*)"ab"; outv[0].iov_len=2; outv[1].iov_base=(void*)"cd"; outv[1].iov_len=2; expect(4==writev(fd,outv,2)); expect(0==close(fd)); fd=open("posix-writev.tmp",O_RDONLY); expect(fd>=0); inv[0].iov_base=a; inv[0].iov_len=2; inv[1].iov_base=b; inv[1].iov_len=2; expect(4==readv(fd,inv,2)); expect(0==memcmp(a,"ab",2)); expect(0==memcmp(b,"cd",2)); expect(0==close(fd)); expect(0==unlink("posix-writev.tmp")); }
  { FILE *fa=fopen("posix-dirent-a.tmp","w"); FILE *fb=fopen("posix-dirent-b.tmp","w"); DIR *dir; struct dirent *ent; int sa=0,sb=0; expect(fa&&fb); expect(0==fclose(fa)); expect(0==fclose(fb)); dir=opendir("."); expect(dir!=NULL); while((ent=readdir(dir))!=NULL){ if(strcmp(ent->d_name,"posix-dirent-a.tmp")==0) sa=1; if(strcmp(ent->d_name,"posix-dirent-b.tmp")==0) sb=1; } expect(0==closedir(dir)); expect(sa&&sb); expect(0==unlink("posix-dirent-a.tmp")); expect(0==unlink("posix-dirent-b.tmp")); }
  POSIX_MARK("posix:block:pathconf");
  { FILE *pf=fopen("posix-pathconf.tmp","w"); int pfd; expect(pathconf(".",_PC_LINK_MAX)>0); errno = 0; expect(-1 == pathconf(".", -1)); expect(EINVAL == errno); expect(pf!=NULL); pfd=fileno(pf); expect(fpathconf(pfd,_PC_LINK_MAX)>0); errno = 0; expect(-1 == fpathconf(-1, _PC_LINK_MAX)); expect(errno != 0); errno = 0; expect(-1 == fpathconf(12345, _PC_LINK_MAX)); expect(EBADF == errno); expect(0==fclose(pf)); expect(0==unlink("posix-pathconf.tmp")); }
  { struct itimerval val,old; memset(&val,0,sizeof(val)); memset(&old,0,sizeof(old)); expect(0==setitimer(ITIMER_REAL,&val,&old)); expect(0==setitimer(ITIMER_REAL,&val,NULL)); }
  { struct itimerval val,old; memset(&val,0,sizeof(val)); memset(&old,0,sizeof(old)); errno=0; expect(-1==setitimer(-1,&val,&old)); expect(EINVAL==errno); }
  { struct timeval tv={0,0}; expect(0==select(0,NULL,NULL,NULL,&tv)); }
  { struct timeval tv={0,0}; errno=0; expect(-1==select(-1,NULL,NULL,NULL,&tv)); expect(EINVAL==errno); }
  { struct timespec ts={0,0}; expect(0==pselect(0,NULL,NULL,NULL,&ts,NULL)); }
  { struct timespec ts={0,0}; errno=0; expect(-1==pselect(-1,NULL,NULL,NULL,&ts,NULL)); expect(EINVAL==errno); }
  { struct timeval tv; expect(0==gettimeofday(&tv,NULL)); expect(tv.tv_usec >= 0); expect(tv.tv_usec < 1000000); }
  { struct timespec ts; expect(0==clock_gettime(CLOCK_REALTIME,&ts)); expect(ts.tv_nsec >= 0); expect(ts.tv_nsec < 1000000000L); }
  expect(0==strcasecmp("HeLLo","hEllO")); expect(strcasecmp("abc","abd")<0); expect(strcasecmp("abD","abc")>0);
  { int tty=isatty(STDOUT_FILENO); expect(tty==0 || tty==1); }
  puts("Success!");
  return 0;
}
