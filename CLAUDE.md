# Lyra — Project Context

Lyra is a programming language under active development. This workspace holds five sub-projects: grammar, compiler, two editor extensions, and the public website.

## Working Agreements

- **Commit directly to `main`.** No feature branches (single-developer workspace). Commit only when asked.
- **Lyra sources read top-down.** `main` at the top, the functions it calls below in rough order of use; for a library, public API first, private helpers after. Order is for the reader only — there is no forward-declaration constraint.
- **Keep todo items succinct** — 2–3 sentences max.
- **Maintenance:** when changing code, update the relevant docs — `CLAUDE.md` at the root and in each sub-project (packages, files, commands, architecture, focus), and **`lyra/LANGUAGE.md` for any language rule or semantics**.
- **CLAUDE.md records rules, not history.** Reasoning goes in `lyra/COMPLETED.md`; open work in `lyra/todo.md`.

## Sub-Projects

| Directory | Language | Purpose |
|---|---|---|
| `tree-sitter-lyra/` | JavaScript | tree-sitter grammar |
| `lyra/` | Go | Parser, AST, types, collector, typechecker, LSP server, compiler CLI |
| `lyra-vscode-ext/` | TypeScript | VS Code extension — launches the LSP server |
| `lyra-zed-ext/` | Rust (wasm) | Zed extension — launches the LSP server; owns its tree-sitter queries |
| `lyra-website/` | Astro | Public site — dev blog and docs (Starlight) |

The Go module (`github.com/Lyra-Language/lyra`) depends on the grammar via a `replace` directive to `../tree-sitter-lyra`. Each sub-project has its own `CLAUDE.md`.

## Bootstrapping the Workspace

Each sub-project is an **independent Git repo** under `Lyra-Language` — **not submodules**. The workspace repo tracks only `CLAUDE.md`, `lyra.code-workspace` and the setup scripts (`.gitignore` ignores the rest). `README.md` covers per-OS prerequisites and the Windows execution-policy step.

```bash
./setup.sh              # clone anything missing, fetch the rest   (setup.ps1 on Windows)
./setup.sh --pull       # also fast-forward each repo to upstream
./setup.sh --https      # https:// remotes instead of git@
```

- Idempotent; processes the grammar first; removes a failed clone's partial directory.
- `--pull` fast-forwards **only clean repos with no local commits** — dirty/diverged trees are reported, never merged or reset.
- **No git-lfs needed**: `tree-sitter-lyra/src/parser.c` (~15 MB) is ordinary tracked text. Only historical commits need lfs.

## Running the Suite on Linux (`asan.sh`)

Runs tests in a Debian container (`asan.Dockerfile`), mounting `lyra/` and `tree-sitter-lyra/` read-only. No Node/tree-sitter CLI needed. Caches live in a named volume, separate from host artifacts.

```bash
./asan.sh                 # ASan suite (pkg/backend/llvm)
./asan.sh ./...           # whole suite on Linux
./asan.sh --shell         # interactive shell
./asan.sh --rebuild       # rebuild the image
LEAKS=1 ./asan.sh         # also LeakSanitizer (expect known noise)
```

- **Catches:** (a) memory faults; (b) **invalid IR Apple clang can't diagnose** — the container pins `clang-15` (14 can't split coroutines, 16 dropped typed pointers), whose typed pointers reject function-type mismatches.
- It is not the fix for ASan missing faults (that was `sanitize_address` instrumentation in the harness; see `lyra/CLAUDE.md`).
- **Clears the container's Go build cache when `parser.c` changes** (keyed on size+mtime), since Go doesn't hash `#include`d sources.
- **Preflights ASan** and fails hard if it can't link/run (Debian's `clang` lacks `libclang-rt-dev`; without it every ASan test skips).

## Critical Cross-Project Dependency

After changing `tree-sitter-lyra/grammar.js`:
1. `npx tree-sitter generate` — regenerate `src/parser.c`
2. `go clean -cache` — **required**: otherwise tests silently run against the old grammar
3. `go test ./...`

