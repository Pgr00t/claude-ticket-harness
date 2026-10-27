#!/usr/bin/env bash
# Tests for hooks/link-worktree-local-files.sh: no-op in a main checkout, links in a linked worktree,
# the configured list, excludes, idempotence. Throwaway repos only.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../link-worktree-local-files.sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/link-worktree-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n      got: %s\n' "$1" "$2"; }
gitq() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
run_hook() { jq -cn --arg d "$1" '{cwd:$d}' | CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>"$T/stderr"; }

M="$T/main"; mkdir -p "$M"
git -C "$M" init -q -b main 2>/dev/null || { gitq "$M" init; gitq "$M" checkout -b main; }
gitq "$M" config user.email t@t.t; gitq "$M" config user.name t; gitq "$M" config commit.gpgsign false
printf 'tracked\n' > "$M/README"; gitq "$M" add -A; gitq "$M" commit -qm init
printf '# local\n' > "$M/CLAUDE.md"; mkdir -p "$M/.claude" "$M/docs/agents"; printf 'x\n' > "$M/.env"; printf 'y\n' > "$M/docs/agents/a.md"
printf 'CLAUDE.md\n.claude/\n.env\ndocs/agents/\n' >> "$M/.git/info/exclude"

echo "# link-worktree-local-files"
OUT=$(run_hook "$M")
[ -z "$OUT" ] && ok 'a main checkout is a no-op with no output' || bad 'a main checkout is a no-op with no output' "$OUT"

W="$T/wt"; gitq "$M" worktree add -q "$W" -b feature
OUT=$(run_hook "$W")
[ -L "$W/CLAUDE.md" ] && [ -L "$W/.claude" ] && [ -L "$W/.env" ] && [ -L "$W/docs/agents" ] && ok 'the default list is linked into a worktree' || bad 'the default list is linked into a worktree' "$(ls -la "$W")"
[ ! -e "$W/TODOS.md" ] && ok 'a listed path the main checkout lacks is skipped' || bad 'a listed path the main checkout lacks is skipped' "$(ls -la "$W")"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("linked CLAUDE.md .claude docs/agents .env")' >/dev/null 2>&1 && ok 'the session is told what was linked' || bad 'the session is told what was linked' "$OUT"
[ -z "$(git -C "$W" status --porcelain)" ] && ok 'git status in the worktree stays clean' || bad 'git status in the worktree stays clean' "$(git -C "$W" status --porcelain)"
grep -qx 'docs/agents' "$M/.git/info/exclude" && ok 'a bare-path exclude is added for a linked dir that only a dir/ pattern ignored' || bad 'a bare-path exclude is added for a linked dir that only a dir/ pattern ignored' "$(cat "$M/.git/info/exclude")"
OUT=$(run_hook "$W")
[ -z "$OUT" ] && ok 'a second run is silent' || bad 'a second run is silent' "$OUT"

W2="$T/wt2"; gitq "$M" worktree add -q "$W2" -b feature2
printf 'z\n' > "$M/secrets.local"; printf '{"worktree_links":["secrets.local","CLAUDE.md"]}\n' > "$M/.claude/harness.json"
OUT=$(run_hook "$W2")
[ -L "$W2/secrets.local" ] && [ -L "$W2/CLAUDE.md" ] && [ ! -e "$W2/.env" ] && ok 'worktree_links from the main checkout config replaces the default list' || bad 'worktree_links from the main checkout config replaces the default list' "$(ls -la "$W2")"
grep -qx 'secrets.local' "$M/.git/info/exclude" && ok 'a linked file git did not ignore gets an exclude' || bad 'a linked file git did not ignore gets an exclude' "$(cat "$M/.git/info/exclude")"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
