# Lyra — Project Context

Lyra is a programming language under active development. This workspace contains five sub-projects — four tightly coupled (grammar, compiler, two editor extensions) plus the public website.

## Working Agreements

- **Commit directly to `main`.** Do not create feature branches — this is a single-developer workspace and all work goes straight to `main`. Commit only when asked.
- **Lyra sources read top-down.** Put `main` at the top of the file and the functions it
  calls below it, in rough order of use; for a library module, public API first and private
  helpers after. There is no forward-declaration constraint — a top-level `let` may call one
  declared later in the same file — so the order is purely for the reader.
- **Keep todo items succinct.** When tracking work in a todo list, keep each item to 2–3 sentences max.
- **Maintenance:** When making code changes, update the relevant `CLAUDE.md` file(s) — new packages, renamed files, changed commands, updated architecture, shifts in development focus. There is one at the workspace root (this file) and one in each sub-project.
- **This file records rules, not history.** The reasoning behind a decision goes in `lyra/COMPLETED.md`; open work goes in `lyra/todo.md`. Keep entries here to what is true today and what will bite someone tomorrow.

## Sub-Projects

| Directory | Language | Purpose |
|---|---|---|
| `tree-sitter-lyra/` | JavaScript | tree-sitter grammar for Lyra |
| `lyra/` | Go | Parser, AST, type system, collector, typechecker, LSP server, compiler CLI |
| `lyra-vscode-ext/` | TypeScript | VS Code extension — launches the LSP server |
| `lyra-zed-ext/` | Rust (wasm) | Zed extension — launches the LSP server; owns its own tree-sitter queries |
| `lyra-website/` | Astro | Public site — dev blog and docs/guides (Starlight) |

The Go module (`github.com/Lyra-Language/lyra`) depends on the tree-sitter grammar via a `replace` directive pointing to `../tree-sitter-lyra`. Each sub-project has its own detailed notes in its `CLAUDE.md`.

## Bootstrapping the Workspace

Each sub-project is its **own independent Git repo** with its own remote under `Lyra-Language`; the workspace repo tracks only `CLAUDE.md`, `lyra.code-workspace` and the two setup scripts (`.gitignore` ignores everything else, so a sub-project can never be committed here by accident). They are **not** submodules, so a fresh clone of `lyra-workspace` gets the docs but none of the code.

`setup.sh` (macOS/Linux) and `setup.ps1` (Windows) reconstitute the tree; `README.md` documents this for humans, including per-OS prerequisites and the Windows execution-policy step.

```bash
./setup.sh              # clone anything missing, fetch what's already there
./setup.sh --pull       # also fast-forward each repo to its upstream
./setup.sh --https      # use https:// remotes instead of git@ (no SSH key)
```

Both are idempotent. `--pull` fast-forwards **only** a clean repo with no local commits — a dirty or diverged tree is reported and left untouched, never merged or reset. Repos are processed grammar-first, since the Go module `replace`s into `../tree-sitter-lyra`. A failed clone has its partial directory removed so a re-run retries cleanly.

git-lfs is **not** a prerequisite: `tree-sitter-lyra`'s generated `src/parser.c` is 12.8 MB of ordinary tracked text, so a plain clone suffices. Only a checkout of a *historical* commit still needs it.

## Running the Suite on Linux (`asan.sh`)

`./asan.sh` runs the test suite in a Debian container (`asan.Dockerfile`), mounting both `lyra/` and `tree-sitter-lyra/` read-only — both, because the Go module reaches the grammar through a `replace` directive. No Node or tree-sitter CLI is needed: the generated `src/parser.c` is tracked and the container only compiles it. Caches live in a named volume, never in the mounted tree, so Linux artifacts cannot mix with the host's macOS ones.

```bash
./asan.sh                 # the ASan suite (pkg/backend/llvm)
./asan.sh ./...           # the whole suite, on Linux
./asan.sh --shell         # interactive shell in the container
./asan.sh --rebuild       # rebuild the image
LEAKS=1 ./asan.sh         # also enable LeakSanitizer (expect known-accepted noise)
```

