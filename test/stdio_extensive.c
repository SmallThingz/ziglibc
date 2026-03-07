#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "expect.h"

static int write_with_vfprintf(FILE *stream, const char *fmt, ...)
{
  va_list ap;
  int ret;
  va_start(ap, fmt);
  ret = vfprintf(stream, fmt, ap);
  va_end(ap);
  return ret;
}

int main(int argc, char *argv[])
{
  (void)argc;
  (void)argv;

  const char *path = "stdio-extensive.txt";
  FILE *f = fopen64(path, "w");
  expect(f != NULL);
  expect(5 == fprintf(f, "hello"));
  expect(4 == write_with_vfprintf(f, " %s", "zig"));
  expect(3 == fwrite("abc", 1, 3, f));
  expect(0 == fwrite("drop", 0, 4, f));
  expect(0 == fwrite("drop", 4, 0, f));
#ifndef _WIN32
  expect('!' == fputc('!', f));
#endif
  expect(0 == fclose(f));

  f = fopen(path, "r");
  expect(f != NULL);
  expect('h' == fgetc(f));
  expect('h' == ungetc('h', f));
  expect('h' == fgetc(f));
  expect(EOF == ungetc(EOF, f));
  expect(0 == fseek(f, 0, SEEK_SET));
  {
    char buf[64];
    const size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    buf[n] = 0;
#ifdef _WIN32
    expect(0 == strcmp("hello zigabc", buf));
#else
    expect(0 == strcmp("hello zigabc!", buf));
#endif
  }
  expect(0 == fclose(f));

  {
    FILE *plus = fopen("stdio-plus.txt", "w+");
    char buf[8];
    fpos_t pos;
    expect(plus != NULL);
    expect(3 == fwrite("xyz", 1, 3, plus));
    expect(0 == fgetpos(plus, &pos));
    expect(0 == fseek(plus, 0, SEEK_SET));
    expect(3 == fread(buf, 1, 3, plus));
    buf[3] = 0;
    expect(0 == strcmp("xyz", buf));
    expect(0 == fsetpos(plus, &pos));
    expect(1 == fwrite("!", 1, 1, plus));
    expect(plus == freopen("stdio-plus.txt", "r", plus));
    expect('x' == fgetc(plus));
    expect(0 == fclose(plus));
  }

  {
    char buf[8];
    FILE *g = fopen("stdio-gets.txt", "w");
    expect(g != NULL);
    setbuf(g, NULL);
    expect(3 == fwrite("hi\n", 1, 3, g));
    expect(0 == fclose(g));
    expect(stdin == freopen("stdio-gets.txt", "r", stdin));
    expect(buf == gets(buf));
    expect(0 == strcmp("hi", buf));
    expect(0 == remove("stdio-gets.txt"));
  }

  {
    FILE *odd = fopen("stdio-odd.txt", "w+");
    char pair[4];
    expect(odd != NULL);
    expect(3 == fwrite("abc", 1, 3, odd));
    expect(0 == fseek(odd, 0, SEEK_SET));
    expect(1 == fread(pair, 2, 2, odd));
    expect(pair[0] == 'a');
    expect(pair[1] == 'b');
    expect(1 == fread(pair, 1, 1, odd));
    expect(pair[0] == 'c');
    expect(0 == fclose(odd));
  }

  {
    char tmp_name[L_tmpnam];
    expect(tmpnam(tmp_name) == tmp_name);
    expect(tmp_name[0] != 0);
  }

  {
    FILE *tf = tmpfile();
    char buf[4];
    expect(tf != NULL);
    expect(3 == fwrite("abc", 1, 3, tf));
    expect(0 == fseek(tf, 0, SEEK_SET));
    expect(3 == fread(buf, 1, 3, tf));
    buf[3] = 0;
    expect(0 == strcmp("abc", buf));
    expect(0 == fclose(tf));
  }

  puts("Success!");
  return 0;
}
