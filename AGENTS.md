# AI Agent Instructions

## Build & Test

- **Build**: `make all` - builds binary + man page from README.md
- **Fast test**: `make check-fast` - unit tests + fast subset of `tests/test.py`
- **Full test**: `make check` - includes large file generation and tests
- **Format check**: `make check-format` - clang-format with Chromium + `InsertBraces: true`
- **Debug build**: `DEBUG=1 make check-fast` - enables ASAN with `-O0 -g`
- **Coverage**: `make coverage` - HTML report at `out/coverage/index.html`

## C++ Standard & Toolchain

- **C++23** by default (`CXXSTD=20` for older compilers)
- **FUSE 3** by default; set `FUSE_MAJOR_VERSION=2` for FUSE 2
- Requires: `libarchive`, `fuse3`/`fuse`, `gtest` (unit tests)
- On macOS: Homebrew paths auto-detected via `brew --prefix`
- Always builds with `-D_FILE_OFFSET_BITS=64 -D_TIME_BITS=64`

## Release Workflow

1. Even minor versions are stable releases; odd minors are development
2. **Command**: `make release [VERSION=X.Y]`
    - Bumps version in `fuse-archive.cc`, `README.md`, `DEVELOPMENT.md`
    - Regenerates man page via `make doc`
    - Creates git tag `vX.Y`, auto-bumps to next development version
3. **Manual step**: Run `git push origin main --tags` after release

## Architecture

- **Core library**: `lib/` - header-only; key headers: `common.h`, `reader.h`, `tree.h`
- **CLI wrapper**: `fuse-archive.cc` (~598 lines) - minimal business logic
- **Key RAII helpers**:
    - `FileDescriptor` - manages file descriptors
    - `Cleanup` - runs lambda in destructor (tempfile/mount cleanup)
- **Shutdown**: ASAN builds use explicit teardown wrapped in `Cleanup`; production builds skip for speed

## Code Style

- **Format**: clang-format (`.clang-format`: Chromium + `InsertBraces: true`)
- **Memory safety**: ASAN-compliant; use RAII for all resources
- **32-bit**: `-D_TIME_BITS=64` (Makefile handles this)
- **Error codes**: `ExitCode` enum in `lib/common.h`

## Testing

- **Test runner**: `tests/test.py` (~2961 lines)
- **Test data**: Pre-generated in `tests/data/` (big.zip, collisions.zip, deep.tar, many_nodes.zip)
- **Platform quirks**:
    - macOS: skip memcache tests, skip xattr tests, different device encoding
    - FUSE 2 vs 3: controlled via `FUSE_MAJOR_VERSION` Makefile variable
    - Use `--fast` flag to skip large file tests

## Manual Pages

- **Source**: `README.md` serves as user documentation
- **Generate**: `make doc` - pandoc + sed post-processing
- **Requirement**: Bulleted lists in README.md must be preceded by blank line
