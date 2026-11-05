#!/usr/bin/env bash
# Tests for hooks/link-worktree-local-files.sh: no-op in a main checkout, links in a linked worktree,
# the configured list, excludes, idempotence; then a python main checkout with the app's nested worktree
# layout (per-entry .claude links, no cycle), the shared venv and its repoint, and the no-venv message.
# Throwaway repos only.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../link-worktree-local-files.sh}"
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/link-worktree-test.XXXXXX")" && pwd -P)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n      got: %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$(eval "echo $2")"; fi; } # $1 = name, $2 = shell test
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

echo "# a python main checkout with worktrees nested under its .claude/worktrees (the desktop app's layout)"
MAIN="$T/py"; mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main 2>/dev/null || { gitq "$MAIN" init; gitq "$MAIN" checkout -b main; }
gitq "$MAIN" config user.email t@t.t; gitq "$MAIN" config user.name t; gitq "$MAIN" config commit.gpgsign false
gitq "$MAIN" commit -q --allow-empty -m init
mkdir -p "$MAIN/.claude/judge" "$MAIN/.venv" "$MAIN/docs/agents"
echo log > "$MAIN/.claude/loop-results.md"
echo x > "$MAIN/.claude/.hidden"
echo c > "$MAIN/CLAUDE.md"
touch "$MAIN/pyproject.toml"

# 1. A worktree under main/.claude/worktrees: real .claude, per-entry links, no cycle.
NESTED="$MAIN/.claude/worktrees/wt1"
git -C "$MAIN" worktree add -q --detach "$NESTED"
OUT=$(run_hook "$NESTED")
check "nested: .claude is a real directory" '[ -d "$NESTED/.claude" ] && [ ! -L "$NESTED/.claude" ]'
check "nested: loop-results.md is linked to main" '[ "$(readlink "$NESTED/.claude/loop-results.md")" = "$MAIN/.claude/loop-results.md" ]'
check "nested: dotfile entry is linked" '[ -L "$NESTED/.claude/.hidden" ]'
check "nested: judge/ is linked" '[ -L "$NESTED/.claude/judge" ]'
check "nested: no worktrees entry, so no cycle" '[ ! -e "$NESTED/.claude/worktrees" ] && [ ! -L "$NESTED/.claude/worktrees" ]'
check "nested: a recursive walk from main terminates" 'find -L "$MAIN" -maxdepth 12 -print >/dev/null 2>&1 && ! find -L "$MAIN" -maxdepth 12 2>&1 | grep -q "Too many levels"'
check "nested: CLAUDE.md linked" '[ -L "$NESTED/CLAUDE.md" ]'
check "nested: .venv linked to main/.venv" '[ "$(readlink "$NESTED/.venv")" = "$MAIN/.venv" ]'
check "nested: message reports the link" 'printf %s "$OUT" | grep -q "linked"'
check "nested: no junk line in info/exclude" '! grep -q "entries)\|replaced the cyclic" "$MAIN/.git/info/exclude"'

# 2. Idempotent: a second run changes nothing and prints nothing.
OUT2=$(run_hook "$NESTED")
check "nested: second run is silent" '[ -z "$OUT2" ]'

# 3. A new entry in main shows up on the next run.
echo n > "$MAIN/.claude/new-note.md"
run_hook "$NESTED" >/dev/null
check "nested: later main entry is topped up" '[ -L "$NESTED/.claude/new-note.md" ]'

# 4. A cyclic link left by an older run is replaced, and main's .claude is untouched.
OLD="$MAIN/.claude/worktrees/wt2"
git -C "$MAIN" worktree add -q --detach "$OLD"
ln -s "$MAIN/.claude" "$OLD/.claude"
run_hook "$OLD" >/dev/null
check "old link: replaced by a real directory" '[ -d "$OLD/.claude" ] && [ ! -L "$OLD/.claude" ]'
check "old link: main/.claude still has its files" '[ -f "$MAIN/.claude/loop-results.md" ] && [ -d "$MAIN/.claude/judge" ]'
check "old link: no cycle" '[ ! -e "$OLD/.claude/worktrees" ]'

# 5. A real .claude (the app's copy) keeps its own files and only gains what it lacks.
APP="$MAIN/.claude/worktrees/wt3"
git -C "$MAIN" worktree add -q --detach "$APP"
mkdir -p "$APP/.claude"; echo mine > "$APP/.claude/loop-results.md"
run_hook "$APP" >/dev/null
check "app copy: own file kept" '[ ! -L "$APP/.claude/loop-results.md" ] && [ "$(cat "$APP/.claude/loop-results.md")" = mine ]'
check "app copy: missing entry added" '[ -L "$APP/.claude/judge" ]'

# 6. A worktree outside main/.claude has no cycle, so it keeps the single link.
OUTSIDE="$T/elsewhere"
git -C "$MAIN" worktree add -q --detach "$OUTSIDE"
run_hook "$OUTSIDE" >/dev/null
check "outside: .claude is one link to main" '[ "$(readlink "$OUTSIDE/.claude")" = "$MAIN/.claude" ]'

# 7. No venv anywhere: the message says what to run once, the default command or the configured one.
rm -rf "$MAIN/.venv"
NOVENV="$MAIN/.claude/worktrees/wt4"
git -C "$MAIN" worktree add -q --detach "$NOVENV"
OUT7=$(run_hook "$NOVENV")
check "no venv: message gives the default one-time command" 'printf %s "$OUT7" | grep -q "run '"'"'poetry install'"'"' once here"'
printf '{"worktree_venv_hint":"poetry env use /opt/py311/bin/python && poetry install"}\n' > "$MAIN/.claude/harness.json"
NOVENV2="$MAIN/.claude/worktrees/wt4b"
git -C "$MAIN" worktree add -q --detach "$NOVENV2"
OUT7B=$(run_hook "$NOVENV2")
check "no venv: worktree_venv_hint from the config replaces the command" 'printf %s "$OUT7B" | grep -q "run '"'"'poetry env use /opt/py311/bin/python && poetry install'"'"' once here"'
rm -f "$MAIN/.claude/harness.json"

# 7b. A .venv link left by an older run, pointing at a stale venv, is repointed to main's.
mkdir -p "$MAIN/.venv" "$T/oldvenv"
STALEWT="$MAIN/.claude/worktrees/wt5"
git -C "$MAIN" worktree add -q --detach "$STALEWT"
ln -s "$T/oldvenv" "$STALEWT/.venv"
run_hook "$STALEWT" >/dev/null
check "stale .venv link: repointed to main's venv" '[ "$(readlink "$STALEWT/.venv")" = "$MAIN/.venv" ]'
REAL="$MAIN/.claude/worktrees/wt6"
git -C "$MAIN" worktree add -q --detach "$REAL"
mkdir -p "$REAL/.venv"; echo own > "$REAL/.venv/marker"
run_hook "$REAL" >/dev/null
check "real .venv directory: left alone" '[ ! -L "$REAL/.venv" ] && [ -f "$REAL/.venv/marker" ]'
rm -rf "$MAIN/.venv"

# 8. The main checkout itself is left alone.
BEFORE=$(ls -A "$MAIN/.claude" | sort | tr '\n' ' ')
run_hook "$MAIN" >/dev/null
check "main checkout: untouched" '[ "$(ls -A "$MAIN/.claude" | sort | tr "\n" " ")" = "$BEFORE" ]'

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
