# Setting up the workspace on Linux

From a fresh machine to Vega and Sheliak running, step by step, for **Ubuntu 26.04 LTS** on
Intel/AMD (x86-64) or ARM (arm64) — the steps are the same on both. On another distribution,
run the same steps inside an [Ubuntu container](#other-distributions-an-ubuntu-container);
Ubuntu 24.04 and older need three packages built by hand (see
[Older Ubuntu](#older-ubuntu-and-debian)).

From step 4 on, every command runs from the workspace root (`lyra-workspace/`); a `cd` is
inside parentheses, so it does not carry over to the next command.

## 0. The machine

- **Intel/AMD or ARM, it makes no difference** — the same packages and commands; the only
  architecture-specific note is one ARM quirk in [Troubleshooting](#troubleshooting).
- **4 cores, 12 GB of RAM** (16 GB to build the Genesis toolchain comfortably) and **60 GB
  of free disk**: the grammar's `parser.c` is ~15 MB of C that the compiler needs real
  memory for, and LLVM is several GB.
- **A GPU with Vulkan drivers.** Vega draws through SDL's GPU API, which on Linux is Vulkan;
  `mesa-vulkan-drivers`, below, covers Intel and AMD graphics. On NVIDIA, use NVIDIA's own
  driver.

## 1. Packages

On 26.04 everything comes from Ubuntu's own repositories — Go 1.26, SDL3 3.4, tree-sitter
0.25, clang 21, Node 22:

```bash
sudo apt update
```

```bash
sudo apt install -y git build-essential clang lld llvm pkgconf zlib1g-dev golang-go nodejs npm \
  libsdl3-dev libsdl3-image-dev libtree-sitter-dev cmake ninja-build curl mesa-vulkan-drivers
```

| Package | For |
|---|---|
| `git` | cloning |
| `build-essential`, `clang`, `lld`, `llvm` | `lyrac` assembles and links with `clang` (`$LYRA_CC` overrides it); the parser is CGO; Dear ImGui is C++ |
| `golang-go` | the compiler and language server (the module needs Go 1.25.4+) |
| `nodejs`, `npm` | the grammar (and the website, which needs Node 22.12+) |
| `libsdl3-dev`, `libsdl3-image-dev` | Vega's and Sheliak's windows, sound and input; the SDL3 bindings' tests |
| `libtree-sitter-dev`, `pkgconf` | `lyrafmt`, which the language server formats with (needs 0.25+) |
| `cmake`, `ninja-build`, `curl`, `zlib1g-dev` | the Genesis toolchain, and the ImGui download |
| `mesa-vulkan-drivers` | Vulkan for Intel and AMD graphics, which Vega draws with |

Check the versions that matter:

```bash
go version && clang --version | head -1 && pkg-config --modversion sdl3 tree-sitter
```

Go must be 1.25.4 or newer, SDL3 3.4 or newer, tree-sitter 0.25 or newer.

## 2. GitHub access

The scripts clone over SSH. `vega` and `sheliak` are **private**: ask for access to both
first, or `setup.sh` reports them as failed and steps 6–9 have nothing to build.

If the machine has no SSH key on GitHub yet:

```bash
ssh-keygen -t ed25519 -C "you@example.com"
```

```bash
cat ~/.ssh/id_ed25519.pub
```

Add that line at GitHub ▸ Settings ▸ SSH and GPG keys ▸ New SSH key, then check it:

```bash
ssh -T git@github.com
```

(Without a key, `./setup.sh --https` clones over https instead; the private repos then need
a GitHub login, e.g. through `gh auth login`.)

## 3. Clone the workspace

Anywhere you like — `~/Dev` is what the examples assume, and it is where the Genesis
toolchain goes by default:

```bash
mkdir -p ~/Dev && cd ~/Dev
```

```bash
git clone git@github.com:Lyra-Language/lyra-workspace.git
```

```bash
cd lyra-workspace && ./setup.sh
```

`setup.sh` clones the seven sub-projects beside each other — `tree-sitter-lyra`, `lyra`,
`lyra-vscode-ext`, `lyra-zed-ext`, `lyra-website`, `vega` and `sheliak` — and ends with a
status line for each. All seven should be ✓. It is safe to re-run; see
[Running setup](README.md#running-setup) for its flags.

## 4. Build Lyra

The compiler (`lyrac`), the language server (`lyra-lsp`), the formatter (`lyrafmt`) and the
C half of the ImGui binding Vega uses:

```bash
(cd lyra && go test ./... && ./build.sh)
```

The first run takes a few minutes; the LLVM backend's
compile-and-run tests cache their binaries after that. **Don't run them while the toolchain
in step 6 builds** — sharing the CPU, a slow package can pass Go's 10-minute test timeout
and fail. One after the other avoids it, or add `-timeout 30m`.

Lyra's Genesis tests skip at this point, saying why — they need the toolchain and Sheliak
from the steps below.

`./build.sh` ends with one line saying what it built. It should name **`lyrafmt`** and
**`lib/liblyra-imgui.a`**; if either says *skipped* or *failed*, the reason is in that line
(usually SDL3 or tree-sitter not found by `pkg-config`, or no network for the ImGui
download). Vega cannot link without `liblyra-imgui.a`.

## 5. Build and test the grammar

```bash
(cd tree-sitter-lyra && npm install && npm run test)
```

Lyra itself does not need this — the generated `parser.c` is committed — but it is how you
know the grammar's toolchain works before you change `grammar.js`.

## 6. Build the Genesis toolchain

Vega builds Genesis ROMs with LLVM's M68k backend, which no distribution ships: this script
clones a pinned LLVM, applies Lyra's patches and builds it into `~/Dev/llvm-m68k`. About
**40–50 minutes on 4 cores**, and 4–5 GB of disk:

```bash
lyra/tools/llvm-m68k.sh
```

It ends with `built: …/llvm-m68k/build/bin/llc`. To put it elsewhere, set `LYRA_M68K_LLVM`
— both when running the script and wherever `lyrac` and Vega run afterwards.

You can skip this step to begin with: Vega and Sheliak build and run without it, but Vega
cannot build a ROM and its checks skip what needs one.

## 7. Build Sheliak and Vega

Both use the compiler from step 4 (`../lyra/build/lyrac`; `$LYRAC` overrides it):

```bash
(cd sheliak && ./build.sh)
```

```bash
(cd vega && ./build.sh)
```

That gives `sheliak/build/sheliak` (and Sheliak's test tools beside it) and
`vega/build/Vega`.

## 8. Run the whole check

With the toolchain and Sheliak both built, nothing below should skip. Lyra's Genesis tests
build ROMs and run them in Sheliak:

```bash
(cd lyra && SHELIAK=$PWD/../sheliak/build/sheliak go test ./cmd/lyrac/)
```

Vega's `--check` exercises the model, the consoles, the files, the export and the interface,
then builds the hero's game and plays it in Sheliak:

```bash
(cd vega && SHELIAK=../sheliak/build/sheliak ./build/Vega --check)
```

It ends with "all passed"; a line beginning `skipped:` names what was missing.

## 9. Run Vega and Sheliak

**Run Vega from its own directory.** It finds the compiler at `../lyra/build/lyrac` and
Sheliak at `../sheliak/build/sheliak`, relative to where it is started (`$LYRAC` and
`$SHELIAK` override them):

```bash
(cd vega && ./build/Vega examples/hero.vega)
```

That opens the hero example, which uses every feature Vega has. Then **File ▸ Run in
Sheliak** builds its ROM and plays it in a Sheliak window. On Linux Vega's menus are a bar
inside its window rather than the desktop's. `./build/Vega` with no project starts a new
Genesis one.

**A ROM without the window** — Vega builds one headless, and Sheliak plays any ROM given on
its command line:

```bash
(cd vega && ./build/Vega examples/hero.vega --rom hero.bin)
```

```bash
sheliak/build/sheliak vega/hero.bin
```

Sheliak's keys (pad 1): arrows; Z, X, C for A, B, C and A, S, D for X, Y, Z; Return for
Start; Q for Mode; F for full screen and Escape to leave it. Gamepads are pads 1 and 2.
Close the window to quit. Its menu bar — open, save states, settings — is macOS-only for
now, so on Linux those are not there yet.

## Keeping it up to date

```bash
./setup.sh --pull
```

fast-forwards every clean repo (dirty or diverged ones are reported and left alone). Then
rebuild in the same order as above — Lyra first, since Sheliak and Vega are compiled by it:

```bash
(cd lyra && ./build.sh) && (cd sheliak && ./build.sh) && (cd vega && ./build.sh)
```

Rerun `lyra/tools/llvm-m68k.sh` when it changes (a moved pin or a new patch); it rebuilds
only what changed.

## Other distributions: an Ubuntu container

On a Linux that isn't Ubuntu — **SteamOS, Fedora, Arch** — the simplest route is to run the
steps above, unchanged, inside an Ubuntu 26.04 container made with
[Distrobox](https://distrobox.it). A Distrobox container shares your home folder, your
display and your GPU, so its programs open windows on your desktop as usual.

**Steam Deck (SteamOS)** — in Desktop Mode, in Konsole. Don't install the packages on SteamOS
itself: its system partition is read-only, and anything `pacman` puts there goes with the
next SteamOS update. Distrobox and Podman come with SteamOS. Set a password for `deck` first
if it has none (`passwd`); `sudo` inside the container needs it. Keep the Deck plugged in,
with sleep off, while the toolchain builds.

Elsewhere, install `distrobox` and `podman` from your distribution's packages.

```bash
distrobox create --name lyra-ubuntu --image docker.io/library/ubuntu:26.04
```

```bash
distrobox enter lyra-ubuntu
```

The first `enter` downloads the image and sets the container up. Then, inside it, follow
steps 1–9 from the top. Your home folder is the same inside and out, so the workspace and
`~/Dev/llvm-m68k` are on the host's disk, and the Genesis toolchain is found as usual. One
complete setup needs roughly 14 GB.

**Run what you built inside the container.** Vega, Sheliak and `lyrac` are linked against
the container's C library (glibc 2.43), which is newer than the host's; started from a host
terminal they fail with a `GLIBC_2.43 not found` error. Enter the container first:

```bash
distrobox enter lyra-ubuntu -- sh -c 'cd ~/Dev/lyra-workspace/vega && ./build/Vega examples/hero.vega'
```

`distrobox-export --bin` (run inside the container) can put a launcher for one on the
host's `PATH`, so it enters the container for you.

To remove all of it later: `distrobox rm lyra-ubuntu`, then delete the workspace and
`~/Dev/llvm-m68k`.

## Older Ubuntu and Debian

On **Ubuntu 24.04 and older, and Debian 12**, three of the packages above are missing or too
old.

- **SDL3** — not packaged; build it from source ([SDL's README-linux](https://github.com/libsdl-org/SDL/blob/main/docs/README-linux.md)
  lists the build dependencies), and SDL3_image the same way. Check
  `pkg-config --modversion sdl3` afterwards.
- **Go** — install 1.25.4 or newer from [go.dev/dl](https://go.dev/dl/).
- **tree-sitter** — the packaged runtime is 0.20, too old for the generated parser (ABI
  15); `pkg-config` finds it and then it refuses the grammar at run time. Build it from
  source, as CI does:

  ```bash
  curl -fsSL https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v0.25.10.tar.gz | tar xz
  ```

  ```bash
  sudo make -C tree-sitter-0.25.10 install PREFIX=/usr/local && sudo ldconfig
  ```

- **Node** — the website needs 22.12+; older releases package an older one
  ([nodejs.org](https://nodejs.org) or `nvm`).

## Troubleshooting

- **A test fails with `panic: test timed out after 10m0s`** — the machine was busy, usually
  with the toolchain build. Rerun it once that has finished, or with `go test -timeout 30m ./...`.
- **`GLIBC_2.43 not found`** — a program built inside a newer Ubuntu container was
  started outside it; see [Run what you built inside the container](#other-distributions-an-ubuntu-container).
- **`setup.sh` fails to clone with a permission error** — no SSH key on GitHub (step 2), or
  for `vega`/`sheliak`, no access to them yet.
- **The parser compile is killed partway** — `src/parser.c` is ~15 MB and `cc1` needs real
  memory; on a machine short of RAM that is an out-of-memory kill. Add RAM or swap. The LLVM build in
  step 6 is the other place this happens; `ninja -C ~/Dev/llvm-m68k/build -j2 …` (the
  targets from the script's last line) trades time for memory.
- **`npm run test` can't find `aarch64-linux-gnu-gcc`** (ARM Linux, with some tree-sitter
  CLI builds) — the prebuilt tree-sitter CLI thinks it
  is cross-compiling. Set `CC` explicitly, and add `export CC=gcc` to your profile to keep it:

  ```bash
  (cd tree-sitter-lyra && CC=gcc npm run test)
  ```

- **`build.sh` says no `liblyra-imgui.a`** — the reason follows it: SDL3 not found by
  `pkg-config`, no network for the pinned ImGui download, or no C++-capable `clang`.
- **Vega or Sheliak can't open a window** — check there is a Vulkan driver
  (`mesa-vulkan-drivers`); over SSH, there is no display to open one on.
- **Vega says it could not start `lyrac` or Sheliak** — it was started from somewhere other
  than `vega/`. `cd vega` first, or set `LYRAC` and `SHELIAK` to absolute paths.
- **Tests behave as if a grammar change never happened** — after regenerating `parser.c`,
  run `go clean -cache` in `lyra/`; Go doesn't hash the `#include`d parser.
