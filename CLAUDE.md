# Lyra — Project Context

Lyra is a programming language under active development. This workspace contains five sub-projects — four tightly coupled (grammar, compiler, two editor extensions) plus the public website.

## Working Agreements

- **Commit directly to `main`.** Do not create feature branches — this is a single-developer workspace and all work goes straight to `main`. Commit only when asked.
- **Keep todo items succinct.** When tracking work in a todo list, keep each item to 2–3 sentences max.
- **Maintenance:** When making code changes, update the relevant `CLAUDE.md` file(s) to reflect them — this includes new packages, renamed files, changed commands, updated architecture, and shifts in development focus. There is a `CLAUDE.md` at the workspace root (this file) and one in each sub-project: `lyra/CLAUDE.md`, `tree-sitter-lyra/CLAUDE.md`, `lyra-vscode-ext/CLAUDE.md`, `lyra-zed-ext/CLAUDE.md`, and `lyra-website/CLAUDE.md`.

## Sub-Projects

| Directory | Language | Purpose |
|---|---|---|
| `tree-sitter-lyra/` | JavaScript | tree-sitter grammar for Lyra |
| `lyra/` | Go | Parser, AST, type system, collector, typechecker, LSP server, compiler CLI |
| `lyra-vscode-ext/` | TypeScript | VS Code extension — launches the LSP server |
| `lyra-zed-ext/` | Rust (wasm) | Zed extension — launches the LSP server; owns its own tree-sitter queries |
| `lyra-website/` | Astro | Public site — dev blog and docs/guides (Starlight) |

The Go module (`github.com/Lyra-Language/lyra`) depends on the tree-sitter grammar via a `replace` directive pointing to `../tree-sitter-lyra`. Each sub-project has its own detailed command and architecture notes in its `CLAUDE.md`.

## Bootstrapping the Workspace

Each sub-project is its **own independent Git repo** with its own remote under `Lyra-Language`; the workspace repo tracks only `CLAUDE.md`, `lyra.code-workspace`, and the two setup scripts (`.gitignore` ignores everything else by default, so a sub-project can never be committed here by accident). They are **not** submodules — nothing pins their commits — so a fresh clone of `lyra-workspace` gets the docs but none of the code.

`setup.sh` (macOS/Linux) and `setup.ps1` (Windows) reconstitute the tree (`README.md` documents this for humans, incl. per-OS prerequisites and the Windows execution-policy step):

```bash
./setup.sh              # clone anything missing, fetch what's already there
./setup.sh --pull       # also fast-forward each repo to its upstream
./setup.sh --https      # use https:// remotes instead of git@ (no SSH key)
```

Both are idempotent and safe to re-run. `--pull` fast-forwards **only** a clean repo with no local commits — a dirty or diverged working tree is reported and left untouched, never merged or reset. Repos are processed grammar-first, since the Go module `replace`s into `../tree-sitter-lyra`.

**git-lfs used to be a hard prerequisite for `tree-sitter-lyra`** and no longer is. Its generated `src/parser.c` was ~115 MB in Git LFS, so without `git-lfs` on `PATH` git invoked it mid-checkout and the clone died partway; the scripts had to detect that and skip the repo. The grammar's `lambda_expr` rule was rebuilt to stop a parser state explosion (62,663 states → 6,475), and the file is now 12.8 MB of ordinary tracked text — a plain clone suffices, and only a checkout of a *historical* commit still needs LFS. Any failed clone still has its partial directory removed so a re-run retries cleanly.

## Running the Suite on Linux (`asan.sh`)

`./asan.sh` runs the test suite in a Debian container (`asan.Dockerfile`), mounting both `lyra/` and `tree-sitter-lyra/` read-only — both, because the Go module reaches the grammar through a `replace` directive, so a container with only `lyra` cannot resolve its own dependency. No Node or tree-sitter CLI is needed: the generated `src/parser.c` is tracked in the repo and the container only compiles it (which also sidesteps the arm64-Linux tree-sitter build quirk needing `CC=gcc`). Caches live in a named volume, never in the mounted tree, so Linux artifacts can't mix with the host's macOS ones.

