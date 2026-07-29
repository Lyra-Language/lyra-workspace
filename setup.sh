#!/usr/bin/env bash
#
# Bootstrap the Lyra workspace: clone (or refresh) the four sub-project repos.
#
# The sub-projects are independent Git repos and are NOT tracked by the
# workspace repo (see .gitignore). This script reconstitutes the full tree
# from a bare clone of lyra-workspace.
#
#   ./setup.sh              clone anything missing, fetch what's already there
#   ./setup.sh --pull       also fast-forward each repo to its upstream
#   ./setup.sh --https      use https:// remotes instead of git@ (no SSH key)
#
# Works on macOS (bash 3.2) and Linux. Windows: use setup.ps1.

set -euo pipefail

ORG_SSH="git@github.com:Lyra-Language"
ORG_HTTPS="https://github.com/Lyra-Language"

# Sub-projects, in dependency order (grammar first — the Go module replaces
# into ../tree-sitter-lyra).
REPOS="tree-sitter-lyra lyra lyra-vscode-ext lyra-website"

# Repos storing files in Git LFS. Cloning these without git-lfs installed
# silently leaves pointer files behind instead of real content.
LFS_REPOS="tree-sitter-lyra"

USE_HTTPS=0
DO_PULL=0

usage() {
	cat <<'EOF'
Bootstrap the Lyra workspace: clone (or refresh) the four sub-project repos.

The sub-projects are independent Git repos and are NOT tracked by the
workspace repo (see .gitignore). This script reconstitutes the full tree
from a bare clone of lyra-workspace.

  ./setup.sh              clone anything missing, fetch what's already there
  ./setup.sh --pull       also fast-forward each repo to its upstream
  ./setup.sh --https      use https:// remotes instead of git@ (no SSH key)

Works on macOS (bash 3.2) and Linux. Windows: use setup.ps1.
EOF
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--https) USE_HTTPS=1 ;;
		--pull) DO_PULL=1 ;;
		-h|--help) usage 0 ;;
		*) printf 'unknown option: %s\n\n' "$1" >&2; usage 1 ;;
	esac
	shift
done

# --- output helpers -------------------------------------------------------

if [ -t 1 ]; then
	C_RESET=$(printf '\033[0m')
	C_BOLD=$(printf '\033[1m')
	C_DIM=$(printf '\033[2m')
	C_RED=$(printf '\033[31m')
	C_GREEN=$(printf '\033[32m')
	C_YELLOW=$(printf '\033[33m')
else
	C_RESET= C_BOLD= C_DIM= C_RED= C_GREEN= C_YELLOW=
fi

info()  { printf '%s\n' "$*"; }
ok()    { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
note()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

FAILED=""
fail() { err "$2"; FAILED="$FAILED $1"; }

contains_word() {
	# contains_word <needle> <space-separated haystack>
	case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# --- preflight ------------------------------------------------------------

cd "$(dirname "$0")"
WORKSPACE=$(pwd)

command -v git >/dev/null 2>&1 || {
	printf 'git is required but was not found on PATH.\n' >&2
	exit 1
}

HAVE_LFS=0
if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
	HAVE_LFS=1
fi

if [ "$USE_HTTPS" -eq 1 ]; then
	BASE="$ORG_HTTPS"
else
	BASE="$ORG_SSH"
fi

info "${C_BOLD}Lyra workspace${C_RESET} — $WORKSPACE"
info "remote base: $BASE"
if [ "$HAVE_LFS" -eq 0 ]; then
	warn "git-lfs not installed — required by: $LFS_REPOS"
	note "brew install git-lfs  /  apt install git-lfs   then: git lfs install"
fi
info ""

# --- per-repo work --------------------------------------------------------

is_repo_root() {
	# True when $1 is the top level of its own working tree (not merely inside
	# the workspace repo).
	top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
	[ "$top" = "$(cd "$1" && pwd)" ]
}

clone_repo() {
	name=$1
	url="$BASE/$name.git"
	info "${C_BOLD}$name${C_RESET} ${C_DIM}(cloning)${C_RESET}"

	# git-lfs is a hard prerequisite here, not a nicety: the repo's
	# .gitattributes routes src/parser.c through the lfs filter, so git invokes
	# git-lfs during checkout and the clone dies mid-checkout without it.
	if contains_word "$name" "$LFS_REPOS" && [ "$HAVE_LFS" -eq 0 ]; then
		fail "$name" "skipped — git-lfs is required to clone this repo"
		note "install git-lfs, run 'git lfs install', then re-run this script"
		return
	fi

	if git clone --quiet "$url" "$name"; then
		ok "cloned from $url"
		return
	fi

	# A failed clone can leave a partial directory behind (e.g. cloned but
	# checkout failed). Remove it so a re-run retries cleanly instead of
	# treating the wreckage as an existing repo.
	if [ -d "$name" ]; then
		rm -rf "$name"
		note "removed partial clone"
	fi
	fail "$name" "clone failed: $url"
	if [ "$USE_HTTPS" -eq 0 ]; then
		note "no SSH key for GitHub? re-run with --https"
	fi
}

refresh_repo() {
	name=$1
	branch=$(git -C "$name" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
	info "${C_BOLD}$name${C_RESET} ${C_DIM}(on $branch)${C_RESET}"

	if ! git -C "$name" fetch --quiet --prune 2>/dev/null; then
		fail "$name" "fetch failed"
		return
	fi

	dirty=""
	[ -n "$(git -C "$name" status --porcelain 2>/dev/null)" ] && dirty=" (working tree dirty)"

	if ! upstream=$(git -C "$name" rev-parse --abbrev-ref '@{u}' 2>/dev/null); then
		warn "no upstream for $branch — fetched only$dirty"
		return
	fi

	set -- $(git -C "$name" rev-list --left-right --count "$upstream...HEAD" 2>/dev/null || echo "0 0")
	behind=${1:-0}
	ahead=${2:-0}

	if [ "$behind" = "0" ] && [ "$ahead" = "0" ]; then
		ok "up to date with $upstream$dirty"
		return
	fi

	if [ "$DO_PULL" -eq 1 ] && [ "$behind" != "0" ] && [ "$ahead" = "0" ] && [ -z "$dirty" ]; then
		if git -C "$name" merge --quiet --ff-only "$upstream"; then
			ok "fast-forwarded $behind commit(s) from $upstream"
		else
			fail "$name" "fast-forward failed"
		fi
		return
	fi

	msg="$ahead ahead, $behind behind $upstream$dirty"
	if [ "$DO_PULL" -eq 1 ]; then
		warn "$msg — not fast-forwardable, left alone"
	else
		warn "$msg"
		[ "$behind" != "0" ] && note "run with --pull to fast-forward"
	fi
}

for name in $REPOS; do
	if [ ! -e "$name" ]; then
		clone_repo "$name"
	elif [ ! -d "$name" ]; then
		info "${C_BOLD}$name${C_RESET}"
		fail "$name" "exists but is not a directory"
	elif is_repo_root "$name"; then
		refresh_repo "$name"
	else
		info "${C_BOLD}$name${C_RESET}"
		fail "$name" "directory exists but is not a Git repo — move it aside and re-run"
	fi
	info ""
done

# --- summary --------------------------------------------------------------

if [ -n "$FAILED" ]; then
	err "problems with:$FAILED"
	exit 1
fi

info "${C_GREEN}Workspace ready.${C_RESET}"
info "${C_DIM}Next: cd lyra && go test ./...${C_RESET}"
