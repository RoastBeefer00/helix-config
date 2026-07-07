{ pkgs, lib, config, inputs, ... }:

{
  packages = with pkgs; [
    git
  ];

  scripts = {
    deploy.exec = ''
      SRC="$(git rev-parse --show-toplevel)"
      DEST="$HOME/.config/helix"
      mkdir -p "$DEST"

      for f in helix.scm init.scm term.scm splash.scm focus.scm config.toml languages.toml ignore; do
        if [ -f "$SRC/$f" ]; then
          ln -sf "$SRC/$f" "$DEST/$f"
          echo "  linked $f"
        fi
      done

      for d in cogs themes; do
        if [ -d "$SRC/$d" ]; then
          ln -sfn "$SRC/$d" "$DEST/$d"
          echo "  linked $d/"
        fi
      done

      echo "Deployed $SRC → $DEST (symlinks)"
      echo ""
      echo "Run 'forge install' to install package dependencies."
    '';
  };

  enterShell = ''
    echo "helix-config dev environment"
    echo "  deploy — symlink config files into ~/.config/helix"
  '';
}