**CI for `lyra`** (`.github/workflows/ci.yml`) checks out the **`tree-sitter-lyra` remote** and regenerates from its `grammar.js` — not your local sibling. Two things must both hold:
1. **Push ordering:** push the grammar change to `tree-sitter-lyra` **before (or with)** the dependent `lyra` code, or CI fails every test using the new grammar. Commit the regenerated `parser.c` with the grammar.
2. **Cache staleness:** the CGO binding does `#include "../../src/parser.c"`, which Go's cache doesn't hash, so a restored `setup-go` cache keeps the old parser. **Keep the `go clean -cache` step** after regeneration in CI.

**Zed** (`lyra-zed-ext/extension.toml`) pins `tree-sitter-lyra` **by commit** and compiles `parser.c` itself. A grammar change reaches Zed only once pushed *and* the pin is bumped; a pin to an unpushed commit fails the build. Queries live in `lyra-zed-ext/languages/lyra/`; a query naming a node that no longer exists makes Zed drop the file and **all Lyra highlighting disappears**. See `lyra-zed-ext/CLAUDE.md`.

## Data Flow

```
source text
  → pkg/parser                 (tree-sitter CST via CGO)
  → pkg/analyzer/collector     (CST → AST + SymbolTable)
  → pkg/analyzer/typechecker   (AST → TypeTable)
```

## Where to Look

- **Language semantics:** `lyra/LANGUAGE.md` — not auto-loaded; read the relevant section before changing or relying on language behaviour.
- **Compiler map** (packages, cross-package rules, per-package READMEs): `lyra/CLAUDE.md`.

## Editor Extensions

- **Formatting belongs to neither extension**: `lyra-lsp` implements `textDocument/formatting` by running `lyrafmt` (the formatter written in Lyra, `lyra/examples/lyrafmt/`), which `./build.sh` puts beside it. Both editors get `Format Document` with no client code, and a machine without `lyrafmt` simply has none.
- **VS Code** (`lyra-vscode-ext/`): `src/extension.ts` starts an LSP client spawning `lyra-lsp` over stdio; path overridable via `lyra.languageServerPath`. Highlighting is a hand-written TextMate grammar.
- **Zed** (`lyra-zed-ext/`): Rust cdylib for `wasm32-wasip1`. `src/lyra.rs` resolves the server: `lsp.lyra-lsp.binary.path` → `lyra-lsp` on `$PATH` → `build/lyra-lsp` in the worktree. Highlights from tree-sitter via its own `languages/lyra/{highlights,brackets,indents,outline,injections}.scm` — a deliberate sibling of `tree-sitter-lyra/queries/highlights.scm` (different capture names), so **both need updating when the grammar gains a node**. Install via **Install Dev Extension** in Zed; not in the registry.

## Current Development Focus

`lyrafmt`, the formatter written in Lyra, as the self-hosting probe — it keeps finding compiler bugs rather than formatter ones. The typechecker is maintenance: exhaustiveness and the purity work are built, and what turns up is a position that accepts a value it should refuse. Detail in `lyra/CLAUDE.md`; open work in `lyra/todo.md`; finished work and reasoning in `lyra/COMPLETED.md`.

## Testing

```bash
# From lyra/
go test ./...                                              # all tests
go test ./pkg/analyzer/collector/tests/...                 # collector golden tests
UPDATE_GOLDEN=1 go test ./pkg/analyzer/collector/tests/... # regenerate golden files
go test -run TestFunctionName ./pkg/...                    # single test

# From tree-sitter-lyra/
npx tree-sitter generate && npx tree-sitter test           # grammar corpus tests
npx tree-sitter test --include "Test Name"                 # single corpus test
```

- Golden files: `lyra/pkg/analyzer/collector/tests/testdata/*.golden`; the printer omits zero/nil/empty fields.
- `lyra/pkg/backend/llvm` behavioural tests (clang compile-and-run) are fully parallel and cache binaries in `~/Library/Caches/lyra-llvm-tests`, keyed on emitted IR; a warm run is ~2s (details in `lyra/CLAUDE.md`).
