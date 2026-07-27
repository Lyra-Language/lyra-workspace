# Lyra — Project Context

Lyra is a programming language under active development. This workspace contains four sub-projects — three tightly coupled (grammar, compiler, editor extension) plus the public website.

## Working Agreements

- **Commit directly to `main`.** Do not create feature branches — this is a single-developer workspace and all work goes straight to `main`. Commit only when asked.
- **Keep todo items succinct.** When tracking work in a todo list, keep each item to 2–3 sentences max.
- **Maintenance:** When making code changes, update the relevant `CLAUDE.md` file(s) to reflect them — this includes new packages, renamed files, changed commands, updated architecture, and shifts in development focus. There is a `CLAUDE.md` at the workspace root (this file) and one in each sub-project: `lyra/CLAUDE.md`, `tree-sitter-lyra/CLAUDE.md`, `lyra-vscode-ext/CLAUDE.md`, and `lyra-website/CLAUDE.md`.

## Sub-Projects

| Directory | Language | Purpose |
|---|---|---|
| `tree-sitter-lyra/` | JavaScript | tree-sitter grammar for Lyra |
| `lyra/` | Go | Parser, AST, type system, collector, typechecker, LSP server, compiler CLI |
| `lyra-vscode-ext/` | TypeScript | VS Code extension — launches the LSP server |
| `lyra-website/` | Astro | Public site — dev blog and docs/guides (Starlight) |

The Go module (`github.com/Lyra-Language/lyra`) depends on the tree-sitter grammar via a `replace` directive pointing to `../tree-sitter-lyra`. Each sub-project has its own detailed command and architecture notes in its `CLAUDE.md`.

## Critical Cross-Project Dependency

After changing `tree-sitter-lyra/grammar.js`:
1. `npx tree-sitter generate` — regenerate `src/parser.c`
2. `go clean -cache` — invalidate Go's stale compiled parser
3. `go test ./...` — verify

Skipping step 2 causes tests to silently run against the old grammar.

**CI grammar sync (two things must both hold).** `lyra` and `tree-sitter-lyra` are independent GitHub repos under `Lyra-Language`. CI for `lyra` (`.github/workflows/ci.yml`) checks out the **`tree-sitter-lyra` remote** and *regenerates* the parser from its `grammar.js` (`npm run build`) — it does not use the grammar in your local sibling directory. Two independent hazards, both of which caused real CI failures:

1. **Push ordering.** A grammar change must be **pushed to `tree-sitter-lyra` before (or with) the `lyra` code that depends on it** — push `tree-sitter-lyra` first, then `lyra`. Pushing only the `lyra` side leaves CI regenerating from an old `grammar.js`, so every test exercising the new grammar fails. `src/parser.c` is stored via Git LFS, so the push uploads it as an LFS object.
2. **Build-cache staleness (the subtle one).** The CGO binding pulls the grammar in with `#include "../../src/parser.c"` (`tree-sitter-lyra/bindings/go/binding.go`). Go's build cache hashes the `.go` files and tracked cgo sources but **not** files brought in via `#include`, so a regenerated `parser.c` does **not** invalidate the compiled-parser object that `setup-go` restores from a previous run. Without a `go clean -cache` **after** regeneration, CI silently reuses the stale grammar even when the remote is fully up to date — the rune work failed CI this way *after* the grammar was correctly pushed. The CI workflow now runs `go clean -cache` post-regeneration (the same local step in the numbered list above); keep that step.

## Data Flow

```
source text
  → pkg/parser          (tree-sitter CST via CGO)
  → pkg/analyzer/collector  (CST → AST + SymbolTable)
  → pkg/analyzer/typechecker  (AST → TypeTable)
```

## Key Go Packages (`lyra/`)