```bash
./asan.sh                 # the ASan suite (pkg/backend/llvm)
./asan.sh ./...           # the whole suite, on Linux
./asan.sh --shell         # interactive shell in the container
./asan.sh --rebuild       # rebuild the image
LEAKS=1 ./asan.sh         # also enable LeakSanitizer (expect known-accepted noise)
```

**Two things it is for, and one it is not.** It catches (a) genuine memory faults, and (b) **invalid IR that modern clang cannot even diagnose**: Debian's older clang still uses *typed pointers*, so it rejects a function-type mismatch that Apple clang 21's opaque pointers make indistinguishable — which is how a real miscompile was found where a `(u8, u8)` tuple argument was built at the i64 default width. It is **not** the fix for ASan missing memory faults; that was missing `sanitize_address` instrumentation, which affected macOS and Linux equally and is fixed in the harness (see `lyra/CLAUDE.md`'s backend-testing section). Both `lyrac`-level Linux gaps it surfaced — an anonymous tuple argument built at the wrong width, and a signed `i128` multiply that could not link — are fixed; see `lyra/COMPLETED.md`'s 07/30 entries. The whole suite passes on Linux as of 07/30.

It also **clears the container's Go build cache when the generated parser changes**, keyed on the parser's size+mtime. This is the workspace's own documented build-cache hazard, and the script walked into it: the cache lives in a named volume, Go does not hash `#include`d sources, and so a regenerated `parser.c` left the compiled-parser object stale — the suite ran against the *old* grammar, silently, and only in the container, which reads as a platform difference rather than a stale build.

The script **preflights** that ASan actually links and runs, and fails hard if not. Debian's `clang` package does not pull in `libclang-rt-dev`, and without it every ASan test *skips* — a green run that verified nothing, which is exactly what the first build of this image did.

## Critical Cross-Project Dependency

After changing `tree-sitter-lyra/grammar.js`:
1. `npx tree-sitter generate` — regenerate `src/parser.c`
2. `go clean -cache` — invalidate Go's stale compiled parser
3. `go test ./...` — verify

Skipping step 2 causes tests to silently run against the old grammar.

**CI grammar sync (two things must both hold).** `lyra` and `tree-sitter-lyra` are independent GitHub repos under `Lyra-Language`. CI for `lyra` (`.github/workflows/ci.yml`) checks out the **`tree-sitter-lyra` remote** and *regenerates* the parser from its `grammar.js` (`npm run build`) — it does not use the grammar in your local sibling directory. Two independent hazards, both of which caused real CI failures:

1. **Push ordering.** A grammar change must be **pushed to `tree-sitter-lyra` before (or with) the `lyra` code that depends on it** — push `tree-sitter-lyra` first, then `lyra`. Pushing only the `lyra` side leaves CI regenerating from an old `grammar.js`, so every test exercising the new grammar fails. `src/parser.c` is regenerated and committed with the grammar, so the push carries it (ordinary text since it left Git LFS — a grammar change is a large but reviewable diff).
2. **Build-cache staleness (the subtle one).** The CGO binding pulls the grammar in with `#include "../../src/parser.c"` (`tree-sitter-lyra/bindings/go/binding.go`). Go's build cache hashes the `.go` files and tracked cgo sources but **not** files brought in via `#include`, so a regenerated `parser.c` does **not** invalidate the compiled-parser object that `setup-go` restores from a previous run. Without a `go clean -cache` **after** regeneration, CI silently reuses the stale grammar even when the remote is fully up to date — the rune work failed CI this way *after* the grammar was correctly pushed. The CI workflow now runs `go clean -cache` post-regeneration (the same local step in the numbered list above); keep that step.

**A third consumer, with the same push-first rule.** `lyra-zed-ext/extension.toml` pins `tree-sitter-lyra` **by commit**, and Zed clones that repo and compiles `src/parser.c` itself — it never reads the sibling checkout either. So a grammar change reaches Zed only once it is pushed *and* the pin is bumped; a pin to an unpushed commit fails the grammar build outright. The tree-sitter queries that go with it live in `lyra-zed-ext/languages/lyra/`, not in the grammar repo, and a query naming a node that no longer exists makes Zed drop the whole file — every Lyra buffer loses all highlighting at once rather than one rule quietly going missing. See `lyra-zed-ext/CLAUDE.md` for how to verify them.

## Data Flow

```
source text
  → pkg/parser          (tree-sitter CST via CGO)
  → pkg/analyzer/collector  (CST → AST + SymbolTable)
  → pkg/analyzer/typechecker  (AST → TypeTable)
```

## The Compiler (`lyra/`)

`lyra/CLAUDE.md` is the map: what each package is, the rules that hold across all of them,
and a pointer to a `README.md` beside each package's code for the depth. Start there rather
than here — this file duplicated that reference until 07/30 and the copy drifted.

## Primitive Types

Integers: `i8`, `i16`, `i32`, `i64`, `i128`, `u8`, `u16`, `u32`, `u64`, `u128` (no platform-dependent `int`/`uint` — removed for determinism; untyped integer literals default to `i64`). `i128`/`u128` lower natively (LLVM `i128`, 16/16 ABI); checked arithmetic + `match`/comparisons/conversions extend for free by width, division/`%%` go through compiler-rt, and `print` uses a hand-written base-10 formatter (`lyra_i128_to_str`, no printf 128-bit specifier). MVP literal gap: a >64-bit literal isn't representable yet (`IntegerLiteralExpr.Value` is `int64`), so a 128-bit constant is reached via arithmetic or an `i128(x)` conversion of an i64/u64-range value; the value-range pass leaves them ⊤ (untracked, sound) like `u64`.
Bitwise/shift on integers (08/02): `&`, `|`, `~` (xor), `<<`, `>>`, prefix `~` (complement),
plus the five compound assignments. **Xor is `~`, not `^`** — `^` is taken by raw-pointer
types (`^T`) and postfix deref (`ptr^`). Precedence is not C's: bitwise binds *tighter than
comparison* (so `flags & MASK == 0` groups as a human reads it) and looser than arithmetic,
with shifts above addition. An out-of-range shift amount **traps** rather than doing whatever
the target's shift hardware does. Integers only — no float operand, at any width.
Floats: `f16`, `f32`, `f64` (there is no bare `float` keyword; untyped float literals default to `f64`)
Other: `bool`, `string`, `rune` (a Unicode code point, i32 — Go/Odin naming)
Compiler-internal, no syntax: `never` — the bottom type, the result of `panic(msg)`. Assignable
to every type (nothing is assignable to it), which is what lets a diverging expression sit in
value position: `match m { Some(v) => v, None => panic("…") }`. `panic` is the one trap a
program reaches deliberately; it is EffectNone, so `pure`/`det`/`noalloc` may all call it.
Internal (literal inference only): `untyped_int`, `untyped_signed_int`, `untyped_float`

## Ranges

Four end operators, two axes: `..<` `..<=` ascend, `..>` `..>=` descend; `..<` `..>` exclude
the end bound, `..<=` `..>=` include it. An optional step follows a colon (`0..<10:2`) and is
a **magnitude** — a negative step is an error, because the operator already says which way
the range runs.

**Direction is the operator's, never the bounds'.** `5..<1` is an ascending range that
happens to be empty, not a descending one. That keeps direction a parse-time fact, so a
range over variables cannot run the opposite way from the way it reads. The inclusive end
was spelled `..=` until 08/04; it became `..<=` so both directions read identically.

Descending is meaningful only where a range is *iterated*. As a match pattern or a `newtype`
constraint a range is a **set**, which has no direction, and `..>`/`..>=` there are
`lyra-E034`.

## Calling on a Receiver

Two related features, both 08/03, both opted into by naming a function's first parameter
`self` — and easier to keep straight as one idea in two halves:

- **UFCS** (call side): `m.unwrap_or(0)` resolves to the free function `unwrap_or(m, 0)`.
  The call is rewritten to pass the receiver as argument 0 before anything downstream sees
  it, so nothing after the typechecker knows UFCS exists. An `own` receiver is refused, so a
  move always looks like a call; calling into another module method-style needs an import.
- **Receiver-keyed overloading** (declaration side): a module may declare one name several
  times when each declaration takes a `self` receiver and their receiver *type heads* differ
  — `Maybe<t>` beside `Result<t,e>` is allowed, a second `Maybe<…>` is refused where it is
  written, since ranking two matching candidates would need a specificity ordering the
  language does not have. The prelude uses it for `unwrap_or`/`unwrap_or_else`.

Without the second, `Maybe` and `Result` could each be *called* with `map` but only one of
them could have a `map` *written* in a given module — which is why the standard library used
to split `std.maybe` from `std.result`. Details and the reasoning are in
`lyra/pkg/analyzer/typechecker/README.md`; a name still may not be exported by two modules
at once (`lyra/todo.md`, Modules).

## Console I/O

Output is `print`/`println`, polymorphic over the printable scalars. **Input is
`read_line() -> Maybe<string>`** (08/05): one line from stdin, terminator removed (a trailing
`\r` with it), `None` at EOF.

`Maybe`, not `string`, because EOF must be distinguishable from a blank line — both are `""`
otherwise, so the natural read loop never terminates once stdin closes. Its companion
`parse_i64` (`(self: string) -> Maybe<i64>`, so `line.parse_i64()`) is strict: `None` for a
blank line, a lone sign, trailing garbage, surrounding whitespace, or a value outside the i64
range. Out-of-range is a `None` rather than an overflow trap, which it would otherwise be —
parsing is where a program meets input it did not choose.

**The division of labour between them is the rule to follow when adding more.** `read_line`
is a compiler builtin because it *has* to be — the line comes from libc and Lyra has no FFI.
`parse_i64` is ordinary Lyra in `std/prelude/parse.lyra` because it can be. Anything expressible in
the language goes in the prelude, where it is readable, testable and replaceable; the builtin
registry stays whatever is genuinely primitive.

## Randomness

`random_seed() -> u64` (one word of OS entropy) is the **only** builtin; the generator is
ordinary Lyra in `std/prelude/rand.lyra`:

- `rng_seeded(seed)` / `rng_from_entropy()` build an `Rng`;
- `rng.next_u64()`, `rng.below(bound)` (half-open), `rng.between(lo, hi)` (inclusive) draw
  from one;
- `random_below(bound)` / `random_between(lo, hi)` are ambient one-liners that seed a fresh
  generator per call.

`below` rejects the top partial bucket rather than taking a modulo, so a draw is unbiased.
The algorithm is xorshift64*, chosen for legibility — **not** suitable for anything
security-sensitive, and seeding it from the OS does not change that.

**Keeping the seed as the primitive is what lets `det` code use randomness, and no rule
enforces it — it falls out of effect inference.** A seeded generator only mutates its own
receiver (`EffectMut`, which `det` permits), so a seeded draw is reproducible and `det`-legal;
`rng_from_entropy`/`random_below` reach `random_seed`, so inference gives them `EffectRand`
and `det` refuses them. Asking for a seed you were not given is the non-deterministic act, and
that is the one place the bit is charged.

`Random.global()` was an effect-table entry naming nothing (no signature, no lowering — it
type-checked and crashed the backend); it is gone.

## The Clock

`wall_clock_nanos() -> i64` (08/06) is `clock_gettime(CLOCK_REALTIME, …)` and nothing else —
the same rule randomness follows, so seconds, elapsed durations and formatting are left to
the prelude. Signed, because the useful operation on two instants is subtraction; the unit is
in the name because a clock returning a bare number invites a guess that fails silently.

It replaced `wallClock`, the last effect-table entry naming nothing — the `Random.global()`
shape, still in place. **Implemented rather than deleted**, since deleting would have left
`EffectTime` a bit nothing in the language could set. Ambient reads carry that bit, so
`pure`/`det` refuse them; a timestamp threaded in as a parameter is ordinary data, which is
the same split that lets `det` code use a seeded `Rng`.

## Strings

UTF-8, an immutable `{ptr, byte_len}` fat pointer. Everything the *language* exposes is
**rune-indexed**, and the field is bytes: representation and language deliberately disagree.

`s[i]` is the i-th code point (O(i)), `for c in s` walks code points, and as of 08/06
`s.len()` is the rune count (O(n)) and `s.slice(start, end)` a half-open rune range. `len`
counts runes because the *index* already did: with a byte length,
`for i in 0..<s.len() { s[i] }` would be wrong on the first non-ASCII input, silently and
only for some inputs.

`slice` **allocates** — it copies into a fresh ref-counted box rather than borrowing its
parent's bytes, because a box's header sits at its start and a pointer into the middle
cannot reach it — so `noalloc` refuses it, and refuses `trim` with it.
`trim`/`trim_start`/`trim_end` are ordinary Lyra in `std/prelude/strings.lyra`, trimming the five
ASCII whitespace characters and not Unicode's full set (which needs a table that belongs in
a real Unicode library). Not yet written, all now expressible:
`starts_with`/`ends_with`/`contains`/`split`.

