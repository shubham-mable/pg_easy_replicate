{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Ruby Environment
    ruby_3_3

    # System dependencies for Gems (pg, pg_query)
    postgresql
    pkg-config

    # Node.js environment (for JS tooling like prettier, etc.)
    nodejs-18_x # Using LTS version 18
    yarn

    # Version control
    git
  ];

  # Optional: Display versions upon entering the shell
  shellHook = ''
    echo "--- Nix Shell ---"
    echo "Ruby:    $(ruby -v)"
    echo "Bundler: $(bundle -v)"
    echo "Node:    $(node -v)"
    echo "Yarn:    $(yarn -v)"
    echo "-----------------"
    echo "Run 'bundle install && yarn install' if needed."
    export GEM_HOME="$(pwd)/.gem"
    export PATH="$GEM_HOME/bin:$PATH"
    export BUNDLE_PATH="$GEM_HOME"
    export BUNDLE_BIN="$GEM_HOME/bin"

    # Make sure bundle installs gems into the project dir not system wide
    bundle config set --local path '.gem'
    bundle config set --local bin '.gem/bin'
  '';
}