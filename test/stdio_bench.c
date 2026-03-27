#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t now_ticks(void)
{
  return (uint64_t)clock();
}

static void prepare_file(const char *path, size_t lines)
{
  static const char line[] =
      "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\n";
  FILE *f = fopen(path, "wb");
  if (f == NULL) {
    perror("fopen");
    exit(1);
  }
  for (size_t i = 0; i < lines; ++i) {
    if (fwrite(line, 1, sizeof(line) - 1, f) != sizeof(line) - 1) {
      perror("fwrite");
      exit(1);
    }
  }
  if (fclose(f) != 0) {
    perror("fclose");
    exit(1);
  }
}

static void bench_getc(const char *path, int passes)
{
  volatile unsigned long long checksum = 0;
  size_t bytes = 0;
  uint64_t start = now_ticks();
  for (int pass = 0; pass < passes; ++pass) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
      perror("fopen");
      exit(1);
    }
    for (;;) {
      int ch = getc(f);
      if (ch == EOF)
        break;
      checksum += (unsigned)ch;
      bytes += 1;
    }
    fclose(f);
  }
  uint64_t elapsed = now_ticks() - start;
  printf("getc ticks=%llu bytes=%zu checksum=%llu\n",
         (unsigned long long)elapsed, bytes, checksum);
}

static void bench_fgets(const char *path, int passes)
{
  volatile unsigned long long checksum = 0;
  size_t bytes = 0;
  uint64_t start = now_ticks();
  for (int pass = 0; pass < passes; ++pass) {
    char buf[128];
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
      perror("fopen");
      exit(1);
    }
    while (fgets(buf, sizeof(buf), f) != NULL) {
      size_t len = strlen(buf);
      checksum += (unsigned char)buf[0];
      bytes += len;
    }
    fclose(f);
  }
  uint64_t elapsed = now_ticks() - start;
  printf("fgets ticks=%llu bytes=%zu checksum=%llu\n",
         (unsigned long long)elapsed, bytes, checksum);
}

static void bench_fread_small(const char *path, int passes)
{
  volatile unsigned long long checksum = 0;
  size_t bytes = 0;
  uint64_t start = now_ticks();
  for (int pass = 0; pass < passes; ++pass) {
    unsigned char buf[64];
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
      perror("fopen");
      exit(1);
    }
    for (;;) {
      size_t n = fread(buf, 1, sizeof(buf), f);
      if (n == 0)
        break;
      checksum += buf[0];
      bytes += n;
    }
    fclose(f);
  }
  uint64_t elapsed = now_ticks() - start;
  printf("fread64 ticks=%llu bytes=%zu checksum=%llu\n",
         (unsigned long long)elapsed, bytes, checksum);
}

int main(void)
{
  const char *path = "stdio-bench.txt";
  const size_t lines = 300000;
  const int passes = 6;

  prepare_file(path, lines);
  bench_getc(path, passes);
  bench_fgets(path, passes);
  bench_fread_small(path, passes);
  remove(path);
  return 0;
}
