{
  description = "Custom Helix editor with vim keybindings and Steel plugins";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Personal helix fork with Steel scripting support, on the combined-features branch.
    # Run `nix flake update helix-steel` to advance to the latest commit on that branch.
    helix-steel = {
      url = "github:RoastBeefer00/evilhelix/local/combined-features";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };

    # The steel workspace — used to build the forge package manager CLI.
    steel-src = {
      url = "github:mattwparas/steel";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    rust-overlay,
    helix-steel,
    steel-src,
    ...
  }: let
    lib = nixpkgs.lib;
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    eachSystem = lib.genAttrs systems;
  in {
    packages = eachSystem (system: let
      pkgs = import nixpkgs {
        localSystem.system = system;
        overlays = [(import rust-overlay)];
      };

      # The custom helix binary (evilhelix fork, --features steel).
      hx = helix-steel.packages.${system}.default;

      # forge CLI built from the steel workspace. helix-setup uses this to run
      # `forge install`, which clones plugins and compiles Rust dylibs (steel-pty,
      # helix-file-watcher) into ~/.local/share/steel/.
      forgeCli = pkgs.rustPlatform.buildRustPackage {
        pname = "steel-forge";
        version = "0-unstable-${steel-src.lastModifiedDate}";
        src = steel-src;
        cargoLock.lockFile = "${steel-src}/Cargo.lock";
        cargoBuildFlags = ["--package" "steel-forge"];
        nativeBuildInputs = [pkgs.perl pkgs.pkg-config];
        buildInputs = [pkgs.openssl];
        doCheck = false;
        meta.mainProgram = "forge";
      };

      # Stable Rust toolchain added to helix-setup PATH so forge can compile
      # the steel-pty and helix-file-watcher dylibs on a fresh machine.
      rustToolchain = pkgs.rust-bin.stable.latest.minimal;

      # Config files bundled into the nix store. helix-setup copies from here
      # so the paths are stable after `nix profile install`.
      configFiles = pkgs.runCommand "helix-config" {} ''
        mkdir -p "$out"

        cp ${self}/config.toml    "$out/config.toml"
        cp ${self}/languages.toml "$out/languages.toml"
        cp ${self}/ignore         "$out/ignore"
        cp ${self}/cog.scm        "$out/cog.scm"

        for f in init.scm helix.scm term.scm splash.scm focus.scm; do
          cp "${self}/$f" "$out/$f"
        done

        cp -r ${self}/cogs   "$out/cogs"
        cp -r ${self}/themes "$out/themes"


        # Our extended term.scm overrides the one bundled inside steel-pty.
        mkdir -p "$out/steel-pty"
        cp ${self}/term.scm "$out/steel-pty/term.scm"
      '';

      setupScript = pkgs.writeShellApplication {
        name = "helix-setup";
        runtimeInputs = [pkgs.coreutils pkgs.git forgeCli rustToolchain];
        text = ''
          FORCE=false
          for arg in "$@"; do
            case "$arg" in
              --force | -f) FORCE=true ;;
              --help | -h)
                echo "Usage: helix-setup [--force]"
                echo "  Copies Helix config to ~/.config/helix and runs forge install."
                echo "  --force  Overwrite existing config files."
                exit 0 ;;
              *) echo "Unknown argument: $arg"; exit 1 ;;
            esac
          done

          DEST="''${XDG_CONFIG_HOME:-$HOME/.config}/helix"
          SRC="${configFiles}"

          echo "==> Installing Helix config to $DEST..."
          mkdir -p "$DEST"

          install_item() {
            local src="$1" dst="$2"
            if $FORCE || [ ! -e "$dst" ]; then
              xattr -cr "$dst" 2>/dev/null || true
              chflags -R nouchg "$dst" 2>/dev/null || true
              chmod -R u+w "$dst" 2>/dev/null || true
              rm -rf "$dst"
              cp -r "$src" "$dst"
              xattr -cr "$dst" 2>/dev/null || true
              chflags -R nouchg "$dst" 2>/dev/null || true
              chmod -R u+w "$dst" 2>/dev/null || true
              echo "    installed: $(basename "$dst")"
            else
              echo "    skipped (exists): $(basename "$dst")  [--force to overwrite]"
            fi
          }

          install_item "$SRC/config.toml"    "$DEST/config.toml"
          install_item "$SRC/languages.toml" "$DEST/languages.toml"
          install_item "$SRC/ignore"         "$DEST/ignore"

          for f in init.scm helix.scm term.scm splash.scm focus.scm; do
            install_item "$SRC/$f" "$DEST/$f"
          done

          install_item "$SRC/cogs"   "$DEST/cogs"
          install_item "$SRC/themes" "$DEST/themes"


          mkdir -p "$DEST/steel-pty"
          install_item "$SRC/steel-pty/term.scm" "$DEST/steel-pty/term.scm"

          echo ""
          echo "==> Running forge install (installs plugins + compiles dylibs)..."
          echo "    Plugins go to ~/.local/share/steel/cogs/"
          echo "    Dylibs (steel-pty, helix-file-watcher) go to ~/.local/share/steel/native/"
          cd "$SRC"
          forge install

          STEEL_HOME="''${STEEL_HOME:-$HOME/.local/share/steel}"
          ln -sf "$SRC/term.scm" "$STEEL_HOME/cogs/steel-pty/term.scm"
          echo "    linked steel-pty/term.scm override"

          echo ""
          echo "Done. Launch helix with: hx"
        '';
      };
    in {
      # `nix profile install github:RoastBeefer00/helix-config` then run `helix-setup`.
      default = pkgs.symlinkJoin {
        name = "helix-with-config";
        paths = [hx setupScript forgeCli rustToolchain];
        meta.mainProgram = "hx";
      };

      inherit hx setupScript configFiles forgeCli;
    });

    apps = eachSystem (system: {
      setup = {
        type = "app";
        program = "${self.packages.${system}.setupScript}/bin/helix-setup";
      };
    });
  };
}
