# Lyra Workspace

Development workspace for [Lyra](https://github.com/Lyra-Language), a programming language under active development.

This repo tracks only workspace files — this README, `CLAUDE.md`, `lyra.code-workspace` and the setup scripts. The code lives in five **independent Git repos** (not submodules; nothing pins their commits):

| Directory | Language | Purpose |
|---|---|---|
| [`tree-sitter-lyra/`](https://github.com/Lyra-Language/tree-sitter-lyra) | JavaScript | tree-sitter grammar for Lyra |
| [`lyra/`](https://github.com/Lyra-Language/lyra) | Go | Parser, AST, type system, typechecker, LSP server, compiler CLI |
| [`lyra-vscode-ext/`](https://github.com/Lyra-Language/lyra-vscode-ext) | TypeScript | VS Code extension — launches the LSP server |
| [`lyra-zed-ext/`](https://github.com/Lyra-Language/lyra-zed-ext) | Rust (wasm) | Zed extension — launches the LSP server |
| [`lyra-website/`](https://github.com/Lyra-Language/lyra-website) | Astro | Public site — dev blog and docs/guides |

## Quick start

**macOS / Linux**

```bash
git clone https://github.com/Lyra-Language/lyra-workspace.git
cd lyra-workspace
./setup.sh
```

**Windows (PowerShell)**

```powershell
git clone https://github.com/Lyra-Language/lyra-workspace.git
cd lyra-workspace
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Windows blocks unsigned local scripts by default, hence `-ExecutionPolicy Bypass`. Alternatively, allow scripts for the current session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup.ps1
```

Either way you end up with all five sub-projects side by side.

## Prerequisites

**For the formatter probe** (`lyra/examples/lyrafmt/`): the tree-sitter runtime — macOS: `brew install tree-sitter`; Debian/Ubuntu: `apt install libtree-sitter-dev`. Then `lyra/examples/lyrafmt/libs.sh` builds the grammar archive.

**To clone:** Git — macOS: preinstalled / `brew install git`; Debian/Ubuntu: `apt install git`; Windows: [git-scm.com](https://git-scm.com).

**To build and test:**

| Tool | Why |
|---|---|
| Go 1.25.4+ | building and testing `lyra/` |
| A C compiler (clang/gcc) | the parser is CGO; the LLVM backend tests compile and run real binaries |
| Node.js 22.12+ | `tree-sitter-lyra/` and `lyra-website/` (Astro 7 requires ≥ 22.12) |
| `rustup` | `lyra-zed-ext/` — Zed builds it to wasm and adds `wasm32-wasip1` itself |

Git LFS is **not** required; only checking out a historical commit of `tree-sitter-lyra` (from when `src/parser.c` lived in LFS) needs it.

## Running setup

Both scripts are idempotent: they clone what's missing, fetch what exists, and exit non-zero if any repo had a problem.

| macOS / Linux | Windows | What it does |
|---|---|---|
| `./setup.sh` | `.\setup.ps1` | Clone missing repos, fetch existing ones, report status |
| `./setup.sh --pull` | `.\setup.ps1 -Pull` | Also fast-forward each repo to its upstream |
| `./setup.sh --https` | `.\setup.ps1 -Https` | Clone over `https://` instead of `git@` (no SSH key needed) |
| `./setup.sh --help` | `Get-Help .\setup.ps1` | Usage |

- Flags combine: `./setup.sh --pull --https`.
- `--https` affects **new clones only**; switch an existing repo with `git -C <repo> remote set-url origin …`.
- `--pull` fast-forwards only a clean repo with no local commits. Dirty or diverged repos are reported and left untouched — never merged, rebased, stashed or reset.

## Verifying the workspace

```bash
cd lyra
go build ./...
go test ./...
```

Then open `lyra.code-workspace` in VS Code. Its `lyra.languageServerPath` is `${workspaceFolder}/build/lyra-lsp` (what `lyra/build.sh` produces); remove it to use `lyra-lsp` from your `PATH`.

## Troubleshooting

- **Clone fails with a permission/authentication error** — the scripts default to SSH. Without a GitHub SSH key, use `./setup.sh --https`.
- **`.\setup.ps1` is "not digitally signed"** — the execution policy; use `powershell -ExecutionPolicy Bypass -File .\setup.ps1`.
- **"directory exists but is not a Git repo"** — something non-clone is at that path. Move it aside and re-run.
- **A repo shows "ahead"/"behind" and won't update** — `--pull` protecting your work. Resolve it in that repo (commit, stash, push or merge), then re-run.
- **`tree-sitter-lyra` `npm run test`/`build` can't find `aarch64-linux-gnu-gcc`** (ARM64 Linux only) — the prebuilt tree-sitter CLI thinks it is cross-compiling. Set `CC` explicitly (add `export CC=gcc` to your profile to persist):

  ```bash
  CC=gcc npm run test
  ```
- **The parser compile is killed partway** — `src/parser.c` is ~15 MB and `cc1` needs real memory; on a small VM that's an OOM kill. Add RAM or swap.

## Working on Lyra

Each sub-project has its own `README.md` and `CLAUDE.md`. Start with [`lyra/`](https://github.com/Lyra-Language/lyra).

After editing `tree-sitter-lyra/grammar.js`, regenerate the parser **and** clear Go's build cache (Go doesn't hash the `#include`d `parser.c`), or tests silently run against the old grammar:

```bash
cd tree-sitter-lyra && npx tree-sitter generate
cd ../lyra && go clean -cache && go test ./...
```

## Running the suite on Linux

`./asan.sh` runs the tests in a Debian container. Needs Docker; it mounts the repos and builds its image on first use.

```bash
./asan.sh              # the AddressSanitizer suite
./asan.sh ./...        # the whole suite, on Linux
./asan.sh --shell      # shell inside the container
```

Run it before pushing memory-model changes: it catches memory faults and invalid LLVM IR that macOS's clang cannot diagnose (Debian's clang still uses typed pointers). See `CLAUDE.md` for details.
