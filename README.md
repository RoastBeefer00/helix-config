# helix-config

Personal [Helix](https://helix-editor.com) configuration with vim keybindings, Steel plugins, and a Nix flake for one-command install on any machine.

## What's included

- **Vim emulation** — normal/visual/insert modes, motions, text objects, surround (`vim.hx`, `surround.hx`)
- **Git conflict resolver** — navigate, highlight, and resolve merge conflicts (ours/theirs/both/none) directly on the buffer, with an optional 3-way ours/working/theirs diff view (`space g c` menu, `:conflict-*` commands)
- **HTML/JSX tag support** — tag text objects (`cit`/`cat`/`dit`/`dat`/`yit`/`yat`) and auto-close on `>` (`html.hx`)
- **Cargo.toml version hints** — inline crates.io version + outdated indicators, refreshed on open/save (`crates.hx`)
- **Embedded terminal** — PTY-backed terminal with lazygit and sidekick (AI panel) integration
- **File manager** — Oil.nvim-style file browser (`oil.hx`)
- **Notifications** — statusline notifications (`notify.hx`)
- **Splash screen, focus mode, fidget spinner** — misc UI polish
- Custom keymaps, LSP config, and editor settings

Built on the [evilhelix](https://github.com/RoastBeefer00/evilhelix) fork of Helix with [Steel](https://github.com/mattwparas/steel) scripting support.

## Install

Requires [Nix](https://nixos.org/download) with flakes enabled.

```bash
# 1. Install the hx binary and helix-setup tool
nix profile install github:RoastBeefer00/helix-config

# 2. Deploy config files and install plugins
helix-setup

# 3. Launch
hx
```

`helix-setup` copies config files to `~/.config/helix/` and runs `forge install`, which clones all plugins and compiles native dylibs (`steel-pty`, `helix-file-watcher`) into `~/.local/share/steel/`.

### Updating

```bash
nix profile upgrade --all --refresh
helix-setup --force
```

`--force` overwrites existing config files and refreshes the `steel-pty/term.scm` symlink, which points into the Nix store and goes stale after an upgrade.

## Plugins (managed by forge)

| Package | What it does |
|---|---|
| [`vim.hx`](https://github.com/RoastBeefer00/vim.hx) | Full vim-motion emulation |
| [`surround.hx`](https://github.com/RoastBeefer00/surround.hx) | Vim surround operations |
| [`html.hx`](https://github.com/RoastBeefer00/html.hx) | HTML/JSX tag text objects + auto-close |
| [`crates.hx`](https://github.com/RoastBeefer00/crates.hx) | Cargo.toml crates.io version hints |
| [`lazygit.hx`](https://github.com/RoastBeefer00/lazygit.hx) | Lazygit in a floating terminal |
| [`sidekick.hx`](https://github.com/RoastBeefer00/sidekick.hx) | AI assistant side panel |
| [`fidget.hx`](https://github.com/RoastBeefer00/fidget.hx) | LSP progress spinner |
| [`notify`](https://github.com/chuwy/notify.hx) | Statusline notifications |
| [`oil`](https://github.com/Ra77a3l3-jar/oil.hx) | File manager |
| [`showkeys`](https://github.com/HeitorAugustoLN/showkeys.hx) | On-screen keypress display (loaded, not auto-enabled) |
| [`steel-pty`](https://github.com/mattwparas/steel-pty) | PTY + VTE terminal emulator (Rust dylib) |
| [`helix-file-watcher`](https://github.com/mattwparas/helix-file-watcher) | Background file watcher (Rust dylib) |

The git conflict resolver (`cogs/git-conflict.scm`) lives directly in this repo rather than as a forge plugin.

## Development

This repo uses [devenv](https://devenv.sh). Enter the dev shell:

```bash
devenv shell
```

Then `deploy` symlinks config files into `~/.config/helix/` for live editing without reinstalling.
