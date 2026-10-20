#!/usr/bin/env bash
set -euo pipefail

# Pull the latest upstream main, rebase nix-proper on top of it (keeping
# nix-proper's own flake.nix on any conflict), and build the flake.
#
# Usage: ./scripts/build-nix-proper.sh

branch="nix-proper"
base="main"

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty, refusing to touch $branch" >&2
  exit 1
fi

git fetch origin "$base"
git checkout "$branch"

if ! git rebase "origin/$base" -X theirs; then
  echo "error: rebase hit a conflict -X theirs could not resolve; aborting" >&2
  git rebase --abort
  exit 1
fi

nix build .
