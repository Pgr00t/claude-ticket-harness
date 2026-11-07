#!/usr/bin/env bash
# Tests for hooks/judge-gate.sh: the command filter, the target-repo rules, the packet and lock checks,
# the checks-commit rule, the deploy-surface rule, the green-suite requirement, the time budget, the config
# file, and the judge round trip. Everything runs against throwaway git repos under a temp dir, with fake
# `poetry` and `claude` binaries first on PATH, so no real suite runs and no real judge is started. Nothing
# outside the temp dir is touched.
#
#   bash hooks/tests/test-judge-gate.sh                    # exit 0 when every case passes
#   HOOK=/path/to/judge-gate.sh bash .../test-judge-gate.sh  # test another copy of the script
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="${HOOK:-$HERE/../judge-gate.sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/judge-gate-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

# --- fakes -------------------------------------------------------------------------------------
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/poetry" <<'X'
#!/usr/bin/env bash
# Stands in for `poetry run pytest ...`: prints the canned pytest output the test chose, after an optional
# delay (a slow suite), and exits with FAKE_PYTEST_EXIT (a suite that never ran, such as a missing runner).
[ -z "${FAKE_PYTEST_SLEEP:-}" ] || sleep "$FAKE_PYTEST_SLEEP"
cat "$FAKE_PYTEST_OUT"
exit "${FAKE_PYTEST_EXIT:-0}"
X
cat > "$FAKEBIN/claude" <<'X'
#!/usr/bin/env bash
# Stands in for the headless judge: records its arguments, then answers per FAKE_CLAUDE_MODE.
printf '%s\n' "$*" > "$FAKE_CLAUDE_ARGS"
case "${FAKE_CLAUDE_MODE:-PASS}" in
  notloggedin) echo "Not logged in · Please run /login"; exit 1;;
  empty) echo '{"result":""}'; exit 0;;
  slow) sleep 3; jq -cn '{result:"VERDICT: PASS"}';;
  *) jq -cn --arg r "1. CLAUDE.md PASS"$'\n'"VERDICT: ${FAKE_CLAUDE_MODE:-PASS}" '{result:$r, usage:{input_tokens:1200, cache_creation_input_tokens:300, cache_read_input_tokens:4500, output_tokens:250}, total_cost_usd:0.0421, duration_ms:61400}';;
esac
X
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$PATH"
export FAKE_PYTEST_OUT="$T/pytest.out" FAKE_CLAUDE_ARGS="$T/claude.args" FAKE_CLAUDE_MODE=PASS
green_suite() { printf '..\n2 passed in 0.01s\n' > "$FAKE_PYTEST_OUT"; }
red_suite() { # $@ = FAILED/ERROR lines as pytest -q prints them
  { printf '%s\n' "$@"; printf '%d failed, 1 passed in 0.01s\n' "$#"; } > "$FAKE_PYTEST_OUT"
}
green_suite

# --- fixture repos -----------------------------------------------------------------------------
gitq() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
new_repo() { # $1 = path; python repo on KEY-1-thing with a checks commit, a build commit and a packet
  local R="$1"; mkdir -p "$R"
  git -C "$R" init -q -b main 2>/dev/null || { gitq "$R" init; gitq "$R" checkout -b main; }
  gitq "$R" config user.email t@t.t; gitq "$R" config user.name t; gitq "$R" config commit.gpgsign false
  printf '.claude/\n' >> "$R/.git/info/exclude"
  mkdir -p "$R/tests" "$R/app" "$R/.claude/judge"
  printf '[tool.poetry]\nname = "t"\n' > "$R/pyproject.toml"
  printf 'x = 0\n' > "$R/app/a.py"; printf 'def test_old(): pass\n' > "$R/tests/test_old.py"
  gitq "$R" add -A; gitq "$R" commit -qm 'main'
  gitq "$R" checkout -qb KEY-1-thing
  printf 'def test_new(): assert False\n' > "$R/tests/test_new.py"
  gitq "$R" add -A; gitq "$R" commit -qm 'KEY-1: Add checks for thing'
  printf 'x = 1\n' > "$R/app/a.py"; gitq "$R" add -A; gitq "$R" commit -qm 'KEY-1: Build thing'
  packet "$R"
}
checks_sha() { git -C "$1" log --format=%H --grep='Add checks' -1; }
packet() { # $1 = repo, $2 = HEAD to claim (default: real HEAD), $3 = CHECKS_SHA to claim (default: real), $4 = BASE to claim (default: main)
  local R="$1" H="${2:-$(git -C "$1" rev-parse HEAD)}" C="${3:-$(checks_sha "$1")}" B="${4:-$(git -C "$1" rev-parse main)}"
  printf '# Judge packet: KEY-1-thing\nCHECKS_SHA: %s\nHEAD: %s\nBASE: %s\nROUNDS: 1\n' "$C" "$H" "$B" > "$R/.claude/judge/KEY-1-thing.md"
}
packet_nobase() { # like packet, but without a BASE line, so the gate must fall back to the merge-base with base_ref
  packet "$1"; sed -i.orig '/^BASE:/d' "$1/.claude/judge/KEY-1-thing.md"; rm -f "$1/.claude/judge/KEY-1-thing.md.orig"
}
commit_all() { gitq "$1" add -A; gitq "$1" commit -qm "$2"; }
config() { printf '%s\n' "$2" > "$1/.claude/harness.json"; }  # $1 = repo, $2 = JSON text
deploy_line() { printf 'DEPLOY_AND_PROMOTION: %s\n' "$2" >> "$1/.claude/judge/KEY-1-thing.md"; } # $1 = repo, $2 = text after the label
surface_commit() { # $1 = repo, $2 = path to add on the deploy surface, $3 = its content; commits it and rewrites the packet
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; commit_all "$1" "KEY-1: Build $2"; packet "$1"
}

