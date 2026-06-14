#!/usr/bin/env bash
# Sync the whole repo to/from Spark (~/Swarm/swarm). No CI.
#   push (default): local -> Spark, mirror (--delete). Spark matches local.
#   pull:           Spark -> local, additive (no --delete). Brings back results.
# Git is synced; dependency/build/cache dirs are not (see env.sh).
# Caveat: push mirrors. Don't edit git on both sides between syncs.
set -euo pipefail

dir="${1:-push}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/env.sh"

repo_root="$(cd "$here/.." && pwd)"
remote="$(ssh "${SPARK}" "echo ${REPO_REMOTE}")"

case "$dir" in
  push)
    echo ">> push ${repo_root}/ -> ${SPARK}:${remote}/ (mirror)"
    ssh "${SPARK}" "mkdir -p '${remote}'"
    rsync -az --delete "${RSYNC_EXCLUDES[@]}" \
      "${repo_root}/" "${SPARK}:${remote}/"
    ;;
  pull)
    echo ">> pull ${SPARK}:${remote}/ -> ${repo_root}/ (additive)"
    rsync -az "${RSYNC_EXCLUDES[@]}" \
      "${SPARK}:${remote}/" "${repo_root}/"
    ;;
  *)
    echo "usage: sync.sh [push|pull]" >&2
    exit 2
    ;;
esac
echo ">> done"