- **`pkg/parser`** — thin CGO wrapper around tree-sitter; returns `*sitter.Tree`
- **`pkg/ast`** — AST node definitions; all nodes embed `AstBase` (holds `Location`); top-level interfaces are `Statement`, `Expression`, `Pattern`
- **`pkg/ast/symbols`** — lexical `SymbolTable` with a `Scope` tree (Global → Module → Function → Block/Loop); quick-lookup maps for `Types` and `Functions`
- **`pkg/types`** — `Type` interface and all implementations: `PrimitiveType`, `StructType`, `DataType`, `LambdaType`, `TupleType`, `ArrayType`, `ConstrainedType`, `PointerType`, `WeakType` (a non-owning `weak T` reference — pointer-sized, non-managed), `GenericType`, `SelfType`, `VoidType`, `UnresolvedType`
- **`pkg/typetable`** — maps `ast.Expression` nodes → resolved `types.Type`; populated by the typechecker, consumed by later passes
- **`pkg/analyzer/collector`** — main CST→AST walker; `collector.go` owns top-level dispatch (`CollectStatement`, `CollectExpr`, `ParseType`); subpackages handle `declarations/`, `typedecls/`, `expressions/`, `statements/`
- **`pkg/analyzer/typechecker`** — walks the AST, infers and checks types, writes results into `TypeTable`
- **`pkg/analyzer/checker`** — standalone AST passes (use-before-declaration, purity/effect bounds, recursive types, lints); since 07/21 also **`use_after_move.go`** (`lyra-E019`), a flow-sensitive definite-move analysis flagging a read of a binding after it was moved into an `own` parameter (union at branch joins, loop bodies seeded with their own moves, declaration/reassignment clears); and **`inert_borrow_modifier.go`** (`lyra-W010`), warning when `own`/`ref`/`mut` sits on a copied scalar primitive where it has no effect; and **`range_analysis.go`** (`lyra-E020`/`E021`/`W011`), a flow-sensitive value-range (interval) analysis tracking each integer variable's `[lo,hi]` to catch a *definite* overflow on a non-constant variable (`if x > 100 { x + 100 }` on an i8 — via branch refinement, which constant-folding can't see), a *definite* divide-by-zero on a variable divisor proven zero by flow (`lyra-E021`, `if b == 0 { a / b }`; the literal case stays the typechecker's), and an always-true/false comparison; zero-false-positive (anything imprecise widens to the type's full range); flow-sensitive with branch refinement and a **widening/narrowing fixpoint for `for`-loop counters** (tracked precisely inside the body, not havoc'd); it also returns a `SafetyTable` the backend uses to **elide** proven-unnecessary runtime traps: the overflow trap on `+`/`-`/`*` (`NoOverflow`), the divide-by-zero / signed-div-overflow guards on `/`/`%`/`%%` (`NoDivZero`/`NoDivOverflow`), and the array bounds trap + negative-index adjustment on `xs[i]` (`IndexInBounds`)
- **`pkg/analyzer/ownership`** — post-typecheck pass computing where the backend must retain/release reference-counted ("managed") values (strings today; `shared` later) so each is freed once; produces an `ownership.Table` the backend consumes (no diagnostics)
- **`pkg/printer`** — reflection-based AST printer used exclusively for golden tests
- **`pkg/driver`** — `Analyze(source) *Result`: the one reusable front-end pipeline (parse → collect → checks → typecheck → purity) returning the typed program + all tables + normalized diagnostics; `ResolveEntryPoint` validates a program's `main` (a zero-parameter function returning `u8` — the process exit code — or `void`). The entry point a backend builds on
- **`pkg/backend`** — `Backend` interface (front-end → codegen seam); **`pkg/backend/llvm`** is the LLVM IR backend, early status: integer + float + character literals (a `rune` is an i32 code point), arithmetic (int and float, incl. Odin-style floored `%%`), numeric conversions (int↔int, int→float, float widening), comparisons + `&&`/`||` (int and float), `if`/blocks, `let`/`var`/reassignment, `for` loops with `break`/`continue`, user-defined functions (calls, `return`, recursion), type declarations (tuple/struct → named LLVM struct types, `data` → its tagged-union layout), tuple/struct instances (construction + `.0`/`.field` access), **fixed-size arrays** (`[N]T` — construction to an `[N x T]` aggregate, `xs[i]` indexing: `extractvalue` for a constant index, a bounds-checked `getelementptr`+`load` for a runtime one; a **negative index counts from the end** (`-1` is the last element, Python-style), and out-of-range indices trap like checked arithmetic; arrays flow through `let`/params/args/returns by value), `data` value construction (nullary + positional variants), `match`/destructuring on a `data` value (tag switch + payload field binding), `match` on a bool/integer/float/rune scalar (if-else comparison ladder — `fcmp` for floats; a `rune` arm is an `icmp eq i32` against the collector-decoded code point, stored as an `ast.RunePatternValue`), `match` on a struct or tuple (shared ladder, recursing into nested struct/tuple/`data` sub-patterns), value-testing `data` payload sub-patterns (`Some(0)`), and match arm guards (`Some(x) if x > 0` — both fall back from the tag `switch` to the shared if-else ladder, where a guard is a second test that falls through to the next arm when false), and float scalars (literals, `fadd`/`fsub`/`fmul`/`fdiv`/`frem`, floored `%%`, `fneg`, `fcmp`, int→float/float-widening conversions, float params/returns, and float `match` — literal/range/binding arms via an `fcmp` ladder), strings (immutable fat pointer `{ i8*, i64 }` — literals interned in a global constant, `==`/`!=` via a branchless length-check + `memcmp`, `++` concatenation heap-allocated via the ref-counted runtime + `memcpy`, `match`, by-value params/returns, and `${…}` interpolation (each segment formatted to bytes via the same `formatForPrint` machinery print uses, then concatenated into one fresh heap box; the collector reconstructs literal chunks from raw source, since tree-sitter strips a content chunk's leading whitespace)), and explicit float→int rounding (`x.floor()`/`.ceil()`/`.round()` — a builtin method call, not the `i64(x)` conversion syntax, which still rejects float→int as lossy; lowers to a lazily-declared `llvm.<op>.<width>` intrinsic + `fptosi`, fixed `i64` return, narrow further via `i32(x.floor())`), **`print`/`println`** (compiler-provided builtins polymorphic over the printable scalars — string/int/float/bool/rune → void — the backend's first observable output; formats per type via libc `write`/`snprintf` + a rune UTF-8 encoder, `println` adds a newline write), and **void functions** (`ret void`; a void body lowers for effect, freeing owned temporaries) all lower to real IR. The ref-counted heap runtime (`lyra_rc_alloc`/`retain`/`release`, on libc `malloc`/`free`) is emitted as real function bodies into each module that needs it, and an **ownership model** (`pkg/analyzer/ownership` + the backend's retain/release lowering) **frees** heap strings — every string is a box (literals are pinned static boxes, so retain/release are uniform). It's evolving toward Perceus: **stages 1–2 last-use precision + dup/drop fusion (scalars)** retire a binding at its final use — an owning last use *transfers* the reference (no dup) and a borrowing last use *drops* it there, both fused (removed from the frame, no scope-exit release / no sentinel), so a copy chain `a → b → c` compiles to one allocation and one release; `own`/`ref`/`mut` are the borrow/own conventions, and break/continue no longer leak. **Stage 3 reuse / FBIP (`shared` values)** reclaims a matched box in place: a `match` on an owned `shared data` value at its last use `lyra_rc_drop_reuse`s the box (the box when unique `rc==1`, else null), and a same-type construction in an arm writes into it instead of allocating (`lowerBoxSharedReuse` — a runtime branch), with a non-constructing arm freeing the token; an arm field binding used once *moves* (no dup) so a recursive `map` rebuilds the whole list with **zero allocation per cell**. Supported by a `shared`-value return path and the typechecker's `propagateAllocation` (a `shared` return/annotation stamps construction leaves inside `match` arms `shared`). A *borrowed* scrutinee is never reused (caller still owns it). The same model **frees `shared` values** (`IsManaged` covers `AllocationOf == Shared`): a `shared T` lowers to a pointer to a `{ i64 rc, T }` box (`lowerType`/`SharedBoxType`), construction heap-boxes the value (`lowerBoxShared` → `lyra_rc_alloc`), field access reads through the box, and a `shared` field is a pointer (so recursive `data` — `Cons(i64, shared List)` — lowers and constructs). **`match` on a `shared` aggregate** (data/struct/tuple) is wired: the scrutinee is a box pointer, so the match unboxes it (`unboxSharedData` — load the inline payload out of `box → field 1`) and the existing tag/pattern machinery runs on the first-class value, while an identifier catch-all still binds the box pointer; the box's own drop is the ordinary last-use release (reading through it consumes no reference). This is the prerequisite for Perceus reuse/FBIP on `shared` values (stages 3–4). A *nested* `shared data` sub-pattern (destructuring a tail through its box) errors loudly. Verified memory-safe under AddressSanitizer with release==allocation conservation; managed values inside a `shared` box (a string field, a `shared` tail) are freed by the per-type **drop glue** (`drop.go`), passed as the box's `drop_fn`. Next: Perceus stage 4 (reuse specialization — skip stores for shared fields, a static-uniqueness fast path, and the token-conditional dup that restores arm-binding moves); `shared`/dynamic arrays (fixed-size stack arrays lower now)
- **`cmd/lyra-lsp`** — LSP server binary (launched by the VS Code extension via stdio)
- **`cmd/lyrac`** — compiler CLI (`check`/`build`) on top of `pkg/driver` + `pkg/backend/llvm`; a form `lowerExpr` doesn't cover yet errors loudly rather than emitting wrong code

## Primitive Types

Integers: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64` (no platform-dependent `int`/`uint` — removed for determinism; untyped integer literals default to `i64`)
Floats: `f16`, `f32`, `f64` (there is no bare `float` keyword; untyped float literals default to `f64`)
Other: `bool`, `string`, `rune` (a Unicode code point, i32 — Go/Odin naming)
Internal (literal inference only): `untyped_int`, `untyped_signed_int`, `untyped_float`

## VS Code Extension (`lyra-vscode-ext/`)

`src/extension.ts` starts the LSP client, which spawns `lyra-lsp` via stdio. The server path defaults to `lyra-lsp` on `$PATH` and is overridable via the `lyra.languageServerPath` VS Code setting.

## Current Development Focus

The typechecker is the active area of work. To-dos, Work In-Progress, and Completed features are logged in `lyra/todo.md`.

## Testing

```bash
# From lyra/
go test ./...                                              # all tests
go test ./pkg/analyzer/collector/tests/...                # collector golden tests
UPDATE_GOLDEN=1 go test ./pkg/analyzer/collector/tests/... # regenerate golden files
go test -run TestFunctionName ./pkg/...                    # single test

# From tree-sitter-lyra/
npx tree-sitter generate && npx tree-sitter test          # grammar corpus tests
npx tree-sitter test --include "Test Name"                # single corpus test
```

Golden test files live in `lyra/pkg/analyzer/collector/tests/testdata/*.golden`. The printer omits zero/nil/empty fields, so only non-empty fields appear in golden output.