**Two things it is for.** It catches (a) genuine memory faults, and (b) **invalid IR that modern clang cannot even diagnose**: Debian's older clang still uses *typed pointers*, so it rejects a function-type mismatch that Apple clang 21's opaque pointers make indistinguishable. It is **not** the fix for ASan missing memory faults — that was missing `sanitize_address` instrumentation, fixed in the harness (see `lyra/CLAUDE.md`'s backend-testing section). The whole suite passes on Linux.

It **clears the container's Go build cache when the generated parser changes**, keyed on the parser's size+mtime. Go does not hash `#include`d sources, so without this a regenerated `parser.c` leaves the compiled-parser object stale and the suite runs against the *old* grammar — silently, and only in the container, which reads as a platform difference. It also **preflights** that ASan actually links and runs, and fails hard if not: Debian's `clang` package does not pull in `libclang-rt-dev`, and without it every ASan test *skips*.

## Critical Cross-Project Dependency

After changing `tree-sitter-lyra/grammar.js`:
1. `npx tree-sitter generate` — regenerate `src/parser.c`
2. `go clean -cache` — invalidate Go's stale compiled parser
3. `go test ./...` — verify

Skipping step 2 causes tests to silently run against the old grammar.

**CI grammar sync (two things must both hold).** CI for `lyra` (`.github/workflows/ci.yml`) checks out the **`tree-sitter-lyra` remote** and *regenerates* the parser from its `grammar.js` — it does not use your local sibling directory.

1. **Push ordering.** A grammar change must be **pushed to `tree-sitter-lyra` before (or with) the `lyra` code that depends on it**. Pushing only the `lyra` side leaves CI regenerating from an old `grammar.js`, so every test exercising the new grammar fails. `src/parser.c` is regenerated and committed with the grammar, so the push carries it.
2. **Build-cache staleness (the subtle one).** The CGO binding pulls the grammar in with `#include "../../src/parser.c"`. Go's build cache hashes `.go` files and tracked cgo sources but **not** `#include`d ones, so a regenerated `parser.c` does not invalidate the compiled-parser object `setup-go` restores from a previous run. The CI workflow runs `go clean -cache` post-regeneration — keep that step.

**A third consumer, with the same push-first rule.** `lyra-zed-ext/extension.toml` pins `tree-sitter-lyra` **by commit**, and Zed clones that repo and compiles `src/parser.c` itself. A grammar change reaches Zed only once it is pushed *and* the pin is bumped; a pin to an unpushed commit fails the grammar build outright. The queries that go with it live in `lyra-zed-ext/languages/lyra/`, not in the grammar repo, and a query naming a node that no longer exists makes Zed drop the whole file — every Lyra buffer loses all highlighting at once. See `lyra-zed-ext/CLAUDE.md` for how to verify them.

## Data Flow

```
source text
  → pkg/parser          (tree-sitter CST via CGO)
  → pkg/analyzer/collector  (CST → AST + SymbolTable)
  → pkg/analyzer/typechecker  (AST → TypeTable)
```

## The Compiler (`lyra/`)

`lyra/CLAUDE.md` is the map: what each package is, the rules that hold across all of them, and a pointer to a `README.md` beside each package's code. Start there rather than here.

## Primitive Types

Integers: `i8`, `i16`, `i32`, `i64`, `i128`, `u8`, `u16`, `u32`, `u64`, `u128`. There is no platform-dependent `int`/`uint` — removed for determinism; untyped integer literals default to `i64`.

`i128`/`u128` lower natively (LLVM `i128`, 16/16 ABI): checked arithmetic, `match`, comparisons and conversions extend by width, division and `%%` go through compiler-rt, and `print` uses a hand-written base-10 formatter (`lyra_i128_to_str`). A 128-bit literal is writable; the magnitude lives in a `big.Int` on the literal node, nil for anything that fits 64 bits, and it stays *untyped* where both `i128` and `u128` could hold it. Compile-time folding is arbitrary-precision (`ast.FoldBigExpr`; `FoldIntExpr` narrows at the end, so a consumer needing an int64 gets ok=false rather than a wrapped value). The value-range pass leaves 128-bit values ⊤ (untracked, sound), like `u64`.

Bitwise/shift on integers: `&`, `|`, `~` (xor), `<<`, `>>`, prefix `~` (complement), plus the five compound assignments. **Xor is `~`, not `^`** — `^` is taken by raw-pointer types (`^T`) and postfix deref (`ptr^`). Precedence is not C's: bitwise binds *tighter than comparison* (so `flags & MASK == 0` groups as a human reads it) and looser than arithmetic, with shifts above addition. An out-of-range shift amount **traps**. Integers only — no float operand at any width.

Floats: `f16`, `f32`, `f64` (no bare `float` keyword; untyped float literals default to `f64`).
Other: `bool`, `string`, `rune` (a Unicode code point, i32).

Compiler-internal, no syntax: `never` — the bottom type, the result of `panic(msg)`. Assignable to every type (nothing is assignable to it), which lets a diverging expression sit in value position: `match m { Some(v) => v, None => panic("…") }`. `panic` is EffectNone, so `pure`/`det`/`noalloc` may all call it.
Internal (literal inference only): `untyped_int`, `untyped_signed_int`, `untyped_float`.

## Overflow Arithmetic

Integer `+ - * /` **trap** on overflow. The three explicit alternatives are builtin methods on any concrete integer width, and having all three is the point of trapping by default — each says what the author meant:

- `wrapping_add`/`_sub`/`_mul` — modular two's-complement arithmetic;
- `saturating_add`/`_sub`/`_mul` — clamp to the type's range;
- `checked_add`/`_sub`/`_mul`/`_div` — `Maybe<T>`, `None` where it would have overflowed.

`checked_div` is in that set although division cannot overflow in the intrinsic sense: its two failures are a zero divisor and `INT_MIN / -1`, which are exactly the two cases `/` traps on. There is no `checked_rem` yet — Lyra has two remainder operators (`%` and `%%`), so the name would have to say which.

All of them are pure and allocate nothing (a `Maybe` of a scalar is an inline union), so they are usable from `pure noalloc` code.

**A literal that cannot hold its value is a compile error in every position** (`lyra-E048` for patterns): a match arm's `300` on a u8 scrutinee, a range-pattern bound, a `Some(300)` payload on `Maybe<u8>`, a value outside a newtype's range constraint, and a return-position `() -> u8 => 300` are all refused rather than truncated. Everything in these positions is a compile-time constant by grammar. One grace: an exclusive range end names a position, so `0..<256` on a u8 is legal and `0..<257` is not.

## Arrays

`[1, 2, 3]` is a fixed-size `[3]T`; the same literal under a `[]T` annotation builds a heap-allocated dynamic array instead — so the two are told apart by what the literal is *used as* rather than by how it is written, and `noalloc` refuses the second, not the first.

An element may be any type but `void`, including an anonymous tuple (`[](i64, string)`), a raw pointer and an anonymous struct, and may carry one allocation or `weak` modifier: `[]shared Node`.

`xs.slice(start, end)` is the half-open element range `[start, end)`, matching `..<` and the string method. The result is **always a `[]T`**, even from a `[N]T`: the length is `end - start`, a run-time value, so no fixed size could be written down — which also makes it `push`-able. It **copies**, so `noalloc` refuses it. Sharing the parent's element buffer would need that buffer ref-counted apart from the box that owns it, and a `push` on the parent reallocates it, so the slice would dangle while the array it came from is perfectly alive. `end == len` is legal (it names the position one past the last element, so `xs.slice(0, xs.len())` is a copy) and `start == end` is the empty array; a negative bound, either bound past the length, and an inverted range all trap. It exists for the commonest C output convention — a function fills a buffer you sized and reports how much it used — which had no spelling but a `push` loop.

`xs.push(v)` grows a dynamic array, amortized doubling. Elements live behind a pointer (`{rc, weak, len, cap, T*}`) rather than inline in the box, so growth cannot move the box and dangle every alias; the cost is one extra load per element access, language-wide. `push` mutates in place, returns void, needs a mutable receiver (the same rule and diagnostic as `xs[i] = v`), and `noalloc` refuses it.

`[...xs, v]` splices an array into a literal — the one append-shaped syntax the language has, and what a reader reaches for before finding `push`. Three rules:

- **The operand is any postfix expression**, not just a name: `[...f(x), ...h.xs, ...ys[0]]` all work.
- **A spread makes the result a `[]T`, always** — even where every operand is a fixed `[N]T` whose lengths would add up. A `[N]T` carries its size in its type, so deriving the arity from whether the operands *happen* to be fixed would make `[...xs, 1]` change type when `xs`'s declaration changes from `[3]i64` to `[]i64`, with the literal reading identically.
- **It allocates once**, sizing the result from the operands' lengths rather than growing — which is the cost it exists to spare an author who would otherwise write the `push` loop by hand. Every operand is evaluated exactly once, in source order.

A spread is only an array literal's element (`lyra-E068`): it stands for zero or more members of a surrounding list, and only an array literal has one. `f(...xs)` is refused rather than unimplemented — argument spread would make a call's arity a run-time property. A non-array operand is refused by name where the mistake is plausible: `[..."ab"]` names `to_runes()`.

`[v; n]` repeats a value, in both flavours. Two rules matter:

- **The value is evaluated once**, so `[next(); 3]` is one call. Each slot is then an owner, so a managed element takes n-1 extra retains — the literal `[s, s, s]` needs none of that, lowering three separate uses.
- **The count is a compile-time constant only where the type needs one.** A fixed `[N]T` carries its size in its type, so it must fold (`const M = N * 2` works — const chains fold); a `[]T` carries its length at run time and accepts any expression.

Evaluating once is also the form's one trap, and **`lyra-W019`** names it: `[[' '; WIDTH]; HEIGHT]` is **one** row referenced HEIGHT times, so every `grid[py][px] = c` writes the same place and every row prints identically — a plausible image rather than an error. A **warning**, because the code is correct and a deliberate alias is a real thing to want.

The predicate is narrower than "managed": a `[]T`, a `shared` aggregate with a writable field, or any struct/tuple/`data`/`[N]T` containing one. A string is managed and *immutable*, so `["hi"; 3]` stays silent. Two rules that surprise: `readonly` does not stop the sharing (it blocks the direct write, not `let mut c = fs[0].cells` then `c[0] = 7`), and a `shared` **scalar** does not share, since assigning to the binding rebinds it rather than writing the box. `examples/life.lyra` is the program written to walk into the shape.

## Ranges

Four end operators, two axes: `..<` `..<=` ascend, `..>` `..>=` descend; `..<` `..>` exclude the end bound, `..<=` `..>=` include it. An optional step follows a colon (`0..<10:2`) and is a **magnitude** — a negative step is an error, because the operator already says which way the range runs. A step of zero or less that is only knowable at **run time** traps (`lyra: range step must be positive`) rather than spinning: provable → compile error, otherwise → trap. A comprehension over the same degenerate step yields an empty array instead, since its count is computed up front.

A `for-in` range **terminates at the type's edge**: the advance is guarded, so `0..<=hi` with `hi` at the counter type's max visits the max and exits instead of wrapping, and a large step cannot leap an exclusive end back into range.

**Direction is the operator's, never the bounds'.** `5..<1` is an ascending range that happens to be empty, not a descending one — which keeps direction a parse-time fact, so a range over variables cannot run the opposite way from the way it reads.

Descending is meaningful only where a range is *iterated*. As a match pattern or a `newtype` constraint a range is a **set**, which has no direction, and `..>`/`..>=` there are `lyra-E034`.

## Newtypes

`newtype` gives **nominal identity to a structural type**: `newtype Meters = f64` is not interchangeable with other f64s. The base must actually be structural — `lyra-E041` refuses a `struct`, a `data` type, a named tuple and an *anonymous* tuple, since all four already have identity (`tuple Rgb(u8, u8, u8)` is what the message tells you to write instead). Scalars, `string`, arrays, raw pointers and function types all work.

**A newtype has a constructor, and a typed value must use it.** `Cents(150)` — and the juxtaposed `Cents 150`, which the collector erases into the same node — is a compile-time assertion about which type a value has, not a wrapper: it lowers to its operand and nothing else. A generic newtype constructs by call too (`Boxed(5)` is `Boxed<i64>`; an untyped operand promotes to its default, and `Boxed::<u8>(200)` binds explicitly). Malformed forms are `lyra-E044`.

**An untyped literal converts implicitly; a typed value does not** (`lyra-E046`). `let c: Cents = 150` and `let xs: []Percent = [10, 20]` are fine; `take(plain_i64)` against `(c: Cents)` is an error, and `Cents(x)` is how it is said. The line is provenance: a literal has no unit yet, a typed value came from somewhere. **An array construction written in place is provenance-free by form** (08/28): an array literal or repeat — elements computed or not — converts implicitly, because the container the newtype names is built right there, aimed at the annotation; a typed *binding* holding one still needs the constructor, and an element-level newtype still refuses a typed element through propagation. A lambda literal is deliberately not form-exempt — a lambda-valued binding's nominal typing has an open gap (todo.md, Newtypes), and `Handler((n) => …)` is the spelling that works. Scalar and string bases stay on value provenance — `x + y` into `Cents` and `a ++ b` into `Email` need the constructor — since there the operand *is* the quantity.

**Reading out is explicit for every base** (`lyra-E047`) — the base's name applied where it has one (`i64(c)`, `string(e)`, `bool(f)`), and the universal **`base(v)`** where it does not (an array, a raw pointer, a function type). Both are identities at runtime just as the constructor is. `string(...)`/`bool(...)` exist solely as that spelling: no stringification, no truthiness. Conversions look *through* a newtype on their operand, so `u8(cents)` behaves exactly as `u8(plain_i64)`; `base(...)` strips exactly **one** newtype layer, so a chain reads out one declaration at a time (`base(base(x))`), matching newtype→newtype conversion having no path. `base` is a compiler builtin resolved after scope, so a user binding of the name shadows it — every later pass recognizes a resolved read-out by the typechecker's marker (`TypeTable.IsBaseReadout`), never by the spelling. (Until 08/28 an unnameable base kept its implicit read-out as the documented limit; `base(...)` is the spelling that retired it.)

**Constraints are checked wherever the newtype flows** — annotation, argument, return, array element — and through the constructor, so `Percent(150)` and `let p: Percent = 150` report alike (`lyra-E023`). `values(...)` is `lyra-E045`. `step(...)` measures from the range's start, so `range(5..<=95), step(10)` accepts 15 and refuses 10 (`lyra-E053`).

**And at run time too**, so the ladder has both rungs: a provable violation is a compile error, and a value the compiler cannot see through traps where it is constructed (`lyra: value violates its newtype's constraint`). The typechecker publishes only the sites it could not settle statically, so a literal construction costs nothing and a runtime one costs one compare-and-branch.

**`pattern(...)` is checked by a DFA compiled at *compile* time** — a constraint's pattern is part of a type, so the runtime needs no regex engine. Flattened tables ship as constants and one shared driver walks them (O(n), no backtracking, no allocation). `lyra-E054` refuses a pattern that cannot become a table: a lookbehind, or a DFA past `regex.MaxTableStates`.

**A regex literal is only a constraint's argument.** As a *value* (`let re = r"[a-z]+"`) or a *match pattern* it is `lyra-E052`, unimplemented. There is no `regex` type to annotate either — a lowercase type name parses as a type variable, so `(re: regex)` declares one called `regex`.

A newtype is **transparent to its base's methods** — `newtype Name = string` supports `len`/`slice`/`trim`, builtins and prelude `self:` functions alike. The fallback is tried after every other rung, so a method written for the newtype still wins.

**Except the overflow-arithmetic family** (`lyra-E043`): `wrapping_*`/`saturating_*`/`checked_*` stop at the wrapper, because they are the *operators'* escape hatches and arithmetic on a newtype is opt-in. Two paths through: an operator impl (`impl Add for Cents` dispatches), or converting to the base (`i64(c)`) — newtype → *other* newtype has no path at all. Float rounding (`floor`/`ceil`/`round`) stays transparent, being a conversion's alternative rather than an operator's. `println(c)` refuses; `impl Show for Cents` is the answer, since print is where transparency would erase the name the newtype carries.

## Effect Bounds Are Written, Not Inferred

`pure`, `det` and `noalloc` are annotations a caller can rely on, and the compiler infers the same facts internally — which is why an unwritten bound is easy to mistake for a harmless omission. `lyra-W018` reports a top-level function or trait-impl method with no observable effect that does not say `pure`.

**Nothing is refused today.** Purity is inferred whole-program, so a `pure` function may call an unannotated one whose body the compiler cleared. The bound costs on the *next* edit, and what it decides is **where the blame lands**:

```lyra
let helper = (n: i64) -> i64 => { println("added later"); n * 2 }
let caller = pure (n: i64) -> i64 => helper(n)
```

The `println` is reported at `caller`, the only thing in the program that promised anything. Mark `helper` and it is reported at the `println` — at the edit, in the function being looked at.

**Only `pure` is warned about.** Measured on the same code, `det` fires on roughly a sixth of all functions and `noalloc` on two-fifths, with nearly every `det` candidate a terminal-escape wrapper that qualifies only because `det` permits output by design. Advice landing on every print helper is advice nobody reads.

An inline closure is never warned about — it is an expression, not an interface — nor is `main`, which nothing calls, nor an impl method whose *trait* already declares the bound. There is no `#[allow]`-shaped suppression in the language, which is why this is a warning: an author about to add an effect is entitled to leave the bound off.

## Operator Overloading

Arithmetic and bitwise operators are overloadable, comparisons are not, and the split is the point. `+ - * / % << >> & | ~`, prefix `-` and `~`, and the compound assignments dispatch to a trait method named for the operator:

```
trait Add { (_+_): (Self, Self) -> Self }
impl Add for Vec2 { (_+_) = (self, o) => Vec2 { x: self.x + o.x, y: self.y + o.y } }
```

**The trait is the author's — the compiler knows no name here**, so the dispatch key is the method name and two traits providing one operator for one type is an ambiguity, reported at the operator. `Eq`/`Ord` are the opposite: they *are* the comparison operators, `<` and `<=>` must agree, so one trait owns them and `(_==_)` as a method name is `lyra-E039`. Both are marked `@builtin(Ord)`/`@builtin(Eq)` in the prelude, so the compiler finds them by identity rather than by spelling and a program's own `trait Ord` stays an ordinary trait.

**A primitive is never routed through an impl**: `1 + 1` is a machine add whatever a program declares. "Primitive" means the receiver *unstripped*, so a newtype over a scalar **is** routed through its impl and `impl Add for i64` is inert. An operator is a call, so `pure`/`det`/`noalloc` charge it as one.

Still inert, each with its own reason in the warning: `&&`/`||` (a call cannot short-circuit), `!` (boolean negation, no user truthiness), `**` (a spelling with no operator — its mirror `%%` is an operator with no spelling), and the suffix `_++`/`_--`.

An operand whose type is a *type parameter* resolves through a `where` bound — `let sum<t> where t: Add = (a: t, b: t) -> t => a + b` — the same abstract dispatch a bound `.method()` call takes.

`Cents(150) + Cents(275)` (a constructor call as a math operand) and `(a + b).x` (a parenthesized binary expression as a postfix head) both parse. Each node has exactly **one** derivation path; adding a second is an unresolved reduce-reduce at every operand position — see the grammar repo's partition rule.

**`min`, `max` and `clamp` are the prelude's, over `where t: Ord`**, with a `self` receiver so `a.min(b)` and `min(a, b)` are one call. `min` keeps `self` on a tie and `max` takes `other`, so the pair still names both values when two compare equal but differ; `clamp` traps on `lo > hi`, an empty range with no nearest value to answer with. The prelude implements `Ord` for the ten integer widths and `rune` **so the bound can be satisfied**, not so a call can dispatch — `3 < 5` stays a machine compare. **Floats are excluded**: `<=>` refuses them because NaN orders against nothing, and inventing a total order here would have every generic inherit the guess, so `min(1.5, 2.5)` is a compile error while `if a < b { a } else { b }` on concrete floats is fine.

## Supertraits

`trait B: A` means two things, and both hold: **every implementer of `B` must implement `A`** (`lyra-E040`, checked at each `impl`), and **a `where t: B` bound reaches `A`'s methods** — `v.foo()` resolves, and `v` satisfies a callee bounded `where u: A`.

A **cycle is legal** — `trait A: B` alongside `trait B: A` — and says the two are always implemented together, which is exactly what the obligation then requires of every implementer.

The shape that motivates the feature is an **umbrella** trait, one with no methods of its own:

```lyra
trait Arithmetic: Add + Sub + Mul + Div      // or `… { }`; the body is optional
impl Arithmetic for Vec2
let combine<t> where t: Arithmetic = (a: t, b: t) -> t => a * b + a
```

A trait's body is optional, braces and all; the bodiless spelling is the one to reach for, since there is no body to delimit. The umbrella's impl is still required and still checked: `impl Arithmetic for Vec2` is what triggers the obligation, so a type missing `Mul` is refused there rather than at the call.

## Trait Default Methods

A trait method may carry a body, which an impl inherits by writing nothing and overrides
by writing a clause:

```lyra
trait Named {
  pure name: (Self) -> string
  pure shout: (Self) -> string = (self) => self.name() ++ "!"
}
impl Named for Cat { name = pure (self) => "cat" }   // Cat.shout() is "cat!"
```

**A default is generic code.** `Self` is a type variable bounded by the declaring trait, so
the body is checked once and compiled per implementing type — which is why it may call any
method the trait declares, or that one of its **supertraits** declares, and why calling
anything else is an error at the trait rather than at each impl.

An impl that provides the method wins; dispatch tries an impl's own clauses first and
reaches the default only when they match nothing. A default calling another default reaches
that method's *override* where one exists, so the two compose the way a reader expects.

**The bound the trait declares is enforced on the default**, and reported there — a
`pure shout` whose default prints has broken the contract at the declaration, and blaming
each impl that inherited it would blame code that wrote nothing.

**A bound the default body *needs* goes on the trait as a supertrait.** A trait method has no
`where` clause and `Self` is not a name a program can constrain, so `trait Doubled: Show` is
how a default demands something of every implementer — which is exactly what the supertrait
obligation then requires of each `impl`.

## Calling on a Receiver

Two related features, both opted into by naming a function's first parameter `self`:

- **UFCS** (call side): `m.unwrap_or(0)` resolves to the free function `unwrap_or(m, 0)`. The call is rewritten to pass the receiver as argument 0 before anything downstream sees it, so nothing after the typechecker knows UFCS exists. An `own` receiver is refused, so a move always looks like a call; calling into another module method-style needs an import. **A receiver whose type is a type parameter resolves too**, against a function generic in its own receiver — so `a.max(b)` inside `where t: Ord` is the prelude's `max`, and the two spellings of one call agree in generic code as they do in concrete code.
- **Receiver-keyed overloading** (declaration side): a module may declare one name several times when each declaration takes a `self` receiver and their receiver *type heads* differ — `Maybe<t>` beside `Result<t,e>` is allowed, a second `Maybe<…>` is refused where it is written, since ranking two matching candidates would need a specificity ordering the language does not have. The prelude uses it for `unwrap_or`/`unwrap_or_else`.

Without the second, `Maybe` and `Result` could each be *called* with `map` but only one of them could have a `map` *written* in a given module. Details in `lyra/pkg/analyzer/typechecker/README.md`; a name still may not be exported by two modules at once (`lyra/todo.md`, Modules).

## Show

`print` and `"${…}"` pick a formatter per *concrete* type, so a value whose type is a **type parameter** could not be rendered at all. A `where t: Show` bound fixes that:

```
let describe<t> where t: Show = (v: t) -> string => "value ${v}"
```

The trait and an impl for every printable scalar are **ordinary Lyra** in `std/prelude/show.lyra` — `"${self}"` on a concrete primitive is the formatter `print` already picks, so nothing here is a builtin. The compiler's half is a desugar: the operand is rewritten to `v.show()`, the bound dispatch that already existed.

**The trait is recognized by its method, not its name** — any in-scope bound declaring `show` will do, so a program may define its own. `Show` is what the *diagnostic* suggests, because it is what the prelude ships.

A **concrete** type with a `show` impl prints the same way. Two rules keep that safe: a printable primitive always takes the built-in formatter, and the rewrite never targets the method it is inside — `impl Show for Pt { show = (self) => "${self}" }` is refused rather than compiled into infinite recursion.

## Documentation Comments

`///` documents the declaration below it; `//!` documents the module the file belongs to. The body is **Markdown**, with no `@param`/`@returns` tags — the signature is already in the AST, so a tag restating it is a second copy that goes stale.

Three headings are **recognized**, matched case-insensitively and in the singular: `# Examples`, `# Panics`, `# Errors`. A renderer gives them a house style and a generator can index every `# Panics` in the standard library. An unrecognized heading is still a heading, simply not classified; `# Panics` and `# Errors` are separate because the split is the language's own (a trap ends the program, an `Err` is a value the caller handles). A heading inside a fenced code block is not a heading.

**Six things carry documentation**, and they are exactly the declarations: a top-level `let`/`var`/`const`, a `type`, a `trait`, an `impl`, and — as members — a struct's fields, a data type's constructors, a trait's method signatures and an impl's methods. Nothing else does.

**Documentation attaches to declarations, not to types.** A field's doc lives on the `struct` declaration that names it (`TypeDeclStmt.MemberDocs`), never on `types.StructField` — so an anonymous struct's field cannot carry one, and two structurally identical types stay structurally equal.

**Attachment is adjacency, and a doc that attaches to nothing warns** (`lyra-W017`): a blank line between the block and the declaration, a `///` at end of file, one on a local `let`, a `//!` after the first declaration. A blank line is the only signal an author has for "this is about the file, not the next declaration". A warning rather than an error, because a doc block above a temporarily commented-out declaration is an ordinary state to be in for a minute. The corollary: **an implementation note goes above the doc block, never between it and the declaration**, since an ordinary `//` in between detaches it.

**`//!` rather than a `///` above the `module` line**, because a module is a file *or a directory*: a directory module has no single header to sit above. It may sit at the top of the file or directly under the `module` line. Several files' headers are joined in file order, keyed by module path (`SymbolTable.ModuleDocs`), so the module's summary is the first file's.

**A `////` divider rule is an ordinary comment**, not documentation.

Docs surface in LSP hover, under the type, and **`lyrac doc` renders them** — one Markdown page per module, with Starlight frontmatter, so the standard library's reference page is generated rather than written:

```bash
lyrac doc std/prelude/prelude.lyra -o ../lyra-website/src/content/docs/reference --strict
```

`--private` includes unexported declarations, `--deps` follows imports, `--prelude` adds the standard library, `--strict` fails on a gap. An undocumented public declaration is still listed with its signature — omitting it would make the page misrepresent the module's surface — and coverage prints on every run.

**A signature on a page must parse as Lyra**, which is not free: the compiler's own type names are written for diagnostics (`DynamicArray<string>`, `boolean`) and a `ParameterizedType` renders as `Maybe` rather than `Maybe<t>`. `pkg/docgen` renders source syntax, and a test feeds every generated signature back through the parser.

## Console I/O

Output is `print`/`println`, polymorphic over the printable scalars. **Input is `read_line() -> Maybe<string>`**: one line from stdin, terminator removed (a trailing `\r` with it), `None` at EOF.

`Maybe`, not `string`, because EOF must be distinguishable from a blank line — both are `""` otherwise, so the natural read loop never terminates once stdin closes. Its companion `parse_i64` (`(self: string) -> Maybe<i64>`, so `line.parse_i64()`) is strict: `None` for a blank line, a lone sign, trailing garbage, surrounding whitespace, or a value outside the i64 range. Out-of-range is a `None` rather than an overflow trap — parsing is where a program meets input it did not choose.

**The division of labour between them is the rule to follow when adding more.** `read_line` is a compiler builtin because it *has* to be — the line comes from libc and Lyra has no FFI. `parse_i64` is ordinary Lyra in `std/prelude/parse.lyra` because it can be. Anything expressible in the language goes in the prelude; the builtin registry stays whatever is genuinely primitive.

## The Terminal

Four builtins, and they are the whole of what an interactive TUI needs from the compiler:

- `set_raw_mode(on: bool)` — echo, line buffering and signal generation off, so a keypress is readable the moment it happens;
- `read_key() -> Maybe<rune>` — one **code point**, `None` at EOF;
- `terminal_size() -> (i64, i64)` — **(columns, rows)**, width first;
- `wait_for_key_ms(timeout: i64) -> bool` — wait up to `timeout` ms and say whether input is readable.

**Only input needed the compiler.** `\e` and `\x1b` both reach stdout as byte 27, so ANSI colour, cursor positioning, clear-screen and the alternate buffer are ordinary `print` calls. What no prelude code can fix is that `read_line` waits for Enter — that is the terminal's line discipline, and turning it off is a syscall. Everything above these four (decoding `\e[A` into "up arrow", colour helpers, box drawing, frame diffing) is ordinary Lyra in `std.tui`, and as of 08/22 all of it is written: `frame.lyra` diffs a frame **by row** and gives consecutive changed rows one cursor move, `box.lyra` returns box pieces a caller assembles, `status.lyra` has `status_bar`/`status_split`. A row diff rather than a cell diff because a row carries escape sequences and nothing can tell which of its runes are visible cells.

`read_key` answers a code point rather than a byte, so a multi-byte character is one key instead of two broken ones. It does **not** decode escape sequences: an arrow key arrives as ESC, `[`, `A` in three calls.

`wait_for_key_ms` exists because `\e` begins every escape sequence, so a decoder must look at what follows — with only a blocking read, a lone Escape waited for the *next* keypress. It also lets a program poll instead of block, which is how a viewer redraws on a resize with no key pressed. **A bool rather than a timed read**: three outcomes (a key arrived, nothing yet, input ended) do not fit a `Maybe<rune>`'s two answers. A closed descriptor reports readable, so the two compose exactly. A negative timeout clamps to zero.

**The four do not carry the same effect.** `set_raw_mode` is EffectOutput and so `det`-legal — it changes the world rather than reading it — while `read_key`, `wait_for_key_ms` and `terminal_size` are EffectInput. The size is the surprising one: it reads no input and returns the same pair all day, but the window can be resized between two calls, and a viewer that redraws on resize depends on exactly that.

**The mouse needs no builtin at all**: a terminal reports clicks as escape sequences *on stdin*, so enabling is a `print` and receiving is `read_key`. One constraint falls out of `read_key` answering a code point — it must be **SGR mode** (`\e[?1006h`), whose fields are ASCII digits. Legacy X10 sends three raw bytes, so a column past 95 is a byte ≥ 128, which `read_key` decodes by swallowing the two bytes after it and losing the column and row together.

**`std.tui` coordinates are 0-based**, both ways: `MouseEvent`'s `col`/`row` and `move_to(col, row)`. The terminal itself counts from one, and the two functions that touch an escape sequence are the only things that know — `mouse_event` subtracts the one, `move_to` adds it back. So a click indexes `grid[row][col]` with no arithmetic and a loop written `0..<rows` compares against it directly, which is the rest of the language's convention rather than the terminal's.

Neither of the last two can fail into nonsense. `terminal_size` answers 80x24 where there is no window, so a piped run still renders; `set_raw_mode` saves the original termios on the first enable and restores *that* on disable, rather than handing the caller a token to keep safe.

## Randomness

`random_seed() -> u64` (one word of OS entropy) is the **only** builtin; the generator is ordinary Lyra in `std/prelude/rand.lyra`:

- `rng_seeded(seed)` / `rng_from_entropy()` build an `Rng`;
- `rng.next_u64()`, `rng.below(bound)` (half-open), `rng.between(lo, hi)` (inclusive) draw from one;
- `random_below(bound)` / `random_between(lo, hi)` are ambient one-liners that seed a fresh generator per call.

`below` rejects the top partial bucket rather than taking a modulo, so a draw is unbiased. The algorithm is xorshift64*, chosen for legibility — **not** suitable for anything security-sensitive, and seeding it from the OS does not change that.

**Keeping the seed as the primitive is what lets `det` code use randomness, and no rule enforces it — it falls out of effect inference.** A seeded generator only mutates its own receiver (`EffectMut`, which `det` permits), so a seeded draw is reproducible and `det`-legal; `rng_from_entropy`/`random_below` reach `random_seed`, so inference gives them `EffectRand` and `det` refuses them. Asking for a seed you were not given is the non-deterministic act, and that is the one place the bit is charged.

## Float Math and Formatting

Rounding is `floor`/`ceil`/`round`, each answering an **i64** — they are the escape hatch the lossy-conversion error points to, since `i64(x)` on a float is refused. An out-of-range result **traps**: `fptosi` is poison rather than saturating in LLVM, so `(1.0e20).floor()` would otherwise answer 0 under one optimization level and `i64::MIN` under another. A NaN traps on the same edge.

`log` (natural), `log2`, `log10` and `sqrt` each answer the receiver's **own** width. They are builtins on the `random_seed` rule rather than the `parse_i64` one — none is expressible in the language, having no series, no table and no FFI to reach libm. The three logarithms ship together because smooth mandelbrot coloring is `n + 1 - log2(log(|z|))`, and because the trio makes the bare name's base unambiguous by contrast. Outside their domains they answer IEEE's value — `log(0)` is `-inf`, `log(-1)` and `sqrt(-1)` are NaN — the same choice float division makes; the trap comes later, at the integer conversion, and in one place.

**`to_fixed(places)` is the precision knob `print` deliberately lacks** (ordinary Lyra, in `std/prelude/format.lyra`). The built-in formatter writes the shortest rendering that reads back as the same value, which is right for inspecting a number and wrong for a column of them — `1.0 / 3.0` prints seventeen digits, and a small magnitude switches to scientific notation. `zoom.to_fixed(4)` is `0.3333` and never switches notation.

## The Clock

`wall_clock_nanos() -> i64` is `clock_gettime(CLOCK_REALTIME, …)` and nothing else — the same rule randomness follows, so seconds, elapsed durations and formatting are left to the prelude. Signed, because the useful operation on two instants is subtraction; the unit is in the name because a clock returning a bare number invites a guess that fails silently.

Ambient reads carry `EffectTime`, so `pure`/`det` refuse them; a timestamp threaded in as a parameter is ordinary data, which is the same split that lets `det` code use a seeded `Rng`.

## Strings

UTF-8, an immutable `{ptr, byte_len, rune_count}` fat pointer. Everything the *language* exposes is **rune-indexed**; the byte length is the representation's.

**A NUL sits one byte past every string's bytes**, at `data[byte_len]`. Nothing in the language reads it — the length stays authoritative, so an interior NUL is still a legal byte and every operation is what it was — and it exists so a string can be handed to C **without copying it**: `s.cstring_ptr()` is an `unsafe` builtin that checks for an interior NUL and yields the address, and `std.ffi`'s `with_cstring` is one line over it and now `pure noalloc`. Crossing used to mean an allocation and two passes per call; measured, **146 ns → 8 ns** for a 26-byte string. The bytes are immutable and a *literal*'s are genuinely read-only, so a C function that writes through the pointer faults — the type is `^u8` for that reason, and `unsafe` is what stands between.

`s[i]` is the i-th code point (O(i)), `for c in s` walks code points, and `s.len()` is the rune count — **O(1)**, a field read maintained arithmetically at each construction (a literal counts at compile time, `++` adds, `slice` subtracts; only `read_line` and interpolation's formatted segments pay a linear `lyra_utf8_count`). `len` counts runes because the *index* does: a byte length would silently disagree with `s[i]` on the first non-ASCII input.

**The indexed traversal is `for i, c in s`** — rune index and rune from one linear walk. `for i in 0..<s.len() { s[i] }` decodes from the start at every `s[i]`, which is O(n²) and a trap the prelude itself once fell into.

`s.slice(start, end)` is a half-open rune range. It **allocates**, copying into a fresh ref-counted box rather than borrowing its parent's bytes — a box's header sits at its start, so a pointer into the middle cannot reach it — and `noalloc` therefore refuses `slice`, and `trim` with it. `trim`/`trim_start`/`trim_end` are ordinary Lyra in `std/prelude/strings.lyra` and trim the five ASCII whitespace characters, not Unicode's full set.

**A negative index traps; `from_end(k)` is the end-relative accessor** — strings and arrays alike, 1-based: `s.from_end(1)` is the last rune, `xs.from_end(2)` the second-to-last element. A provable negative (a literal, a folded constant) is `lyra-E022`, naming the from_end spelling; a runtime one is caught by the same unsigned bounds compare as everything else. On a string it is a backward byte walk skipping continuation bytes with no decoding. `slice` takes no negative bounds either — a provable one is the same `lyra-E022`, though the message names computing the position (`slice(0, len() - 1)`) rather than `from_end`, since a bound is a position and not an element — and `byte_offset`'s negative position is `None`. The end position `s[n]` is not an index, though `slice(n, n)` is the empty string.

`starts_with`/`ends_with` are **byte-level** — one line each over `s.byte_len()` (O(1)) and `s.compare_bytes_at(offset, other)` (memcmp at a byte offset, comparing exactly `other`'s length, so `== 0` is a prefix test). Not an approximation: UTF-8 is prefix-free and self-synchronizing, so a byte-prefix is exactly a rune-prefix. Both are `pure noalloc`. The rune-indexed version was quadratic — 19.9 ms against 19 µs for a 2000-rune haystack.

`index(needle, offset = 0) -> Maybe<i64>` is a naive scan over `compare_bytes_at`, with `offset` and the result in **rune** indices so the answer feeds straight into `slice` (the scan is byte-level, reconciled by carrying a byte cursor alongside the rune counter). Naive rather than Rabin–Karp deliberately: RK buys only an *expected* bound, and a real guarantee wants a `memmem` builtin.

`index`/`contains`/`split` are **generic over the needle** — `pub trait Needle`, whose `found_at` reports a match as a `(Index, Length)` span (`pub type` aliases of `i64`), implemented for `rune` and `string` and open to user types. A span rather than a fixed step is what `"a::b::c".split("::")` needs. `split` on an **empty separator traps**, naming the fix: `to_runes() -> []rune`.

**`bytes.decode_utf8() -> string`** and **`s.encode_utf8() -> []u8`** are the two ways
across between text and bytes, and both are builtins because they have to be: it allocates a ref-counted box and copies into it, and
concatenation is the only string construction Lyra code has. Without it the spelling was
`s = s ++ "${rune(b)}"` in a loop — one allocation per rune, each copying everything
before it. Measured at 400 KB: 1.44 s that way, 0.02 s this way, and 8× the input costs
24× the time on the loop against no change at all here.

**`p.decode_utf8(byte_len)`** is the same method on a **raw pointer** — memory Lyra does
not own, which is the only kind a `^u8` can address. The length is an argument because a
pointer carries none, which is also why it is `unsafe`: nothing can check that many bytes
are readable, and a negative one traps while a too-large one cannot be caught at all.
`std.ffi`'s `CBuffer` is the checked pairing and its `decode_utf8` is one line over this;
before it, reading a C buffer meant a bounds-checked `get` and a capacity-checked `push`
per byte and then a second full copy (548 µs → 256 µs over 400 KB).

It is named for the *interpretation*: `to_string` on a byte array is ambiguous with
rendering it, since `[104, 105]` as text is either "hi" or "[104, 105]" depending on what
the reader assumed. **It does not validate** — the rune count is the number of
non-continuation bytes, exactly as `read_line` counts libc's — so malformed input yields a
string whose length disagrees with its bytes. One unvalidated answer rather than two
different ones; both are fixed by the same change when it comes.

`encode_utf8` exists for the mirror-image reason: **nothing else can read a byte out of a
string.** `byte_len` measures, `byte_offset` maps a rune position to a byte one and
`compare_bytes_at` compares — none of them reads, and `s[i]` is a rune — so the bytes were
reachable only by re-encoding each rune by hand, a UTF-8 encoder in user code recovering
bytes the string already holds. The result is a `[]u8` rather than a `[N]u8` because the
length is a run-time property, which also makes it `push`-able.

Neither copy is avoidable, and each is the reason rather than the cost. A box's header
sits at its start, so a string cannot point into an array's buffer — and a later `push`
may move that buffer anyway; conversely the bytes must be a copy or a mutable `[]u8`
would be a way to write through an immutable string.

`s.byte_offset(i) -> Maybe<i64>` is the rune→byte conversion, which nothing else in the language can perform — it is what makes "does `sep` occur at rune i" allocation-free. It maps *positions*, so the end position answers `Some(byte_len)` rather than `None`.

A literal *is* a postfix head, so `"abc".len()`, `[1, 2, 3].len()` and `1.wrapping_add(2)` all parse — and so is a **constructor call**, which is what makes `Some(1).unwrap_or(0)` parse. That one did not until 08/22: a constructor call was reachable only as a literal, so the juxtaposition rule read `Some` as applied to `(1).unwrap` and left `_or(0)` to start a statement. A binding receiver worked, which is why every program written before then compiled.

## Raw Pointers

`&x` takes one, `&mut x` takes a writable one, `p^` reads through it and `p^ = v` writes.
All four, and a call to an `unsafe` function, need an enclosing `unsafe { … }` block or
`unsafe` function (`lyra-E011`); unsafe-ness does not leak across a lambda boundary. The
block changes what is *permitted* inside it and nothing else — it is its body, so it takes
a value in value position and a binding declared in it is scoped to it.

**Mutability is two separate questions.** `&mut x` requires **x** to be mutable, the same
rule every interior mutation obeys; `p^ = v` requires **p** to be a `^mut T`
(`lyra-E061`). A `^mut T` may be copied into a `let` and a `^T` may be taken of a `var`, so
neither implies the other.

**Only storage has an address**: a binding, a field or an element. `&f()` is `lyra-E059` —
the temporary stops existing at the end of the statement, so the pointer would dangle
immediately. `^` on a non-pointer is `lyra-E060`.

**Pointer arithmetic is one named method, never an operator**: `p.offset(n) -> ^T`,
measured in **elements**, signed, and propagating mutability so `p.offset(n)^ = v` works
on a `^mut T`. `p[i]` is deliberately not the spelling — it is `xs[i]`'s spelling with
none of `xs[i]`'s bounds check, so two things that behave differently would look alike —
and `^` stays the only load, which makes `p.offset(3)^` visibly the two acts it is.

Nothing about it can be checked, because a raw pointer carries no length. A pointer *and*
a length can be: `std.ffi`'s `CBuffer { ptr, len }` pairs them and `buf.get(i)` traps on a
bad index exactly as `xs[i]` does. Going the other way, `s.cstring()` is a NUL-terminated
`[]u8` the caller keeps alive with the pointer taken at the call site, and `xs.data()` /
`xs.data_mut()` are a buffer's base address — no copy, since a `[]T`'s elements already sit
behind a contiguous `T*`; two functions because `&x` and `&mut x` are two spellings and a
method call has nowhere to put the word, so `data_mut` needs a `mut` receiver. Both trap on
an empty array, and both are dynamic arrays only until const generics let a `[N]T` be a
generic parameter. `with_cstring(s, f)` is the scoped form — it lends a pointer for one
call and takes it back — and is deliberately **not** marked `unsafe`, which is the line the
module draws: *`unsafe` marks handing a pointer out to keep, not lending one for a call.*
`with_cstrings(a, b, f)` is the flat two-string form. All of it is ordinary Lyra written
over the primitive, so `unsafe` appears once in the standard library instead of at every
use. It does not make the pointer
*valid*; a wrong length checks against the wrong number.

There is still **no comparison and no null**, and no way to make a pointer other than `&`.
A raw pointer addresses a binding that exists; producing one from an integer is a separate
feature with its own safety story.

## Calling on a Type Name

There isn't any. `Rng.seeded(42)` is **`lyra-E035`**: Lyra has no type-namespaced associated functions, which is why the prelude's constructors are bare (`rng_seeded`). A trait gets its own message, since `Trait::method(…)` *is* a spelling the language has. Building the feature is open; the diagnostic is not a placeholder for it.

## A Module Is a File or a Directory

`std.prelude` is `std/prelude.lyra` **or** every `*.lyra` directly inside `std/prelude/`. Both forms are the same module — one path, one namespace, one scope — so a module that outgrows a file splits without any of its declarations changing meaning. The shipped prelude is seven files.

**The equivalence is the whole point**, because the obvious alternative is wrong. Receiver-keyed overloading, `pub` and prelude shadowing are all keyed on the *module*, so splitting a grown module into *several* modules silently changes what its names mean: `unwrap_or` for `Maybe` beside `unwrap_or` for `Result` would become a cross-module duplicate.

Every file in a module directory must declare the module; a single-file module needs no header, since its path is its location. A subdirectory is the next path down, not more of the parent. A module offering both forms in one root is an error rather than a silent preference. Entering a compile at one file of a multi-file module brings its siblings — without that, `lyrac check std/prelude/strings.lyra` would analyze a fragment and report the rest of the prelude undefined.

## An Import's Member List Is the Boundary

`import lib.{ listed }` admits `listed` and nothing else — not the module's other exports,
and not its types. A **namespace** import (`import lib`) admits no bare names at all: it
binds `lib.listed`, and if it also admitted bare `listed` the two forms would mean the same
thing and the member list would be decoration. An alias binds only its local name.

Each module resolves through **its own scope, then its imports, then the prelude**, and
stops there — so a name reaches a module because that module asked for it, not because some
other module marked it `pub`. Reaching for an export you did not import names the fix:
*"module `lib` exports it, but this file does not import it; add `import lib.{ … }`"*, which
is a different failure from `pub` being absent and says so.

**A method call is exempt**, structurally rather than by a rule: `b.doubled()` resolves
against the receiver's type, so a method the receiver already justifies needs no import of
the free function it desugars to.

## Shadowing an Imported Name

A module may declare its own version of a name a module it imports exports. The local declaration **wins every bare reference in that module** and warns (`lyra-W016`); the shadowed one stays reachable through the namespace the import already binds (`seq.map`), and no other module is affected. It is one rule with prelude shadowing (`noteAmbientShadow`): every declaration is keyed `<module>::<name>`, and resolution tries the module's own declaration first.

What is still an error is a **second claim on the program-wide name**: two modules exporting one name, including a module re-exporting one it imports. Neither has a local declaration obviously meant to win, so there is nothing for a shadowing rule to prefer.

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
