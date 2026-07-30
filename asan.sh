#!/usr/bin/env bash
#
# Run Lyra's test suite under Linux, where AddressSanitizer actually works.
#
# macOS ASan is not a reliable detector for this codebase: it cannot see leaks there,
# and it has stayed silent three separate times on genuine use-after-free / double-free
# faults that Linux ASan reports immediately. Treat a green macOS ASan run as
# confirming-only, never as clearing — and run this before pushing memory-model work.
#
#   ./asan.sh                    # the ASan suite (pkg/backend/llvm)
#   ./asan.sh ./...              # the whole test suite, on Linux
#   ./asan.sh -run TestExec_Weak ./pkg/backend/llvm/
#   ./asan.sh --shell            # interactive shell in the container
#   ./asan.sh --rebuild          # force a rebuild of the image
#   LEAKS=1 ./asan.sh            # also enable LeakSanitizer (see below)
#
# Leak detection is OFF by default. Linux ASan enables LeakSanitizer automatically,
# but the ownership model still leaks *deliberately* in documented places (a managed
# target reached through a borrowed root, break/continue edges in older paths), so
# leaving it on would fail the suite for known-accepted behavior and bury the faults
# this script exists to surface. LEAKS=1 opts in when you are specifically hunting
# leaks; expect known noise.
set -euo pipefail

readonly IMAGE=lyra-asan
readonly VOLUME=lyra-asan-cache
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'asan.sh: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable — start Docker Desktop and retry"

# Both repos are needed, not just lyra: the Go module reaches the grammar through a
# `replace` directive pointing at ../tree-sitter-lyra, so a container that mounts only
# lyra cannot resolve its own dependency.
[[ -d "$ROOT/lyra" ]] || die "no lyra/ next to this script — run ./setup.sh first"
[[ -d "$ROOT/tree-sitter-lyra" ]] || die "no tree-sitter-lyra/ next to this script — run ./setup.sh first"

# The generated parser is a git-lfs object. If LFS never ran, the file on disk is a
# ~130-byte pointer stub rather than the real ~110 MB source, and CGO fails deep inside
# the build with a confusing error about missing symbols. Check it here instead.
readonly PARSER="$ROOT/tree-sitter-lyra/src/parser.c"
[[ -f "$PARSER" ]] || die "missing $PARSER — run ./setup.sh"
if head -c 45 "$PARSER" | grep -q 'git-lfs.github.com/spec'; then
  die "$PARSER is an unfetched git-lfs pointer, not the generated parser.
    Install git-lfs and run: git -C '$ROOT/tree-sitter-lyra' lfs pull"
fi

rebuild=0
shell=0
args=()
for arg in "$@"; do
  case "$arg" in
    --rebuild) rebuild=1 ;;
    --shell)   shell=1 ;;
    *)         args+=("$arg") ;;
  esac
done

