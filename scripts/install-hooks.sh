#!/bin/sh
# Point git at the repo-local hooks in .githooks.
# Invoked by the root "postinstall"; safe to re-run and a no-op outside a
# git checkout (CI tarballs, published copies).
set -e

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
script_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Only act when this script lives at the root of the repository that git sees.
[ "$repo_root" = "$script_root" ] || exit 0

current=$(git -C "$repo_root" config --local core.hooksPath 2>/dev/null || true)
if [ "$current" = ".githooks" ]; then
  echo "[hooks] core.hooksPath already set to .githooks"
else
  git -C "$repo_root" config --local core.hooksPath .githooks
  echo "[hooks] installed: core.hooksPath=.githooks"
fi
