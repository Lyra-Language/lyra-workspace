# Linux image for running Lyra's AddressSanitizer suite.
#
# Why this exists: macOS ASan is not a reliable detector for this codebase. It cannot
# see leaks there at all, and — measured three separate times — it stays silent on
# genuine use-after-free and double-free faults that Linux ASan reports immediately
# (a closure-capture double free, a release of an uninitialized alloca on a weak
# upgrade, and a double free at a managed generic type argument). Each was caught only
# by a refcount-count or CFG assertion, or by CI. This image makes the Linux run
# available locally, before pushing.
#
# The base image already carries gcc, which is what CGO uses to compile the
# tree-sitter parser; clang is added because the backend's behavioral tests shell out
# to it to compile emitted LLVM IR. Those are two distinct compilers doing two
# distinct jobs here, and both need to be present.
#
# No Node/npm and no tree-sitter CLI: the grammar's generated src/parser.c is already
# checked out on the host (via git-lfs) and mounted in, so the container only compiles
# it. That also keeps this image clear of the arm64-Linux tree-sitter build quirk,
# where the CLI's cross-compile detection requires CC=gcc.
FROM golang:1.26-bookworm

# libclang-rt-dev is not optional and not implied by `clang`: Debian ships the
# sanitizer runtime archives (libclang_rt.asan-aarch64.a) in a separate package, and
# without them `clang -fsanitize=address` fails at *link* time. The suite treats that as
# "AddressSanitizer not available in this toolchain" and **skips** every ASan test, so
# the run goes green having checked nothing — the exact vacuous pass this image exists to
# rule out. asan.sh preflights the same probe so a regression here is an error, not a skip.
#
# The unversioned metapackage tracks whatever clang version Debian defaults to, so this
# stays correct when the base image moves rather than pinning a version that will rot.
# zlib1g-dev is for `examples/zlib.lyra`, the FFI's **real-library** proof: the vendored C
# fixture shows the ABI is self-consistent across a boundary this project wrote both sides
# of, and only a library nobody wrote for Lyra shows it matching a convention it had to obey
# rather than choose. `-lz` links on macOS without a package and does not here, which is why
# the round-trip test self-skips — and why it must not skip *here*, the one environment
# whose job is to catch what macOS does not.
RUN apt-get update \
    && apt-get install -y --no-install-recommends clang libclang-rt-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# CGO compiles the ~110 MB generated parser.c. gcc is the base image's default and the
# combination known to work on arm64 Linux; stated explicitly so it cannot drift if the
# base image ever changes its default.
ENV CC=gcc
ENV CGO_ENABLED=1

# Caches live inside the container (a named volume, see asan.sh) rather than in the
# mounted source tree, so Linux build artifacts never mix with the host's macOS ones.
# GOCACHE is keyed per-platform anyway, but the backend's compiled-test-binary cache
# under os.UserCacheDir() is not, and sharing that across platforms would serve a Mach-O
# binary to a Linux run.
ENV GOCACHE=/cache/go-build
ENV XDG_CACHE_HOME=/cache

WORKDIR /work/lyra
