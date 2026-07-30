# Lyra Workspace

Development workspace for [Lyra](https://github.com/Lyra-Language), a programming language under active development.

This repository is intentionally thin. It tracks only the workspace-level files — this README, `CLAUDE.md`, `lyra.code-workspace`, and the two setup scripts. The actual code lives in four **independent Git repos** that this repo does *not* track:

| Directory | Language | Purpose |
|---|---|---|
| [`tree-sitter-lyra/`](https://github.com/Lyra-Language/tree-sitter-lyra) | JavaScript | tree-sitter grammar for Lyra |
| [`lyra/`](https://github.com/Lyra-Language/lyra) | Go | Parser, AST, type system, typechecker, LSP server, compiler CLI |
| [`lyra-vscode-ext/`](https://github.com/Lyra-Language/lyra-vscode-ext) | TypeScript | VS Code extension — launches the LSP server |
| [`lyra-website/`](https://github.com/Lyra-Language/lyra-website) | Astro | Public site — dev blog and docs/guides |

They are **not** submodules — nothing here pins their commits, so each moves independently. A fresh clone of this repo gets the docs but none of the code; `setup.sh` / `setup.ps1` fetch the rest.

## Quick start

### macOS / Linux

```bash
git clone https://github.com/Lyra-Language/lyra-workspace.git
cd lyra-workspace
./setup.sh
```

### Windows (PowerShell)

```powershell
git clone https://github.com/Lyra-Language/lyra-workspace.git
cd lyra-workspace
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

The `-ExecutionPolicy Bypass` is needed because Windows blocks unsigned local scripts by default. To avoid typing it every time, allow scripts for the current session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup.ps1
```

After either, you should have all four sub-projects checked out beside each other.

## Prerequisites

**Required before running setup:**

| Tool | Why | macOS | Linux (Debian/Ubuntu) | Windows |
|---|---|---|---|---|
| Git | Everything | preinstalled / `brew install git` | `apt install git` | [git-scm.com](https://git-scm.com) |
| **Git LFS** | **`tree-sitter-lyra` will not clone without it** | `brew install git-lfs` | `apt install git-lfs` | `winget install GitHub.GitLFS` |

After installing Git LFS, run this once per machine:

```bash
git lfs install
```

**Needed to build and test, not to clone:**

| Tool | Why |
|---|---|
| Go 1.25.4+ | building and testing `lyra/` |
| A C compiler (clang/gcc) | the parser is CGO; the LLVM backend tests compile and run real binaries |
| Node.js 22.12+ | `tree-sitter-lyra/` and `lyra-website/` (Astro 7 requires ≥ 22.12) |

## Running setup

Both scripts are idempotent — run them as often as you like. They clone whatever is missing and fetch whatever is already there.

| macOS / Linux | Windows | What it does |
|---|---|---|
| `./setup.sh` | `.\setup.ps1` | Clone missing repos, fetch existing ones, report status |
| `./setup.sh --pull` | `.\setup.ps1 -Pull` | Also fast-forward each repo to its upstream |
| `./setup.sh --https` | `.\setup.ps1 -Https` | Clone over `https://` instead of `git@` (no SSH key needed) |
| `./setup.sh --help` | `Get-Help .\setup.ps1` | Usage |

Flags combine: `./setup.sh --pull --https`.

`--https` / `-Https` applies to **new clones only** — a repo you already have keeps whatever remote it is configured with. To switch an existing one, change it yourself with `git -C <repo> remote set-url origin …`.

**`--pull` is deliberately conservative.** It fast-forwards only a repo that is clean and has no local commits. A repo with uncommitted changes, or one that has diverged from its upstream, is reported and left completely untouched — the scripts never merge, rebase, stash, or reset your work.

Typical output:

```
Lyra workspace — /home/you/lyra-workspace
remote base: git@github.com:Lyra-Language

tree-sitter-lyra (on main)
  ✓ up to date with origin/main

lyra (on main)
  ! 0 ahead, 3 behind origin/main
    run with --pull to fast-forward
...
```

The scripts exit non-zero if any repo had a problem, so they are safe to use in automation.

## Verifying the workspace

```bash
cd lyra
go build ./...
go test ./...
```

Then open `lyra.code-workspace` in VS Code to get all four projects in one window.

> Note: `lyra.code-workspace` contains a `lyra.languageServerPath` pointing at a local `lyra-lsp` binary. Change it to wherever you install yours, or remove it to fall back to `lyra-lsp` on your `PATH`.

## Troubleshooting

**"git-lfs is required to clone this repo"** — `tree-sitter-lyra` stores its generated `src/parser.c` (~115 MB) in Git LFS. Without `git-lfs` on your `PATH`, Git invokes it partway through checkout and the clone dies, leaving a broken repo. The scripts detect this and skip that repo rather than leave wreckage. Install Git LFS, run `git lfs install`, then re-run setup.

**Clone fails with a permission or authentication error** — the scripts default to SSH (`git@github.com:…`). If you have no SSH key set up for GitHub, use HTTPS instead:

```bash
./setup.sh --https
```

**`.\setup.ps1` is "not digitally signed"** — that's the Windows execution policy. Use `powershell -ExecutionPolicy Bypass -File .\setup.ps1`, as in the quick start above.

**"directory exists but is not a Git repo"** — something is sitting at that path that isn't a clone (a leftover folder, a partial download). Move it aside and re-run.

**A repo shows as "ahead"/"behind" and won't update** — that is `--pull` refusing to touch work you might lose. Resolve it yourself in that repo (commit, stash, push, or merge), then re-run.

**`npm run test` / `npm run build` in `tree-sitter-lyra` can't find `aarch64-linux-gnu-gcc`** — on ARM64 Linux only. Nothing is wrong with the grammar. The tree-sitter CLI compiles `src/parser.c` + `src/scanner.c` on the fly using Rust's `cc` crate, and the prebuilt `linux-arm64` CLI binary was itself cross-compiled, so its baked-in host triple differs from its target triple. `cc` reads that as cross-compilation and prefixes the compiler name with the target triple, looking for a cross-toolchain you don't have. Set `CC` explicitly — `cc` uses a plain `CC` verbatim and skips the prefixing:

```bash
CC=gcc npm run test
```

Add `export CC=gcc` to your shell profile to make it stick. (Symlinking `gcc` to the prefixed name, or installing the real cross toolchain, work too — the env var is just the cheapest.)

**The parser compile gets killed partway through** — `src/parser.c` is ~115 MB, and `cc1` wants real memory to chew through it. On a small VM this shows up as an OOM kill rather than a compiler error. Give the VM more RAM or add swap.

## Working on Lyra

Each sub-project has its own `README.md` and `CLAUDE.md` with detailed build, test, and architecture notes. Start with [`lyra/`](https://github.com/Lyra-Language/lyra).

One cross-project gotcha worth knowing up front: after editing `tree-sitter-lyra/grammar.js` you must regenerate the parser **and** clear Go's build cache, or tests will silently run against the old grammar. Note the two steps run in different directories:

```bash
cd tree-sitter-lyra && npx tree-sitter generate
cd ../lyra && go clean -cache && go test ./...
```

The cache step is not optional: the Go binding pulls the grammar in via `#include "../../src/parser.c"`, and Go's build cache does not hash `#include`d files — so a regenerated parser does not invalidate the compiled object on its own.

## Running the suite on Linux

`./asan.sh` runs the tests in a Debian container. Needs Docker running; nothing else to set up (it mounts the two repos and builds its own image on first use).

```bash
./asan.sh              # the AddressSanitizer suite
./asan.sh ./...        # the whole suite, on Linux
./asan.sh --shell      # poke around inside the container
```

Worth doing before pushing anything that touches the memory model. It catches real memory faults, and also invalid LLVM IR that the newer clang on macOS cannot diagnose at all — Debian's clang still uses typed pointers, so it rejects function-type mismatches that opaque pointers render invisible.

`CLAUDE.md` in this directory explains why, along with the rest of the workspace-level context.
