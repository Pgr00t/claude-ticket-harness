#!/usr/bin/env bash
# judge-gate.sh and judge-status.sh each carry a copy of the push-recognition regexes (the status hook cannot
# `source` the gate, which runs the suite and the judge at top level). The copies must stay identical: a push
# shape the gate recognises but the status hook does not would be gated yet never statused, and the reverse
# would be statused "no judge verdict" for a push that was never gated. This test extracts the block between
# the two marker comments from each script and diffs them.
#
#   bash hooks/tests/test-push-regex-sync.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GATE="${GATE:-$HERE/../judge-gate.sh}"; STATUS="${STATUS:-$HERE/../judge-status.sh}"
START='^# --- push recognition'; END='^# --- end push recognition'
block() { sed -n "/$START/,/$END/p" "$1"; }
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }

echo "# the push-recognition block exists in both hooks and is identical"
G=$(block "$GATE"); S=$(block "$STATUS")
[ -n "$G" ] && grep -q '^PUSH_RE=' <<<"$G" && ok 'judge-gate.sh has a push-recognition block defining PUSH_RE' || bad 'judge-gate.sh has a push-recognition block defining PUSH_RE' "got: $(printf '%s' "$G" | head -c 200)"
[ -n "$S" ] && grep -q '^PUSH_RE=' <<<"$S" && ok 'judge-status.sh has a push-recognition block defining PUSH_RE' || bad 'judge-status.sh has a push-recognition block defining PUSH_RE' "got: $(printf '%s' "$S" | head -c 200)"
D=$(diff <(printf '%s\n' "$G") <(printf '%s\n' "$S"))
[ -n "$G" ] && [ -z "$D" ] && ok 'the two blocks are identical' || bad 'the two blocks are identical' "$D"
for v in ASSIGN_RE ENV_RE PUSH_RE PRE_RE; do
  [ "$(grep -c "^$v=" <<<"$G")" = 1 ] && [ "$(grep -c "^$v=" <<<"$S")" = 1 ] && ok "$v is defined exactly once in each block" || bad "$v is defined exactly once in each block" "gate: $(grep -c "^$v=" <<<"$G") status: $(grep -c "^$v=" <<<"$S")"
done
echo "# the block is the only place a push regex lives: no stray grep for git push outside it"
for f in "$GATE" "$STATUS"; do
  STRAY=$(sed "/$START/,/$END/d" "$f" | grep -nE 'grep -Eq .*push\(\[\[:space:\]\]\|\$\)' || true)
  [ -z "$STRAY" ] && ok "$(basename "$f") matches pushes only through PUSH_RE" || bad "$(basename "$f") matches pushes only through PUSH_RE" "$STRAY"
done

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
