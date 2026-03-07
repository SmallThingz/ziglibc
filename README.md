# ziglibc

`ziglibc` is an experimental libc implementation in Zig covering the C standard library plus a growing POSIX surface.

## Status

- Builds with Zig `0.15.2`.
- `zig build test` passes on:
  - Linux native
  - macOS targets executed through `darling`
  - Windows GNU targets executed through `wineconsole`
- `zig build conformance` passes on the same matrix.
- The in-tree parity runner compares ziglibc and the platform libc for the validated matrix on:
  - process execution (`system`, `popen`, `pclose`)
  - signal/sigaction basics
  - `strtol`/`strtod` no-digit behavior
  - `setitimer`, `select`, `pselect`, and `utimes` where the platform libc exposes them

## Repository Setup

Conformance sources are tracked as git submodules. Initialize them before running the test or conformance steps:

```sh
git submodule update --init --recursive
```

The conformance-related submodules live under `dep/`:

- `dep/libc-test`
- `dep/tiny-regex-c`
- `dep/open_posix_testsuite`
- `dep/glibc-testsuite`

## Building

Build the default install artifacts with:

```sh
zig build
```

Run the project test suite with:

```sh
zig build test
```

Run the conformance suite bundle with:

```sh
zig build conformance
```

Useful individual steps:

```sh
zig build libc-test
zig build glibc-check
zig build posix-test-suite
zig build austin-group-tests
zig build re-tests
```

## Cross-Platform Validation

On a Linux host, the build uses external runners for foreign test execution:

- Darwin targets: `darling`
- Windows GNU targets: `wineconsole`

Examples:

```sh
zig build test -Dtarget=x86_64-macos
zig build conformance -Dtarget=x86_64-macos

zig build test -Dtarget=x86_64-windows-gnu
zig build conformance -Dtarget=x86_64-windows-gnu
```

`aarch64-macos` is also kept compiling in CI:

```sh
zig build -Dtarget=aarch64-macos
```

## Using ziglibc

After `zig build`, point `zig cc` at the generated headers and libraries:

```sh
zig cc \
    -nostdlib \
    -I PATH_TO_ZIGLIBC_SRC/inc/libc \
    -I PATH_TO_ZIGLIBC_SRC/inc/posix \
    -I PATH_TO_ZIGLIBC_SRC/inc/linux \
    -L PATH_TO_ZIGLIBC_INSTALL/lib \
    -lstart \
    -lc
```

## Notes

- The validated Linux/macOS/Windows matrix is green for both `test` and `conformance`.
- Remaining `ENOSYS` paths are scoped to unsupported targets or unsupported OS-specific features outside that matrix.
- The build will fail fast if required submodules are missing rather than cloning repositories during `zig build`.
