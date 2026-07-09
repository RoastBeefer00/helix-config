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

        cp -r ${self}/runtime "$out/runtime"

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

          # Themes: install the `default` variant set at the TOP level of the
          # themes dir. Helix loads themes by filename and does NOT recurse into
          # subdirectories, so a file under themes/default/ is never found by
          # name — the built-in theme (without our typed inlay-hint scopes) wins.
          mkdir -p "$DEST/themes"
          for tfile in "$SRC/themes/default"/*.toml; do
            [ -f "$tfile" ] || continue
            install_item "$tfile" "$DEST/themes/$(basename "$tfile")"
          done

          # Tree-sitter query overrides (rstml highlights + Rust injection rule).
          mkdir -p "$DEST/runtime/queries"
          for qdir in "$SRC/runtime/queries"/*/; do
            lang=$(basename "$qdir")
            mkdir -p "$DEST/runtime/queries/$lang"
            for qfile in "$qdir"*.scm; do
              [ -f "$qfile" ] || continue
              install_item "$qfile" "$DEST/runtime/queries/$lang/$(basename "$qfile")"
            done
          done

          # Build the rstml grammar. The helix binary bundles every grammar
          # EXCEPT rstml, so the user runtime grammars dir should contain only
          # rstml.so. A previous `hx --grammar fetch/build` (which ignores its
          # argument and processes ALL grammars) can leave newer, mismatched
          # grammars here that shadow the bundled ones and break highlighting
          # (e.g. svelte: invalid node type "script_element"). Clean everything
          # but rstml, then build — with only rstml's source present, the
          # arg-less `hx --grammar build` compiles just rstml.
          echo ""
          echo "==> Building rstml tree-sitter grammar..."
          GRAMMARS="$DEST/runtime/grammars"
          SOURCES="$GRAMMARS/sources"
          mkdir -p "$SOURCES"
          find "$GRAMMARS" -maxdepth 1 -type f -name '*.so' ! -name 'rstml.so' -delete 2>/dev/null || true
          find "$SOURCES" -maxdepth 1 -mindepth 1 ! -name 'rstml' -exec rm -rf {} + 2>/dev/null || true

          RSTML_SRC="$SOURCES/rstml"
          RSTML_REV="2d4c2bc84a40d99a4e099ff7c6cf7f1bc5dc7806"
          if [ ! -d "$RSTML_SRC/.git" ]; then
            git clone --filter=blob:none https://github.com/rayliwell/tree-sitter-rstml "$RSTML_SRC" 2>&1 | sed 's/^/    /'
          fi
          (cd "$RSTML_SRC" && git checkout "$RSTML_REV" 2>&1 | sed 's/^/    /')
          hx --grammar build 2>&1 | grep -E "(rstml|[Ee]rror)" | sed 's/^/    /'

          mkdir -p "$DEST/steel-pty"
          install_item "$SRC/steel-pty/term.scm" "$DEST/steel-pty/term.scm"

          # Wipe cached plugin clones so forge re-pulls the latest pushed code.
          # forge reuses whatever is already in cog-sources/, which is why stale
          # plugin code otherwise lingers until manually deleted. Keep the two
          # dylib-bearing plugins (and native/) so we don't recompile Rust every
          # time — those rarely change.
          STEEL_HOME="''${STEEL_HOME:-$HOME/.local/share/steel}"
          if [ -d "$STEEL_HOME/cog-sources" ]; then
            echo ""
            echo "==> Refreshing plugin sources (dropping cached clones)..."
            for d in "$STEEL_HOME/cog-sources"/*/; do
              [ -d "$d" ] || continue
              name=$(basename "$d")
              case "$name" in
                steel-pty | helix-file-watcher) : ;;
                *)
                  rm -rf "$d" "$STEEL_HOME/cogs/$name"
                  echo "    refreshed: $name"
                  ;;
              esac
            done
          fi

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
