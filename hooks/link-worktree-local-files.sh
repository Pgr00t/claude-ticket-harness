#!/usr/bin/env bash
# SessionStart hook: when the session's cwd is a git worktree, symlink the
# main checkout's local-only (untracked / gitignored) files into it so the
# harness (CLAUDE.md, .claude/, env files, deps) is present. Idempotent.
# Only links what the main checkout actually has; never overwrites.
#
# Config: `worktree_links` in the MAIN checkout's .claude/harness.json lists the paths to link
# (the worktree has no .claude yet, so the main checkout's file is the one read). Default:
# CLAUDE.md .claude docs/agents TODOS.md .env .env.test node_modules.
set -u

INPUT=$(cat 2>/dev/null || true)
DIR="${CLAUDE_PROJECT_DIR:-}"
[ -z "$DIR" ] && DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -z "$DIR" ] && DIR=$(pwd)
cd "$DIR" 2>/dev/null || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
GIT_DIR=$(git rev-parse --absolute-git-dir 2>/dev/null)
COMMON=$(git rev-parse --git-common-dir 2>/dev/null)
case "$COMMON" in /*) ;; *) COMMON="$DIR/$COMMON" ;; esac
COMMON=$(cd "$COMMON" 2>/dev/null && pwd -P)
# Not a linked worktree when git-dir and common-dir are the same place.
[ "$GIT_DIR" = "$COMMON" ] && exit 0

MAIN=$(dirname "$COMMON")
WT=$(pwd -P)
[ "$MAIN" = "$WT" ] && exit 0


# Direct dependencies whose installed version (node_modules/.package-lock.json) differs
# from package-lock.json. Empty output means node_modules matches this branch's lockfile.
stale_node_modules() {
  [ -f package-lock.json ] || return 0
  [ -f node_modules/.package-lock.json ] || { echo "node_modules missing or not installed by npm"; return 0; }
  local q='.packages | to_entries[] | select(.key | test("^node_modules/(@[^/]+/)?[^/]+$")) | select(.value.optional != true) | "\(.key) \(.value.version)"'
  diff <(jq -r "$q" package-lock.json | sort) <(jq -r "$q" node_modules/.package-lock.json | sort) | grep -E '^[<>]' | sed 's/^</wanted:/;s/^>/installed:/' | head -8
}

linked=()
link_one() {  # $1 = relative path
  local rel="$1" src="$MAIN/$1" dst="$WT/$1"
  [ -e "$src" ] || return 0
  [ -e "$dst" ] || [ -L "$dst" ] && return 0
  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst" && linked+=("$rel")
}

LINKS=""
[ -f "$MAIN/.claude/harness.json" ] && LINKS=$(jq -r '(.worktree_links // [])[]' "$MAIN/.claude/harness.json" 2>/dev/null || true)
[ -n "$LINKS" ] || LINKS=$'CLAUDE.md\n.claude\ndocs/agents\nTODOS.md\n.env\n.env.test\nnode_modules'
while IFS= read -r f; do
  [ -n "$f" ] && link_one "$f"
done <<< "$LINKS"

# Python: reuse the main checkout's poetry venv instead of re-installing.
if [ -f "$MAIN/pyproject.toml" ] && [ ! -e "$WT/.venv" ]; then
  VENV=""
  if [ -d "$MAIN/.venv" ]; then
    VENV="$MAIN/.venv"
  elif command -v poetry >/dev/null 2>&1; then
    VENV=$(cd "$MAIN" && poetry env info --path 2>/dev/null || true)
  fi
  if [ -n "$VENV" ] && [ -d "$VENV" ]; then
    ln -s "$VENV" "$WT/.venv" && linked+=(".venv")
    EXCL="$COMMON/info/exclude"
    grep -qx '.venv' "$EXCL" 2>/dev/null || { mkdir -p "$(dirname "$EXCL")"; echo '.venv' >> "$EXCL"; }
  fi
fi

# A symlink is not a directory to git, so "dir/" ignore patterns miss it.
# Add a bare-path exclude for anything linked that git does not already ignore.
EXCL="$COMMON/info/exclude"
for rel in "${linked[@]:-}"; do
  [ -n "$rel" ] || continue
  if ! git check-ignore -q -- "$rel" 2>/dev/null; then
    mkdir -p "$(dirname "$EXCL")"
    grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
  fi
done

STALE=$(stale_node_modules 2>/dev/null || true)
if [ ${#linked[@]} -gt 0 ] || [ -n "$STALE" ]; then
  msg="Worktree of $MAIN: linked ${linked[*]} from the main checkout."
  [ -z "$STALE" ] || msg="$msg WARNING: node_modules does not match this branch's package-lock.json (it was installed for another branch). Tests and tsc will give false results until 'npm ci' runs in the main checkout on this lockfile:"$'\n'"$STALE"
  jq -cn --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m},systemMessage:$m}'
fi
exit 0
