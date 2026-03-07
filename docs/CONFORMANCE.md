# Conformance

`zig build conformance` is a meta-step that runs the supported external conformance suites for the selected target.

## Included Suites

- `libc-test`
- `tiny-regex-c` regression tests
- `glibc-testsuite` checks when targeting GNU libc
- `open_posix_testsuite` checks on POSIX targets
- Austin Group `strftime` coverage on POSIX targets

## Source Management

These suites are checked into the repository as git submodules under `dep/`. They are not cloned dynamically by the build anymore.

Initialize them with:

```sh
git submodule update --init --recursive
```

This avoids build-graph races where Zig tries to hash test sources before a fetch step has materialized them, and it removes repeated CI clone cost.

## Platform Matrix

Validated paths:

- Linux native
- `x86_64-macos` through `darling` on Linux
- `x86_64-windows-gnu` through `wineconsole` on Linux

Additional compile-only validation:

- `aarch64-macos`

## Commands

```sh
zig build conformance
zig build conformance -Dtarget=x86_64-macos
zig build conformance -Dtarget=x86_64-windows-gnu
```
