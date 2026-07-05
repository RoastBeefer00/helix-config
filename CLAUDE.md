# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Steel (Scheme) plugin for the [mattwparas/helix fork](https://github.com/mattwparas/helix) that adds:
- Full vim-motion emulation in normal/visual/insert modes (`vim/`)
- Embedded terminal with PTY and lazygit support (`term.scm`)
- Reusable components: file tree, recent-file picker, git-status picker, splash screen (`cogs/`)
- Custom keymaps, LSP config, and editor settings (`init.scm`, `helix.scm`)

The plugin is a [forge](https://github.com/mattwparas/steel) package (`cog.scm` defines metadata and dependencies).

## Setup

This project uses [devenv](https://devenv.sh). Enter the dev shell with:

```bash
devenv shell
```

Devenv provides helper scripts:

| Script | What it does |
|---|---|
| `install-steel-forge` | Installs the `forge` CLI from source |
| `install-helix-steel` | Builds helix fork (requires `$HELIX_SRC` set to the clone) |
| `deploy` | Copies `vim/*.scm` → `~/.config/helix/vim/` |
| `dev-setup` | Prints the full setup walkthrough |

Install this package's dependencies into the helix runtime:

```bash
forge install
```

## Architecture

### Entry Points

- **`helix.scm`** — Main library file. Loaded by helix at startup via `load-package`. Registers all sub-packages, provides editor utility functions (`eval-sexpr`, `insert-lambda`, `expanded-shell`, etc.), and wires up keymaps.
- **`init.scm`** — Personal init config. Requires `helix.scm` indirectly; sets keybindings, options, LSP/language definitions, and conditionally shows the splash screen.
- **`vim/init.scm`** — Assembles and exports the full vim keymap via `set-vim-keybindings!`. Also re-exports every vim motion function for use by `helix.scm`.

### Vim Motions (`vim/`)

Each file handles one category of motions. They all share helpers from `vim/utils.scm`.

| File | Responsibility |
|---|---|
| `vim/utils.scm` | Rope/cursor primitives, bracket pair search, word/paragraph boundary logic |
| `vim/key-emulation.scm` | Pre-built `KeyEvent` values used to synthesize key presses |
| `vim/normal-motions.scm` | `h/j/k/l`, `w/b/e`, `f/t/F/T`, `gg/G`, `zz/zt/zb`, undo, search, etc. |
| `vim/visual-motions.scm` | Visual/select mode extensions; `a`/`i` text objects (word, paragraph, brackets, quotes) |
| `vim/delete-motions.scm` | `d{motion}`, `dd`, `da`/`di` text objects |
| `vim/change-motions.scm` | `c{motion}`, `cc`, `ca`/`ci` text objects |
| `vim/yank-motions.scm` | `y{motion}`, `yy`, `ya`/`yi` text objects |

**Text object pattern**: `around`/`inner` variants for word, WORD, paragraph, function, comment, data structure, HTML tag, type definition, test, and all bracket/quote pairs. Adding a new text object means adding it in each of the four motion files (visual, delete, change, yank) and registering it in `vim/init.scm`.

### Terminal (`term.scm`)

Wraps `libsteel_pty` (a Rust dylib via `#%require-dylib`) that exposes a PTY + [vte](https://github.com/nicowillis/vte) virtual terminal emulator. The Scheme side manages:
- Multiple named terminal instances
- A custom Helix component that renders VTE cell data as colored text
- lazygit integration (opens lazygit in a floating terminal, patches a highlight leak in the VTE cell renderer)
- `xplr` file-picker integration

### Cogs (`cogs/`)

Self-contained optional modules, each `require`d via `load-package` in `helix.scm`:

| File | Feature |
|---|---|
| `cogs/keymaps.scm` | `keymap` macro and `merge-keybindings` helpers |
| `cogs/recentf.scm` | Background snapshot of recent files; `:recentf-open-files` command |
| `cogs/file-tree.scm` | File-tree browser with its own keybindings |
| `cogs/git-status-picker.scm` | Picker over `git status` output |
| `cogs/scheme-indent.scm` | Smart indent for `.scm` files |
| `cogs/helix-ext.scm` | Misc helix extension helpers |
| `cogs/labelled-buffers.scm` | Named/labelled buffer management |
| `cogs/picker.scm` | Generic picker component |
| `cogs/component.scm` | Base component struct and rendering utilities |
| `cogs/themes/spacemacs.scm` | Spacemacs color theme |

### Package Manifest (`cog.scm`)

Declares `package-name`, `version`, and `dependencies` (fetched by `forge install`):
- `steel-pty` — the PTY/VTE Rust dylib (required by `term.scm`)
- `helix-file-watcher` — background file watcher

## Steel/Scheme Conventions

- **Prefix imports**: `(require (prefix-in helix. "helix/commands.scm"))` — all calls use `helix.open`, `helix.theme`, etc.
- **`provide`**: every public function must be explicitly exported with `(provide ...)`.
- **`@@doc`** docstrings: `;;@doc` comments above `define` are picked up by the Steel LSP.
- **`load-package` vs `require`**: `load-package` is the helix-level loader that silently continues on failure; `require` is the standard Steel module system.
- The helix Steel API lives in the `helix/` namespace (not in this repo — it's part of the helix fork runtime).
