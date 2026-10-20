#!/usr/bin/env bash
set -euo pipefail

# Keep the nix-proper branch rebased on top of upstream main.
#
# Usage: ./scripts/sync-nix-proper.sh

branch="nix-proper"
base="main"

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [[ -n "$(git status --porcelain --uno)" ]]; then
  echo "error: working tree is dirty, refusing to touch $branch" >&2
  exit 1
fi

git fetch origin "$base"
git checkout "$branch"
git rebase "origin/$base"
