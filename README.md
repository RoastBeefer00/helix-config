# helix-config

Personal [Helix](https://helix-editor.com) configuration with vim keybindings, Steel plugins, and a Nix flake for one-command install on any machine.

## What's included

- **Vim emulation** — normal/visual/insert modes, motions, text objects, surround (`vim.hx`, `surround.hx`)
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
| `vim.hx` | Full vim-motion emulation |
| `surround.hx` | Vim surround operations |
| `lazygit.hx` | Lazygit in a floating terminal |
| `sidekick.hx` | AI assistant side panel |
| `fidget.hx` | LSP progress spinner |
| `notify` | Statusline notifications |
| `oil` | File manager |
| `steel-pty` | PTY + VTE terminal emulator (Rust dylib) |
| `helix-file-watcher` | Background file watcher (Rust dylib) |

## Development

This repo uses [devenv](https://devenv.sh). Enter the dev shell:

```bash
devenv shell
```

Then `deploy` symlinks config files into `~/.config/helix/` for live editing without reinstalling.
