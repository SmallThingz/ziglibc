#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include "expect.h"
#define POSIX_MARK(name) do { if (getenv("ZIGLIBC_TEST_MARKERS") != NULL) { fputs(name, stderr); fputc('\n', stderr); fflush(stderr); } } while (0)
int main(void) {
  POSIX_MARK("posix_proc:block:popen");
  { FILE *p=popen("printf popen-ok","r"); char buf[64]; expect(p!=NULL); expect(NULL!=fgets(buf,sizeof(buf),p)); expect(0==strcmp(buf,"popen-ok")); expect(0==pclose(p)); }
  { FILE *p=popen("cat > /dev/null","w"); expect(p!=NULL); expect(fputs("payload\n",p)>=0); expect(0==pclose(p)); }
  { errno=0; expect(NULL==popen("echo invalid","x")); expect(EINVAL==errno); }
  { const char *home=getenv("HOME"); if(home&&home[0]){ FILE *p=popen("printf %s \"$HOME\"","r"); char buf[512]; expect(p!=NULL); expect(NULL!=fgets(buf,sizeof(buf),p)); expect(0==strcmp(buf,home)); expect(0==pclose(p)); } }
  POSIX_MARK("posix_proc:block:timers");
  { struct itimerval val,old; memset(&val,0,sizeof(val)); memset(&old,0,sizeof(old)); expect(0==setitimer(ITIMER_REAL,&val,&old)); expect(0==setitimer(ITIMER_REAL,&val,NULL)); }
  { struct itimerval val,old; memset(&val,0,sizeof(val)); memset(&old,0,sizeof(old)); errno=0; expect(-1==setitimer(-1,&val,&old)); expect(EINVAL==errno); }
  { struct timeval tv={0,0}; expect(0==select(0,NULL,NULL,NULL,&tv)); }
  { struct timeval tv={0,0}; errno=0; expect(-1==select(-1,NULL,NULL,NULL,&tv)); expect(EINVAL==errno); }
  { struct timespec ts={0,0}; expect(0==pselect(0,NULL,NULL,NULL,&ts,NULL)); }
  { struct timespec ts={0,0}; errno=0; expect(-1==pselect(-1,NULL,NULL,NULL,&ts,NULL)); expect(EINVAL==errno); }
  puts("Success!");
  return 0;
}