# Default target: the package every ASan test lives in. Passing your own arguments
# overrides it entirely, so `./asan.sh ./...` runs the whole suite on Linux.
if [[ ${#args[@]} -eq 0 ]]; then
  args=(./pkg/backend/llvm/)
fi

if [[ $rebuild -eq 1 ]] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  printf 'asan.sh: building %s ...\n' "$IMAGE" >&2
  docker build -q -t "$IMAGE" -f "$ROOT/asan.Dockerfile" "$ROOT" >/dev/null
fi

docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null

# Invalidate the container's Go build cache when the generated parser changes.
#
# This is the workspace's documented build-cache hazard, and this script walked
# straight into it: the CGO binding pulls the grammar in with
# `#include "../../src/parser.c"`, and Go's build cache hashes the .go files and tracked
# cgo sources but *not* files reached by #include. So a regenerated parser does not
# invalidate the compiled-parser object sitting in the cache volume, and the suite runs
# against the old grammar — silently, and only in the container, which reads as a
# platform difference rather than a stale build. (It cost a confusing round of
# "Linux fails where macOS passes" when `pub` became a labelled grammar field.)
#
# Keyed on size+mtime rather than a content hash: regeneration always changes both, and
# hashing 110 MB on every run to catch a case that cannot occur is not worth the wait.
# A false positive only costs one rebuild; a false negative is the bug above.
parser_stamp() {
  if stat -f '%z-%m' "$PARSER" 2>/dev/null; then return; fi
  stat -c '%s-%Y' "$PARSER" 2>/dev/null || echo unknown
}
readonly STAMP_FILE=/cache/.parser-stamp
readonly PARSER_STAMP="$(parser_stamp)"
if [[ "$(docker run --rm -v "$VOLUME:/cache" "$IMAGE" cat "$STAMP_FILE" 2>/dev/null || true)" != "$PARSER_STAMP" ]]; then
  printf 'asan.sh: grammar changed — clearing the container Go cache\n' >&2
  docker run --rm -v "$VOLUME:/cache" "$IMAGE" \
    bash -c "go clean -cache && printf '%s' '$PARSER_STAMP' > $STAMP_FILE" >/dev/null
fi

# Preflight: prove ASan actually links and runs before handing off to `go test`.
#
# This is the whole point of the script, and it is silently skippable — the suite gates
# every ASan test behind an `asanAvailable` probe and *skips* when it fails, so a
# toolchain missing the sanitizer runtime produces a green run that verified nothing.
# That already happened once here: Debian's `clang` package does not pull in
# libclang-rt-dev, so the first build of this image skipped all 30-odd ASan tests and
# reported ok. Checking the same thing the suite checks, and failing hard, is what keeps
# a green result meaningful.
if ! docker run --rm "$IMAGE" bash -c \
    'printf "int main(void){return 0;}" > /tmp/probe.c \
     && clang -fsanitize=address /tmp/probe.c -o /tmp/probe \
     && ASAN_OPTIONS=detect_leaks=0 /tmp/probe' >/dev/null 2>&1; then
  die "AddressSanitizer does not work in the image, so every ASan test would silently
    SKIP and the run would pass having checked nothing. Rebuild with: ./asan.sh --rebuild
    (if that fails, the image is missing libclang-rt-dev — see asan.Dockerfile)"
fi

asan_options='abort_on_error=1'
if [[ "${LEAKS:-0}" == 1 ]]; then
  asan_options="$asan_options:detect_leaks=1"
else
  asan_options="$asan_options:detect_leaks=0"
fi

# The source tree is mounted READ-ONLY. Nothing in the suite writes to it (the golden
# tests only rewrite files under UPDATE_GOLDEN=1, and the backend's compiled-binary
# cache lives under XDG_CACHE_HOME), so read-only costs nothing and guarantees a Linux
# run cannot leave Linux artifacts in the working tree you are about to commit.
#
# The host module cache is mounted read-only too — module contents are plain source and
# platform-independent, so sharing it skips re-downloading every dependency, while
# read-only keeps the container from writing into the host's GOPATH.
mounts=(
  -v "$ROOT/lyra:/work/lyra:ro"
  -v "$ROOT/tree-sitter-lyra:/work/tree-sitter-lyra:ro"
  -v "$VOLUME:/cache"
)
if modcache="$(cd "$ROOT/lyra" && go env GOMODCACHE 2>/dev/null)" && [[ -d "$modcache" ]]; then
  mounts+=(-v "$modcache:/go/pkg/mod:ro")
fi

# The expansions below are guarded (${arr[@]+...}) rather than plain: macOS ships bash
# 3.2, where expanding an empty array under `set -u` is an "unbound variable" error.
tty=()
if [[ -t 0 && -t 1 ]]; then tty=(-t); fi

if [[ $shell -eq 1 ]]; then
  exec docker run --rm -i ${tty[@]+"${tty[@]}"} "${mounts[@]}" \
    -e "ASAN_OPTIONS=$asan_options" "$IMAGE" bash
fi

printf 'asan.sh: linux/%s, ASAN_OPTIONS=%s\n' "$(uname -m)" "$asan_options" >&2
exec docker run --rm -i ${tty[@]+"${tty[@]}"} "${mounts[@]}" \
  -e "ASAN_OPTIONS=$asan_options" \
  "$IMAGE" go test "${args[@]}"