A literal *is* a postfix head as of 08/06, so `"abc".len()`, `[1, 2, 3].len()` and
`1.wrapping_add(2)` all parse — which matters because UFCS made method syntax the normal way
to call, and every prelude combinator had been unreachable from the literal a reader would
naturally try it on.

## Calling on a Type Name

There isn't any. `Rng.seeded(42)` is **`lyra-E035`** (08/06): Lyra has no type-namespaced
associated functions, which is why the prelude's constructors are bare (`rng_seeded`). A
trait gets its own message, since `Trait::method(…)` *is* a spelling the language has.

Until then it type-checked clean and crashed the backend — the hole that made
`Random.global()` look implemented. It was wider than a member call: a PascalCase name owning
no constructor inferred as a silent nil, so `Rng.field`, `let x = Rng` and even
`Nonexistent.make(1)` were all accepted. Building the feature is open; the diagnostic is not
a placeholder for it.

## A Module Is a File or a Directory

`std.prelude` is `std/prelude.lyra` **or** every `*.lyra` directly inside `std/prelude/`
(08/07). Both forms are the same module — one path, one namespace, one scope — so a module
that outgrows a file splits without any of its declarations changing meaning. The shipped
prelude is seven files.

**The equivalence is the whole point**, because the obvious alternative is wrong. Receiver-keyed
overloading, `pub`, and prelude shadowing are all keyed on the *module*, so splitting a grown
module into *several* modules silently changes what its names mean: `unwrap_or` for `Maybe`
beside `unwrap_or` for `Result` would become a cross-module duplicate, which is exactly the
split the standard library was rescued from on 08/04.

