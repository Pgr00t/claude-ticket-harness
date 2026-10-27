#!/usr/bin/env bash
# Tests for hooks/format-on-edit.sh: the repo-root walk, the configured formatter with {file}, the
# disabled extension, and the silent exit when nothing applies. Fake tools on PATH; temp dir only.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../format-on-edit.sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/format-on-edit-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n      got: %s\n' "$1" "$2"; }
run_hook() { # $1 = file path as the tool reported it
  jq -cn --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f},tool_response:{filePath:$f}}' | bash "$HOOK" 2>"$T/stderr"; echo "exit=$?"
}

FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/poetry" <<'X'
#!/usr/bin/env bash
printf '%s\n' "poetry $*" >> "$FAKE_LOG"
X
chmod +x "$FAKEBIN/poetry"; export PATH="$FAKEBIN:$PATH" FAKE_LOG="$T/log"

echo "# format-on-edit"
mkdir -p "$T/loose"; printf 'x=1\n' > "$T/loose/a.py"
OUT=$(run_hook "$T/loose/a.py")
[ "$OUT" = "exit=0" ] && [ ! -e "$FAKE_LOG" ] && ok 'a file outside any repo root is left alone' || bad 'a file outside any repo root is left alone' "$OUT $(cat "$FAKE_LOG" 2>/dev/null)"

R="$T/py"; mkdir -p "$R/pkg"; printf '[tool.poetry]\n' > "$R/pyproject.toml"; printf 'x=1\n' > "$R/pkg/a.py"
OUT=$(run_hook "$R/pkg/a.py")
grep -q "^poetry run black -q $R/pkg/a.py$" "$FAKE_LOG" && grep -q "^poetry run isort --profile black -q $R/pkg/a.py$" "$FAKE_LOG" && ok 'a .py file under a pyproject root gets the default black then isort' || bad 'a .py file under a pyproject root gets the default black then isort' "$(cat "$FAKE_LOG")"

rm -f "$FAKE_LOG"; mkdir -p "$R/.claude"
printf '{"formatters":{"py":"echo formatted {file} >> \\"$FAKE_LOG\\""}}\n' > "$R/.claude/harness.json"
OUT=$(run_hook "$R/pkg/a.py")
[ "$(cat "$FAKE_LOG")" = "formatted $R/pkg/a.py" ] && ok 'a configured formatter replaces the default and gets the path for {file}' || bad 'a configured formatter replaces the default and gets the path for {file}' "$(cat "$FAKE_LOG" 2>/dev/null)"

rm -f "$FAKE_LOG"; mkdir -p "$R/pkg/with space"; printf 'x=1\n' > "$R/pkg/with space/b.py"
OUT=$(run_hook "$R/pkg/with space/b.py")
[ "$(cat "$FAKE_LOG")" = "formatted $R/pkg/with space/b.py" ] && ok 'a path with a space reaches the formatter as one argument' || bad 'a path with a space reaches the formatter as one argument' "$(cat "$FAKE_LOG" 2>/dev/null)"

rm -f "$FAKE_LOG"; printf '{"formatters":{"py":""}}\n' > "$R/.claude/harness.json"
OUT=$(run_hook "$R/pkg/a.py")
[ "$OUT" = "exit=0" ] && [ ! -e "$FAKE_LOG" ] && ok 'an empty formatter string disables formatting for that extension' || bad 'an empty formatter string disables formatting for that extension' "$OUT $(cat "$FAKE_LOG" 2>/dev/null)"

rm -f "$FAKE_LOG"; printf '{"formatters":{"py":"exit 3"}}\n' > "$R/.claude/harness.json"
OUT=$(run_hook "$R/pkg/a.py")
[ "$OUT" = "exit=0" ] && ok 'a failing formatter never fails the hook' || bad 'a failing formatter never fails the hook' "$OUT"

C="$T/cfg-only"; mkdir -p "$C/.claude" "$C/src"; printf 'q\n' > "$C/src/x.go"
printf '{"formatters":{"go":"echo go {file} >> \\"$FAKE_LOG\\""}}\n' > "$C/.claude/harness.json"
OUT=$(run_hook "$C/src/x.go")
[ "$(cat "$FAKE_LOG" 2>/dev/null)" = "go $C/src/x.go" ] && ok 'a repo with only harness.json (no pyproject or package.json) is a root too' || bad 'a repo with only harness.json (no pyproject or package.json) is a root too' "$(cat "$FAKE_LOG" 2>/dev/null)"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
