#!/usr/bin/env bash
# Run melpazoid against this package on the host (no Docker required).
#
# melpazoid's `make test` / `make run` targets both shell out to Docker.
# This wrapper reproduces the inner step (running melpazoid.el against the
# package files) directly with the host's Emacs:
#
#   1. Stage every taskjuggler-mode*.el plus snippets/ into a temp dir.
#   2. Invoke emacs --batch --load=melpazoid.el from that dir, which is
#      what the upstream Docker image's CMD does.
#   3. Tear the temp dir down on exit.
#
# Requirements:
#   - A melpazoid checkout. Defaults to ~/repos/melpazoid; override with
#     $MELPAZOID_DIR. Clone with:
#       git clone https://github.com/riscy/melpazoid.git ~/repos/melpazoid
#   - Emacs packages pkg-info and package-lint installed in your user
#     elpa (~/.emacs.d/elpa). Both are on MELPA. Install with:
#       emacs --batch --eval "(progn (require 'package) \
#         (add-to-list 'package-archives \
#           '(\"melpa\" . \"https://melpa.org/packages/\") t) \
#         (package-initialize) (package-refresh-contents) \
#         (package-install 'pkg-info) (package-install 'package-lint))"

set -euo pipefail

MELPAZOID_DIR="${MELPAZOID_DIR:-$HOME/repos/melpazoid}"
MELPAZOID_EL="$MELPAZOID_DIR/melpazoid/melpazoid.el"

if [[ ! -f "$MELPAZOID_EL" ]]; then
    echo "melpazoid.el not found at $MELPAZOID_EL" >&2
    echo "Set MELPAZOID_DIR or clone https://github.com/riscy/melpazoid.git there." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STAGE="$(mktemp -d -t melpazoid-taskjuggler-mode-XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

cp "$REPO_ROOT"/taskjuggler-mode*.el "$STAGE/"
cp -r "$REPO_ROOT/snippets" "$STAGE/"
rm -f "$STAGE"/*.elc

cd "$STAGE"
exec emacs --no-site-file --batch --load="$MELPAZOID_EL"