Every file in a module directory must declare the module (a file's own text has to say which
namespace its declarations join, in a namespace where a name may be a receiver overload of one
three files away); a single-file module needs no header, since its path is its location. A
subdirectory is the next path down, not more of the parent. A module offering both forms in one
root is an error rather than a silent preference. Entering a compile at one file of a
multi-file module brings its siblings — without that, `lyrac check std/prelude/strings.lyra`
would analyze a fragment and report the rest of the prelude undefined.

## VS Code Extension (`lyra-vscode-ext/`)

`src/extension.ts` starts the LSP client, which spawns `lyra-lsp` via stdio. The server path defaults to `lyra-lsp` on `$PATH` and is overridable via the `lyra.languageServerPath` VS Code setting.

## Zed Extension (`lyra-zed-ext/`)

A Rust cdylib compiled to `wasm32-wasip1`. `src/lyra.rs` resolves the server binary — Zed settings (`lsp.lyra-lsp.binary.path`) → `lyra-lsp` on `$PATH` → `build/lyra-lsp` under the worktree root — and hands Zed the command to spawn; Zed owns the LSP client itself.

The two extensions differ in one structural way: **Zed highlights from tree-sitter, so this repo carries its own queries** (`languages/lyra/{highlights,brackets,indents,outline}.scm`) where VS Code uses a hand-written TextMate grammar. Those queries are a deliberate sibling of `tree-sitter-lyra/queries/highlights.scm` rather than a copy — the grammar's file targets nvim-treesitter's capture names and Zed's themes key off a different set, so the nvim names would render as the wrong style instead of failing visibly. Both files need updating when the grammar gains a node.

Install it with **Install Dev Extension** on Zed's Extensions page (there is no CLI for this). Not published to the Zed registry yet.

## Current Development Focus

The typechecker is the active area of work. Open to-dos and work in progress are in `lyra/todo.md`; finished work, with the reasoning behind it, is in `lyra/COMPLETED.md`.

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

The `lyra/pkg/backend/llvm` behavioral tests (clang-compile-and-run) are fully parallel and cache compiled binaries in `~/Library/Caches/lyra-llvm-tests`, keyed on the emitted IR — macOS's serialized first-exec assessment of new binaries is what made them slow, so a warm run is ~2s and only tests whose IR changed recompile (details in `lyra/CLAUDE.md`).