# --- runner and assertions ---------------------------------------------------------------------
OUT=""; PASS=0; FAIL=0
PUSH="git push"   # built by concatenation so the gate on the machine running the tests never sees it
run_gate() { # $1 = command text, $2 = cwd
  OUT=$(jq -cn --arg c "$1" --arg d "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | bash "$HOOK" 2>"$T/stderr")
}
ok() { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n      got: %s\n' "$1" "$(printf '%s' "$OUT" | head -c 400)"; }
skip() { SKIP=$((SKIP+1)); printf 'skip  %s\n' "$1"; }; SKIP=0
expect_allow() { [ "$OUT" = "{}" ] && ok "$1" || bad "$1 (expected {})"; }
expect_pass() {
  printf '%s' "$OUT" | jq -e '.systemMessage | test("Judge PASS")' >/dev/null 2>&1 && ok "$1" || bad "$1 (expected Judge PASS)"
}
expect_deny() { # $1 = name, $2 = text the reason must contain
  printf '%s' "$OUT" | jq -e --arg s "$2" '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains($s))' >/dev/null 2>&1 \
    && ok "$1" || bad "$1 (expected deny containing: $2)"
}

# ===============================================================================================
echo "# command filter: only a real push in command position enters the gate"
R="$T/filter"; new_repo "$R"; rm "$R/.claude/judge/KEY-1-thing.md"   # a real push here is denied (no packet)
run_gate 'git status' "$R";                       expect_allow 'git status is not a push'
run_gate 'git pushy' "$R";                        expect_allow 'git pushy is not a push'
run_gate "echo \"$PUSH\"" "$R";                   expect_allow 'a push inside a quoted echo argument is not a push'
run_gate $'cat <<EOF\n('"$PUSH"$')\nEOF' "$R";    expect_allow 'a push after a bare ( in a heredoc is not a push'
run_gate 'poetry run pytest -q && echo $?' "$R";  expect_allow 'a command with $ but no push is not a push'
run_gate "$PUSH" "$R";                            expect_deny 'a bare push enters the gate' 'no packet'
run_gate "$PUSH -u origin KEY-1-thing" "$R";      expect_deny 'a push with arguments enters the gate' 'no packet'
run_gate "make ci/check && $PUSH" "$R";           expect_deny 'a push after && enters the gate' 'no packet'
run_gate "true; $PUSH" "$R";                      expect_deny 'a push after ; enters the gate' 'no packet'
run_gate "env GIT_SSH=x $PUSH" "$R";              expect_deny 'env VAR=... before the push enters the gate' 'no packet'
run_gate "echo \$($PUSH 2>&1)" "$R";              expect_deny 'a push inside $( ) enters the gate' 'no packet'
run_gate "git -C \"$R\" push" "$T";               expect_deny 'git -C <repo> push from another cwd enters the gate' 'no packet'
run_gate "git -C $R push -u origin b" "$T";       expect_deny 'git -C <repo> push with arguments enters the gate' 'no packet'
run_gate "cd $R && $PUSH -u origin b" "$T";       expect_deny 'cd <repo> && push from another cwd enters the gate' 'no packet'
run_gate "cd '$R' && $PUSH 2>&1 | tail -3; echo \"push exit: \$?\"" "$T"; expect_deny 'the worktree push form with a pipe and $? enters the gate' 'no packet'
run_gate "$PUSH" "$T";                            expect_allow 'a push from a folder that is not a git repo passes through'
run_gate 'git -C /nonexistent-dir-xyz push' "$R"; expect_deny 'git -C <missing dir> push is refused' 'cannot be entered'
run_gate 'git -C "$WT" push' "$R";               expect_deny 'git -C with an unexpanded variable is refused' 'cannot be entered'
run_gate 'git -C "$WT" push' "$R";               expect_deny 'git -C with an unexpanded variable says the path must be spelled out' 'spell the path out'

echo "# command filter: NAME=value assignments before the push do not hide it (2026-11-07 bypass)"
R="$T/filter-env"; new_repo "$R"; rm "$R/.claude/judge/KEY-1-thing.md"
run_gate "GH_TOKEN=\$(gh auth token --user X) git -C \"$R\" push -u origin KEY-1-thing" "$T"; expect_deny 'NAME=$(...) git -C <repo> push enters the gate' 'no packet'
run_gate "GH_TOKEN=\$(gh auth token --user X) $PUSH -u origin KEY-1-thing" "$R"; expect_deny 'NAME=$(...) push enters the gate' 'no packet'
run_gate "FOO=1 BAR=2 $PUSH" "$R";                expect_deny 'two bare assignments before the push enter the gate' 'no packet'
run_gate "FOO='a b' BAR=\"c d\" $PUSH" "$R";      expect_deny 'quoted assignments before the push enter the gate' 'no packet'
run_gate "FOO=\$BAR BAZ=\${QUX:-1} $PUSH" "$R";   expect_deny 'variable-valued assignments before the push enter the gate' 'no packet'
run_gate "FOO=1 env BAR=2 $PUSH" "$R";            expect_deny 'an assignment before env ... push enters the gate' 'no packet'
run_gate "make ci/check && FOO=1 $PUSH" "$R";     expect_deny 'an assignment-prefixed push after && enters the gate' 'no packet'
run_gate "true; FOO=1 $PUSH" "$R";                expect_deny 'an assignment-prefixed push after ; enters the gate' 'no packet'
run_gate "false || FOO=1 $PUSH" "$R";             expect_deny 'an assignment-prefixed push after || enters the gate' 'no packet'
run_gate "echo x | FOO=1 $PUSH" "$R";             expect_deny 'an assignment-prefixed push after | enters the gate' 'no packet'
run_gate "echo \$(FOO=1 $PUSH 2>&1)" "$R";        expect_deny 'an assignment-prefixed push inside $( ) enters the gate' 'no packet'
run_gate "cd $R && GH_TOKEN=\$(gh auth token --user X) $PUSH -u origin b; cd /" "$T"; expect_deny 'cd <repo> && NAME=$(...) push from another cwd enters the gate' 'no packet'
run_gate "FOO=1 git pushy" "$R";                  expect_allow 'an assignment before git pushy is not a push'
run_gate "FOO=1 echo \"$PUSH\"" "$R";             expect_allow 'an assignment before a quoted echo of a push is not a push'

echo "# branches: main and release branches are never gated"
R="$T/branch"; new_repo "$R"; rm "$R/.claude/judge/KEY-1-thing.md"
gitq "$R" checkout main;             run_gate "$PUSH" "$R"; expect_allow 'push on main is not gated'
gitq "$R" checkout -b release/qa;    run_gate "$PUSH" "$R"; expect_allow 'push on release/* is not gated'
gitq "$R" checkout KEY-1-thing;      run_gate "$PUSH" "$R"; expect_deny 'push on a feature branch is gated' 'no packet'

echo "# packet"
R="$T/packet"; new_repo "$R"
packet "$R" "$(checks_sha "$R")";                       run_gate "$PUSH" "$R"; expect_deny 'packet HEAD must be the current HEAD' 'packet HEAD'
packet "$R" "" "0000000000000000000000000000000000000000"; run_gate "$PUSH" "$R"; expect_deny 'packet CHECKS_SHA must be a commit' 'CHECKS_SHA'
packet "$R";                                             run_gate "$PUSH" "$R"; expect_pass 'a correct packet, a clean lock, a green suite and a PASS judge allow the push'
[ -f "$R/.claude/judge/KEY-1-thing.verdict.md" ] && grep -q 'VERDICT: PASS' "$R/.claude/judge/KEY-1-thing.verdict.md" && ok 'the verdict is saved beside the packet' || { OUT="$(ls "$R/.claude/judge")"; bad 'the verdict is saved beside the packet'; }
grep -q -- '--model claude-fable-5-1' "$FAKE_CLAUDE_ARGS" && grep -q -- '--disallowedTools Edit,Write' "$FAKE_CLAUDE_ARGS" && ok 'the judge runs on the default model with Edit and Write disallowed' || { OUT="$(cat "$FAKE_CLAUDE_ARGS")"; bad 'the judge runs on the default model with Edit and Write disallowed'; }
grep -q -- '--allowedTools Read,Grep,Glob,Bash(git diff \*),Bash(git show \*),Bash(git log \*),Bash(git grep \*),Bash(poetry run pytest \*),Bash(npx vitest run \*),Bash(npx tsc \*)' "$FAKE_CLAUDE_ARGS" && ok 'the judge gets the read-only tools plus the default suite runners' || { OUT="$(cat "$FAKE_CLAUDE_ARGS")"; bad 'the judge gets the read-only tools plus the default suite runners'; }

echo "# test-file lock"
R="$T/lock-dirty"; new_repo "$R"
printf 'def test_new(): pass\n' > "$R/tests/test_new.py"; run_gate "$PUSH" "$R"; expect_deny 'an uncommitted test edit is refused' 'uncommitted changes to test files'
R="$T/lock-title"; new_repo "$R"
printf 'def test_new(): pass\n' > "$R/tests/test_new.py"; commit_all "$R" 'KEY-1: Loosen the check'; packet "$R"
run_gate "$PUSH" "$R"; expect_deny 'a test commit after the checks commit without a Correct check title is refused' "not 'Correct check'"
R="$T/lock-foreign"; new_repo "$R"
printf 'def test_old(): assert True\n' > "$R/tests/test_old.py"; commit_all "$R" 'KEY-1: Correct check test_old fixture'; packet "$R"
run_gate "$PUSH" "$R"; expect_deny 'a Correct check touching a test file the checks commit did not is refused' "not this ticket's checks"
R="$T/lock-own"; new_repo "$R"
printf 'def test_new(): assert 1 == 1\n' > "$R/tests/test_new.py"; commit_all "$R" 'KEY-1: Correct check test_new'; packet "$R"
run_gate "$PUSH" "$R"; expect_pass 'a Correct check limited to the checks commit files passes the lock'
R="$T/lock-app"; new_repo "$R"
printf 'x = 2\n' > "$R/app/a.py"; commit_all "$R" 'KEY-1: Tidy'; packet "$R"
run_gate "$PUSH" "$R"; expect_pass 'app commits after the checks commit do not trip the lock'

echo "# suite must be green: every red id is named, and the judge is never asked about the suite"
R="$T/suite"; new_repo "$R"
red_suite 'FAILED tests/test_x.py::TestA::test_b - AssertionError: boom'
rm -f "$FAKE_CLAUDE_ARGS"
run_gate "$PUSH" "$R"; expect_deny 'a red test is refused and named by its whole id' 'tests/test_x.py::TestA::test_b'
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'AssertionError' && bad 'the failure message is stripped from the id' || ok 'the failure message is stripped from the id'
[ ! -e "$FAKE_CLAUDE_ARGS" ] && ok 'the judge is not called when a red test exists (the script owns that fact)' || { OUT="$(cat "$FAKE_CLAUDE_ARGS")"; bad 'the judge is not called when a red test exists (the script owns that fact)'; }
red_suite 'FAILED tests/test_x.py::TestA::test_b - AssertionError: boom' 'FAILED tests/test_y.py::test_c - KeyError: 1'
run_gate "$PUSH" "$R"; expect_deny 'with two red tests the second is named' 'tests/test_y.py::test_c'
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'tests/test_x.py::TestA::test_b' && ok 'and the first is named too' || bad 'and the first is named too'
red_suite 'ERROR tests/test_c.py - ImportError: cannot import name X'
run_gate "$PUSH" "$R"; expect_deny 'a collection error is refused and named by its file path' 'tests/test_c.py'
red_suite 'FAILED tests/test_d.py::test_e'
run_gate "$PUSH" "$R"; expect_deny 'a FAILED line without a message still yields the id' 'tests/test_d.py::test_e'
red_suite 'FAILED tests/test_p.py::test_q[a-b] - assert 1 == 2'
run_gate "$PUSH" "$R"; expect_deny 'a parametrised id with a hyphen inside the brackets is named whole' 'tests/test_p.py::test_q[a-b]'
printf 'tests/test_x.py::TestA::test_b\n' > "$R/.claude/known-failures.txt"
red_suite 'FAILED tests/test_x.py::TestA::test_b - AssertionError: boom'
run_gate "$PUSH" "$R"; expect_deny 'a leftover known-failures.txt no longer excuses a red test' 'tests/test_x.py::TestA::test_b'
rm "$R/.claude/known-failures.txt"
{ printf 'FAILED something the test printed\n'; printf '..\n2 passed in 0.01s\n'; } > "$FAKE_PYTEST_OUT"
run_gate "$PUSH" "$R"; expect_pass 'a FAILED line outside the test paths is test output, not a red id'
green_suite; run_gate "$PUSH" "$R"; expect_pass 'a green suite reaches the judge'
grep -q 'suite summary: 2 passed in 0.01s' "$FAKE_CLAUDE_ARGS" && ok 'the judge prompt carries the suite summary and says the suite was checked mechanically' || { OUT="$(grep -o 'suite summary[^.]*' "$FAKE_CLAUDE_ARGS")"; bad 'the judge prompt carries the suite summary and says the suite was checked mechanically'; }
grep -q 'never rationalise a discrepancy' "$FAKE_CLAUDE_ARGS" && grep -q 'Do not re-judge either' "$FAKE_CLAUDE_ARGS" && ok 'the judge prompt forbids rationalising and re-judging the mechanical checks' || { OUT="(prompt text missing)"; bad 'the judge prompt forbids rationalising and re-judging the mechanical checks'; }
R="$T/other"; new_repo "$R"; rm "$R/pyproject.toml"; commit_all "$R" 'KEY-1: Build thing more'; packet "$R"
run_gate "$PUSH" "$R"; expect_pass 'a repo that is neither python nor web skips the suite and still reaches the judge'

echo "# checks commit is the first test commit after BASE"
R="$T/first-correct"; new_repo "$R"
printf 'def test_new(): assert 1 == 1\n' > "$R/tests/test_new.py"; commit_all "$R" 'KEY-1: Correct check test_new'
packet "$R" "" "$(git -C "$R" rev-parse HEAD)"
run_gate "$PUSH" "$R"; expect_deny 'a packet naming a later Correct check commit as CHECKS_SHA is refused' 'first commit after BASE'
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -qF "$(git -C "$R" rev-parse --short "$(checks_sha "$R")") 'KEY-1: Add checks for thing'" && ok 'and the real checks commit is named with its short sha and title' || bad 'and the real checks commit is named with its short sha and title'
packet "$R"; run_gate "$PUSH" "$R"; expect_pass 'the same branch passes once the packet names the real checks commit'
R="$T/first-build"; new_repo "$R"; packet "$R" "" "$(git -C "$R" rev-parse HEAD)"
run_gate "$PUSH" "$R"; expect_deny 'a packet naming the build commit as CHECKS_SHA is refused' 'first commit after BASE'
R="$T/first-none"; new_repo "$R"; gitq "$R" checkout -q main; gitq "$R" branch -D KEY-1-thing; gitq "$R" checkout -qb KEY-1-thing
printf 'x = 1\n' > "$R/app/a.py"; commit_all "$R" 'KEY-1: Build thing'; packet "$R" "" "$(git -C "$R" rev-parse HEAD)"
run_gate "$PUSH" "$R"; expect_deny 'a branch with no test commit after BASE is refused' 'touches a test path, so there is no checks commit to lock'
R="$T/first-badbase"; new_repo "$R"; packet "$R" "" "" "0000000000000000000000000000000000000000"
run_gate "$PUSH" "$R"; expect_deny 'a BASE line that is not a commit is refused' 'packet BASE'
R="$T/first-nobase"; new_repo "$R"; gitq "$R" update-ref refs/remotes/origin/main main; packet_nobase "$R"
run_gate "$PUSH" "$R"; expect_pass 'a packet without a BASE line falls back to the merge-base with origin/main'
R="$T/first-noorigin"; new_repo "$R"; packet_nobase "$R"
run_gate "$PUSH" "$R"; expect_deny 'a packet without a BASE line in a repo without origin/main is refused, naming BASE' 'no BASE line'

echo "# deploy surface: a change needing a deploy order must carry a DEPLOY_AND_PROMOTION line of ten or more words"
TEN='worker before API on release/qa, else the old worker drops the task'
R="$T/deploy-workflow"; new_repo "$R"; surface_commit "$R" .github/workflows/cd.yml 'on: push'
run_gate "$PUSH" "$R"; expect_deny 'a .github/workflows/ change with no deploy line is refused, naming the path' '.github/workflows/cd.yml'
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'no DEPLOY_AND_PROMOTION: line with at least ten words' && ok 'and the missing line is named' || bad 'and the missing line is named'
deploy_line "$R" "$TEN"; run_gate "$PUSH" "$R"; expect_pass 'the same diff with a ten-word deploy line reaches the judge'
grep -q '7. Deploy and promotion: the DEPLOY_AND_PROMOTION line of the packet must match the diff' "$FAKE_CLAUDE_ARGS" && grep -q 'a line that says none while the diff touches one of those is a FAIL' "$FAKE_CLAUDE_ARGS" && ok 'the judge prompt carries the deploy-and-promotion step' || { OUT="$(grep -o 'Deploy and promotion[^.]*' "$FAKE_CLAUDE_ARGS" | head -c 300)"; bad 'the judge prompt carries the deploy-and-promotion step'; }
grep -q 'found mechanically (none means the diff touches no such path and adds no task or scheduled job): .github/workflows/cd.yml' "$FAKE_CLAUDE_ARGS" && ok 'and lists the touched surface paths' || { OUT="$(grep -o 'found mechanically.*' "$FAKE_CLAUDE_ARGS" | head -c 300)"; bad 'and lists the touched surface paths'; }
R="$T/deploy-api"; new_repo "$R"; surface_commit "$R" app/api/routes.py 'def route(): pass'
run_gate "$PUSH" "$R"; expect_pass 'a diff touching only app/api/ needs no deploy line'
grep -q 'adds no task or scheduled job): none$' "$FAKE_CLAUDE_ARGS" && ok 'and the judge is told the surface is none' || { OUT="$(grep -o 'found mechanically.*' "$FAKE_CLAUDE_ARGS" | head -c 300)"; bad 'and the judge is told the surface is none'; }
R="$T/deploy-alembic"; new_repo "$R"; surface_commit "$R" alembic/versions/0001_add_col.py 'def upgrade(): pass'; deploy_line "$R" 'none, no dependency'
run_gate "$PUSH" "$R"; expect_deny 'an alembic/ change with a three-word deploy line is refused' 'alembic/versions/0001_add_col.py'
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q '(found 3)' && ok 'and the word count is reported' || bad 'and the word count is reported'
R="$T/deploy-decorator"; new_repo "$R"; surface_commit "$R" app/services/jobs.py $'@shared_task\ndef nightly(): pass'
run_gate "$PUSH" "$R"; expect_deny 'a task decorator added outside the surface paths is a deploy surface too' 'app/services/jobs.py'
R="$T/deploy-dockerfile"; new_repo "$R"; surface_commit "$R" Dockerfile 'FROM python:3.11'
run_gate "$PUSH" "$R"; expect_deny 'a Dockerfile change with no deploy line is refused' 'Dockerfile'
R="$T/deploy-makefile"; new_repo "$R"; surface_commit "$R" Makefile 'start:'
run_gate "$PUSH" "$R"; expect_deny 'a Makefile change with no deploy line is refused' 'Makefile'
R="$T/deploy-testword"; new_repo "$R"
printf 'def test_new(): assert "beat_schedule" == "beat_schedule"\n' > "$R/tests/test_new.py"; commit_all "$R" 'KEY-1: Correct check test_new'; packet "$R"
run_gate "$PUSH" "$R"; expect_pass 'the task-pattern grep ignores test files, so a test mentioning beat_schedule needs no deploy line'
R="$T/deploy-config"; new_repo "$R"; surface_commit "$R" app/queue/tasks.py 'def job(): pass'
run_gate "$PUSH" "$R"; expect_pass 'a path outside the default surface needs no deploy line'
config "$R" '{"deploy":{"paths":["app/queue/"]}}'
run_gate "$PUSH" "$R"; expect_deny 'deploy.paths from the config replaces the surface paths' 'app/queue/tasks.py'
config "$R" '{"deploy":{"paths":["app/queue/"],"patterns":"def job"}}'; surface_commit "$R" app/other.py 'def job(): pass'
run_gate "$PUSH" "$R"; expect_deny 'deploy.patterns from the config replaces the task regex' 'app/other.py'
R="$T/deploy-off"; new_repo "$R"; surface_commit "$R" Dockerfile 'FROM python:3.11'; config "$R" '{"deploy":{"paths":[],"patterns":""}}'
run_gate "$PUSH" "$R"; expect_pass 'an empty deploy.paths and an empty deploy.patterns switch the rule off'

echo "# config: .claude/harness.json in the target repo"
R="$T/config"; new_repo "$R"
config "$R" '{not json';                          run_gate "$PUSH" "$R"; expect_deny 'an unreadable config file is refused, not ignored' 'not valid JSON'
config "$R" '{}';                                 run_gate "$PUSH" "$R"; expect_pass 'an empty config keeps every default'
config "$R" '{"kind":"nope"}';                    run_gate "$PUSH" "$R"; expect_deny 'an unknown kind is refused' 'unknown kind'
config "$R" '{"protected_branches":["develop","KEY-*"]}'
run_gate "$PUSH" "$R";                            expect_allow 'a branch matching a configured protected glob is not gated'
gitq "$R" checkout main; run_gate "$PUSH" "$R";   expect_deny 'main is gated once the configured list leaves it out' 'no packet'
gitq "$R" checkout KEY-1-thing
config "$R" '{"judge":{"model":"claude-opus-5-5","extra_allowed_tools":["Bash(make test *)"]}}'
run_gate "$PUSH" "$R"; expect_pass 'a configured judge model and tool list still reach a PASS'
grep -q -- '--model claude-opus-5-5' "$FAKE_CLAUDE_ARGS" && grep -q -- 'Bash(git grep \*),Bash(make test \*) --disallowedTools' "$FAKE_CLAUDE_ARGS" && ok 'the judge model and the extra allowed tools come from the config' || { OUT="$(cat "$FAKE_CLAUDE_ARGS")"; bad 'the judge model and the extra allowed tools come from the config'; }
config "$R" '{"judge":{"extra_allowed_tools":[]}}'; run_gate "$PUSH" "$R"
grep -q -- 'Bash(git grep \*) --disallowedTools' "$FAKE_CLAUDE_ARGS" && ok 'an empty extra_allowed_tools list removes the default suite runners' || { OUT="$(cat "$FAKE_CLAUDE_ARGS")"; bad 'an empty extra_allowed_tools list removes the default suite runners'; }
config "$R" '{"suite":{"command":"printf \"FAILED tests/test_cfg.py::test_z - boom\\n1 failed in 0.01s\\n\""}}'
run_gate "$PUSH" "$R"; expect_deny 'the configured suite command is the one that runs' 'tests/test_cfg.py::test_z'
printf 'FOO=from-env-file\n# comment\n' > "$R/custom.env"
config "$R" '{"suite":{"env_file":"custom.env","env":{"FOO":"ignored-default","BAR":"from-config"},"command":"printf \"%s %s\\n\" \"$FOO\" \"$BAR\""}}'
run_gate "$PUSH" "$R"; expect_pass 'a configured env file and env defaults are exported to the suite'
grep -q 'suite summary: from-env-file from-config' "$FAKE_CLAUDE_ARGS" && ok 'env_file wins over an env default, and an env default fills an unset variable' || { OUT="$(grep -o 'suite summary[^)]*' "$FAKE_CLAUDE_ARGS")"; bad 'env_file wins over an env default, and an env default fills an unset variable'; }
config "$R" '{"kind":"other"}'
run_gate "$PUSH" "$R"; expect_pass 'kind other from the config skips the suite in a repo that looks like python'
R="$T/config-paths"; new_repo "$R"; mkdir -p "$R/spec"; printf 'def test_s(): assert False\n' > "$R/spec/test_s.py"
gitq "$R" add -A; gitq "$R" commit -qm 'KEY-1: Add checks for spec'; packet "$R"
config "$R" '{"test_paths":["spec/"]}'
printf 'def test_s(): pass\n' > "$R/spec/test_s.py"; run_gate "$PUSH" "$R"; expect_deny 'a configured test path is the locked one' 'uncommitted changes to test files'
gitq "$R" checkout -- spec; printf 'def test_new(): pass\n' > "$R/tests/test_new.py"
run_gate "$PUSH" "$R"; expect_pass 'a path outside the configured test paths is not locked'
red_suite 'FAILED spec/test_s.py::test_s - boom'; run_gate "$PUSH" "$R"; expect_deny 'red ids are read under the configured test paths' 'spec/test_s.py::test_s'
green_suite
R="$T/config-base"; new_repo "$R"; gitq "$R" update-ref refs/remotes/origin/trunk main; packet_nobase "$R"
config "$R" '{"base_ref":"origin/trunk"}'; run_gate "$PUSH" "$R"; expect_pass 'base_ref from the config is the fallback when the packet has no BASE line'

echo "# portability: the gate runs on a PATH without coreutils timeout"
MIN="$T/minbin"; mkdir -p "$MIN"
for tool in jq git python3 bash; do ln -s "$(command -v $tool)" "$MIN/$tool"; done
R="$T/notimeout"; new_repo "$R"
OLDPATH="$PATH"; export PATH="$FAKEBIN:$MIN:/usr/bin:/bin"
command -v timeout >/dev/null 2>&1 && NOTE=' (timeout is a system command here, so the fallback is not exercised)' || NOTE=''
run_gate "$PUSH" "$R"; export PATH="$OLDPATH"
expect_pass "a push reaches a PASS with only jq, git, python3 and the system tools on PATH$NOTE"

echo "# judge outcomes"
R="$T/judge"; new_repo "$R"
FAKE_CLAUDE_MODE=FAIL;        run_gate "$PUSH" "$R"; expect_deny 'VERDICT: FAIL refuses the push with the report' 'VERDICT FAIL'
grep -q 'VERDICT: FAIL' "$R/.claude/judge/KEY-1-thing.verdict.md" && ok 'a FAIL verdict is saved too' || { OUT="$(cat "$R/.claude/judge/KEY-1-thing.verdict.md" 2>&1)"; bad 'a FAIL verdict is saved too'; }
FAKE_CLAUDE_MODE=notloggedin; run_gate "$PUSH" "$R"; expect_deny 'a logged-out CLI is reported, not treated as a verdict' 'not logged in'
FAKE_CLAUDE_MODE=empty;       run_gate "$PUSH" "$R"; expect_deny 'an empty judge result is refused' 'did not return a report'
FAKE_CLAUDE_MODE=PASS;        run_gate "cd $R && $PUSH -u origin KEY-1-thing" "$T"; expect_pass 'the target repo is taken from the cd before the push'
V="$R/.claude/judge/KEY-1-thing.verdict.md"
[ "$(grep -c '^# Judge verdict for KEY-1-thing' "$V")" = 2 ] && grep -q 'VERDICT: FAIL' "$V" && grep -q 'VERDICT: PASS' "$V" && ok 'a second run appends a dated section, so the earlier FAIL is kept beside the PASS' || { OUT="$(cat "$V" 2>&1)"; bad 'a second run appends a dated section, so the earlier FAIL is kept beside the PASS'; }
grep -q '^Usage: input=1200 cache_create=300 cache_read=4500 output=250 cost_usd=0.0421 duration_s=61$' "$V" && ok 'each section records the judge usage and cost from the CLI JSON' || { OUT="$(grep -n Usage "$V" 2>&1)"; bad 'each section records the judge usage and cost from the CLI JSON'; }
run_gate "git -C $R push -u origin KEY-1-thing" "$T"; expect_pass 'the target repo is taken from git -C'

echo "# time budget: the gate refuses when it cannot finish inside its own budget, never outliving the hook timeout"
R="$T/budget"; new_repo "$R"
if command -v timeout >/dev/null 2>&1; then
  config "$R" '{"suite":{"timeout":1}}'; FAKE_PYTEST_SLEEP=2 run_gate "$PUSH" "$R"; expect_deny 'a suite that outruns its cap is refused, not waited for' 'the unit suite did not finish within 1 s'
  config "$R" '{"judge":{"timeout":1}}'; FAKE_CLAUDE_MODE=slow run_gate "$PUSH" "$R"; expect_deny 'a judge that outruns its cap is refused, not waited for' 'the judge did not finish within 1 s'
else
  skip 'a suite that outruns its cap is refused (needs coreutils timeout)'
  skip 'a judge that outruns its cap is refused (needs coreutils timeout)'
fi
config "$R" '{"budget":0}';  run_gate "$PUSH" "$R"; expect_deny 'a spent budget refuses before the suite starts' 'budget was spent before the unit suite'
config "$R" '{"budget":30}'; run_gate "$PUSH" "$R"; expect_deny 'a budget too short for the judge refuses before starting it' 'were left when the judge was due to start'
config "$R" '{}'; FAKE_CLAUDE_MODE=PASS run_gate "$PUSH" "$R"; expect_pass 'with the default budget the same branch passes'
BUDGET=$(grep -Eo "cfg '.budget' [0-9]+" "$HOOK" | grep -Eo '[0-9]+$')
# In this repo the example settings are checked; an installed copy of the suite (~/.claude/hooks/tests) has no
# example file next to it and checks the live ~/.claude/settings.json instead, the one that actually runs the gate.
SETTINGS="$HERE/../../settings.example.json"; [ -f "$SETTINGS" ] || SETTINGS="$HOME/.claude/settings.json"
HOOK_TIMEOUT=$(jq -r '[.hooks.PreToolUse[]?.hooks[]? | select(.command | test("judge-gate")) | .timeout] | first // empty' "$SETTINGS" 2>/dev/null)
[ -n "$BUDGET" ] && [ -n "$HOOK_TIMEOUT" ] && [ "$HOOK_TIMEOUT" -ge $((BUDGET * 2)) ] && ok "the hook timeout in $(basename "$SETTINGS") ($HOOK_TIMEOUT s) is at least twice the default budget ($BUDGET s)" || { OUT="budget=$BUDGET hook timeout=$HOOK_TIMEOUT settings=$SETTINGS"; bad 'the registered hook timeout is at least twice the default budget'; }

echo "# a suite that never ran is not green"
R="$T/norun"; new_repo "$R"
printf 'No preset version installed for command poetry\n' > "$FAKE_PYTEST_OUT"
FAKE_PYTEST_EXIT=126 run_gate "$PUSH" "$R"; expect_deny 'a suite command that fails to start is refused with its exit status' 'did not run to a green finish (pytest exit 126)'
printf 'no tests ran in 0.01s\n' > "$FAKE_PYTEST_OUT"
FAKE_PYTEST_EXIT=5 run_gate "$PUSH" "$R";   expect_deny 'a suite that collected nothing is refused' 'pytest exit 5'
green_suite; run_gate "$PUSH" "$R";          expect_pass 'a suite that exits 0 with a passed summary reaches the judge'

echo
if [ "$SKIP" -gt 0 ]; then printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"; else printf '%d passed, %d failed\n' "$PASS" "$FAIL"; fi
[ "$FAIL" -eq 0 ]
