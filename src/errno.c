#include <errno.h>

/*
 * Keep errno storage defined from C rather than Zig. Darwin-target C code uses
 * a plain external `_errno` data symbol when built against our headers, and a
 * Zig-exported var proved less reliable at that Mach-O ABI boundary than a
 * normal C definition.
 */
int errno = 0;
