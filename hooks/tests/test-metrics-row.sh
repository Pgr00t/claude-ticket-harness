#!/usr/bin/env bash
# Tests for hooks/metrics-row.py: a dry-run row from a fixture repo with a packet and two verdict
# sections, the ticket key from the branch, the configured key regex, and the no-gh path.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${SCRIPT:-$HERE/../metrics-row.py}"
T=$(mktemp -d "${TMPDIR:-/tmp}/metrics-row-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n      got: %s\n' "$1" "$2"; }
gitq() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"; printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/gh"; chmod +x "$FAKEBIN/gh"; export PATH="$FAKEBIN:$PATH"

R="$T/repo"; mkdir -p "$R/tests" "$R/app" "$R/.claude/judge"
git -C "$R" init -q -b main 2>/dev/null || { gitq "$R" init; gitq "$R" checkout -b main; }
gitq "$R" config user.email t@t.t; gitq "$R" config user.name t; gitq "$R" config commit.gpgsign false
printf 'x\n' > "$R/app/a.py"; gitq "$R" add -A; gitq "$R" commit -qm main; BASE=$(git -C "$R" rev-parse HEAD)
gitq "$R" checkout -qb KEY-7-thing
printf 'def test_a(): pass\ndef test_b(): pass\n' > "$R/tests/test_t.py"; gitq "$R" add -A; gitq "$R" commit -qm 'KEY-7: Add checks for thing'; CHECKS=$(git -C "$R" rev-parse HEAD)
printf 'y\n' > "$R/app/a.py"; gitq "$R" add -A; gitq "$R" commit -qm 'KEY-7: Build thing'
printf 'def test_a(): pass\ndef test_b(): pass\ndef test_c(): pass\n' > "$R/tests/test_t.py"; gitq "$R" add -A; gitq "$R" commit -qm 'KEY-7: Correct check test_c'; HEAD=$(git -C "$R" rev-parse HEAD)
printf '# Judge packet\nCHECKS_SHA: %s\nHEAD: %s\nBASE: %s (origin/main)\nROUNDS: 3\nSPEC_STARTED: 2026-01-02T03:04Z\nINTERRUPTIONS: 0\n' "$CHECKS" "$HEAD" "$BASE" > "$R/.claude/judge/KEY-7-thing.md"
printf '# Judge verdict for KEY-7-thing at x (t)\nUsage: input=10 cache_create=20 cache_read=30 output=40 cost_usd=0.1 duration_s=5\n\nVERDICT: FAIL\n\n# Judge verdict for KEY-7-thing at y (t)\nUsage: input=1 cache_create=2 cache_read=3 output=4 cost_usd=0.1 duration_s=5\n\nVERDICT: PASS\n' > "$R/.claude/judge/KEY-7-thing.verdict.md"

echo "# metrics-row"
ROW=$(python3 -I "$SCRIPT" "$R" KEY-7-thing --mutants 12/2 --qa 0 --session-tokens 999 --dry-run 2>"$T/stderr")
field() { printf '%s' "$ROW" | python3 -I -c 'import csv,sys; cols="repo,ticket,branch,pr,pr_state,round_date,checks,rounds,correct_checks,mutants_run,mutants_survived,judge_fails,qa_bounces,human_approvals,human_review_comments,changes_requested,plan_approved_utc,packet_utc,pushed_utc,pr_opened_utc,pr_merged_utc,plan_to_push_min,open_to_merge_h,spec_started_utc,session_tokens,judge_tokens,interruptions,note".split(","); r=next(csv.reader(sys.stdin)); print(dict(zip(cols,r))[sys.argv[1]])' "$1"; }
[ "$(field ticket)" = "KEY-7" ] && ok 'the ticket key is read from the branch name' || bad 'the ticket key is read from the branch name' "$ROW"
[ "$(field checks)" = "3" ] && ok 'checks counts every test function the branch adds from BASE, Correct checks included' || bad 'checks counts every test function the branch adds from BASE, Correct checks included' "$ROW"
[ "$(field correct_checks)" = "1" ] && ok 'correct_checks counts the Correct check commits' || bad 'correct_checks counts the Correct check commits' "$ROW"
[ "$(field rounds)" = "3" ] && [ "$(field interruptions)" = "0" ] && [ "$(field spec_started_utc)" = "2026-01-02T03:04Z" ] && ok 'rounds, interruptions and spec start come from the packet' || bad 'rounds, interruptions and spec start come from the packet' "$ROW"
[ "$(field judge_fails)" = "1" ] && [ "$(field judge_tokens)" = "110" ] && ok 'judge_fails and judge_tokens are summed over the verdict sections' || bad 'judge_fails and judge_tokens are summed over the verdict sections' "$ROW"
[ "$(field mutants_run)" = "12" ] && [ "$(field mutants_survived)" = "2" ] && [ "$(field session_tokens)" = "999" ] && ok 'the typed values land in their columns' || bad 'the typed values land in their columns' "$ROW"
[ -z "$(field pr_state)" ] && [ -z "$(field pr)" ] && ok 'without a PR number nothing is asked of gh and the PR columns stay blank' || bad 'without a PR number nothing is asked of gh and the PR columns stay blank' "$ROW"

printf '{"ticket_key_regex":"\\\\bT[0-9]+"}\n' > "$R/.claude/harness.json"
gitq "$R" checkout -qb T42-other
ROW=$(python3 -I "$SCRIPT" "$R" T42-other --dry-run 2>"$T/stderr")
[ "$(field ticket)" = "T42" ] && ok 'ticket_key_regex from the config changes how the key is read' || bad 'ticket_key_regex from the config changes how the key is read' "$ROW $(cat "$T/stderr")"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
