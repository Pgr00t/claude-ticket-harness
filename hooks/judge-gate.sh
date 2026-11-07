#!/usr/bin/env bash
# PreToolUse(Bash) hook: gate `git push` behind (1) a mechanical lock check and
# (2) a headless Claude judge. Allows everything that is not a real git push.
# Output: {} to allow, or hookSpecificOutput.permissionDecision=deny with reasons.
#
# Site-specific values (suite command, protected branches, judge model, ...) come from
# .claude/harness.json in the repo the push targets; every key is optional and the defaults
# below apply when the file or the key is absent. See docs/how-it-works.md, "Configuration".
set -u
GATE_START=$(date +%s)   # the wall-clock budget below counts from the first line, not from the first slow step
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
# Exact match on an actual push command, not the best-effort "if" filter.
# --- push recognition: keep this block identical in judge-gate.sh and judge-status.sh (test-push-regex-sync.sh diffs it) ---
# Command position only: line start, after ; & | && ||, or inside $( ... ). A bare "(" is deliberately not accepted,
# so the hook matcher string quoted inside a heredoc does not count. Any number of NAME=value assignments may precede
# the command, each value a bare word, a quoted string, $VAR, ${...} or $(...): on 2026-11-07
# `GH_TOKEN=$(gh auth token --user X) git -C "/wt" push -u origin b` was not recognised by either hook and reached GitHub
# with no judge run and no commit status. `env NAME=value ... git push` is accepted as before.
ASSIGN_RE='([A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|\$\([^)]*\)|\$\{[^}]*\}|[^[:space:];&|"'"'"'])*[[:space:]]+)*'
ENV_RE='(env[[:space:]]+[^;&|]*[[:space:]])?'
PUSH_RE='(^|[;&|]|&&|\|\||\$\()[[:space:]]*'"$ASSIGN_RE$ENV_RE"'git[[:space:]]+(-C[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:]]+)[[:space:]]+)?push([[:space:]]|$)'
# The text before a plain `git push` (no -C), where the last `cd <path>` names the target repo.
PRE_RE='(^|[;&|]|&&|\|\|)[[:space:]]*'"$ASSIGN_RE$ENV_RE"'git[[:space:]]+push.*$'
# --- end push recognition ---
printf '%s' "$CMD" | grep -Eq "$PUSH_RE" || { echo '{}'; exit 0; }

deny() { jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty'); [ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$CWD" 2>/dev/null || { echo '{}'; exit 0; }
# The push may target another repo than the session's folder: honour `git -C <path> push`
# and the last `cd <path>` that precedes the push in the command text.
TARGET=$(printf '%s' "$CMD" | grep -Eo 'git[[:space:]]+-C[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:]]+)[[:space:]]+push' | tail -1 | sed -E 's/^git[[:space:]]+-C[[:space:]]+//; s/[[:space:]]+push$//; s/^["'"'"']//; s/["'"'"']$//')
if [ -z "$TARGET" ]; then
  PRE=$(printf '%s' "$CMD" | sed -E "s/$PRE_RE//")
  TARGET=$(printf '%s' "$PRE" | grep -Eo '(^|[;&|]|&&|\|\|)[[:space:]]*cd[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:];&|]+)' | tail -1 | sed -E 's/^.*cd[[:space:]]+//; s/^["'"'"']//; s/["'"'"']$//')
fi
if [ -n "$TARGET" ]; then
  TARGET="${TARGET/#\~/$HOME}"
  if ! cd "$TARGET" 2>/dev/null; then
    case "$TARGET" in
      *'$'*) deny "judge gate: the push targets '$TARGET' but that directory cannot be entered from $CWD: the hook reads the command text literally and does not expand shell variables, so spell the path out (git -C /full/path push)." ;;
      *) deny "judge gate: the push targets '$TARGET' but that directory cannot be entered from $CWD." ;;
    esac
  fi
fi
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo '{}'; exit 0; }
cd "$ROOT"

# --- configuration -------------------------------------------------------------------------
CONFIG="$ROOT/.claude/harness.json"
if [ -f "$CONFIG" ]; then
  jq -e . "$CONFIG" >/dev/null 2>&1 || deny "judge gate: $CONFIG is not valid JSON."
else
  CONFIG=""
fi
cfg() { # $1 = jq path, $2 = default; scalars only
  local v=""
  [ -n "$CONFIG" ] && v=$(jq -r "$1 // empty" "$CONFIG" 2>/dev/null)
  printf '%s' "${v:-$2}"
}
cfg_lines() { # $1 = jq path to an array; one element per line, nothing when absent
  [ -n "$CONFIG" ] && jq -r "($1 // [])[]" "$CONFIG" 2>/dev/null
}
cfg_has() { # $1 = jq path; true when the key is present in the config, whatever its value (an explicit [] or "" counts)
  [ -n "$CONFIG" ] && [ "$(jq -r "$1 != null" "$CONFIG" 2>/dev/null)" = true ]
}
# `timeout` is GNU coreutils; a stock macOS does not have it. Run without a limit when absent (exit 124 then
# never happens, so a hung step is only caught by the budget checks between steps, never cut short).
run_timed() { # $1 = seconds, $@ = command
  if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi
}

# Time budget. Claude Code cancels a hook that outlives the timeout in settings.json and then runs the tool
# anyway: a PreToolUse hook that times out fails open (docs/fail-open-on-timeout.md: the machine slept
# mid-judge, the hook was cancelled when the timer ran out, and the push went through ungated). The gate
# therefore keeps its own wall-clock deadline well inside that timeout and refuses the push when a step cannot
# finish in time, which is the direction a gate should fail in. Config `budget` (default 1200 s) must stay well
# under the hook timeout in settings.json (settings.example.json gives 7200 s); the test suite checks the ratio.
GATE_BUDGET_S=$(cfg '.budget' 1200)
remaining() { local r=$((GATE_START + GATE_BUDGET_S - $(date +%s))); [ "$r" -gt 0 ] && echo "$r" || echo 0; }
out_of_time() { # $1 = what ran out of time, as a clause
  deny "judge gate: $1, so the push is refused rather than let through: Claude Code cancels a hook that outlives its timeout and runs the tool anyway. If the machine slept during the gate, push again with it awake; otherwise find what is slow."
}

# Direct dependencies whose installed version (node_modules/.package-lock.json) differs
# from package-lock.json. Empty output means node_modules matches this branch's lockfile.
stale_node_modules() {
  [ -f package-lock.json ] || return 0
  [ -f node_modules/.package-lock.json ] || { echo "node_modules missing or not installed by npm"; return 0; }
  local q='.packages | to_entries[] | select(.key | test("^node_modules/(@[^/]+/)?[^/]+$")) | select(.value.optional != true) | "\(.key) \(.value.version)"'
  diff <(jq -r "$q" package-lock.json | sort) <(jq -r "$q" node_modules/.package-lock.json | sort) | grep -E '^[<>]' | sed 's/^</wanted:/;s/^>/installed:/' | head -8
}


BRANCH=$(git rev-parse --abbrev-ref HEAD)
# Branches that are never gated: config `protected_branches` (globs), default main, master, release/*.
PROTECTED=$(cfg_lines '.protected_branches')
[ -n "$PROTECTED" ] || PROTECTED=$'main\nmaster\nrelease/*'
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  case "$BRANCH" in $pat) echo '{}'; exit 0;; esac
done <<< "$PROTECTED"

# Repo type decides where the locked checks live and which suite runs. Config `kind` overrides
# the detection; config `test_paths` overrides the pathspecs.
KIND=$(cfg '.kind' '')
if [ -z "$KIND" ]; then
  if [ -f pyproject.toml ] && [ -d tests ]; then KIND=python
  elif [ -f package.json ]; then KIND=web
  else KIND=other; fi
fi
case "$KIND" in python|web|other) ;; *) deny "judge gate: unknown kind '$KIND' in $CONFIG (python, web or other).";; esac
TEST_PATHSPEC=()
while IFS= read -r p; do [ -n "$p" ] && TEST_PATHSPEC+=("$p"); done <<< "$(cfg_lines '.test_paths')"
if [ ${#TEST_PATHSPEC[@]} -eq 0 ]; then
  if [ "$KIND" = web ]; then TEST_PATHSPEC=('*.test.ts' '*.test.tsx' '*.spec.ts' '*.spec.tsx' '__tests__/*')
  else TEST_PATHSPEC=(tests/); fi
fi

PACKET=".claude/judge/$BRANCH.md"
[ -f "$PACKET" ] || deny "judge gate: no packet at $PACKET. Write it per the /ticket skill step 7 (spec, CHECKS_SHA, HEAD, counts, Verify output), then push again."

CHECKS_SHA=$(grep -E -m1 '^CHECKS_SHA:' "$PACKET" | awk '{print $2}')
PKT_HEAD=$(grep -E -m1 '^HEAD:' "$PACKET" | awk '{print $2}')
HEAD_SHA=$(git rev-parse HEAD)
[ -n "$CHECKS_SHA" ] && git cat-file -e "$CHECKS_SHA^{commit}" 2>/dev/null || deny "judge gate: packet has no valid CHECKS_SHA line."
[ -n "$PKT_HEAD" ] && [ "$HEAD_SHA" = "$(git rev-parse "$PKT_HEAD" 2>/dev/null)" ] || deny "judge gate: packet HEAD ($PKT_HEAD) is not the current HEAD ($HEAD_SHA). Re-run verify and rewrite the packet for this commit."

# The checks commit is a fact git knows: the first commit after BASE that touches a test path. A packet that
# named a later commit (a Correct check, the build) would hide every test edit before it from the lock below.
# BASE comes from the packet; without a BASE line it is the merge-base with config `base_ref` (default origin/main).
BASE_REF=$(cfg '.base_ref' 'origin/main')
BASE=$(grep -E -m1 '^BASE:' "$PACKET" | awk '{print $2}')
if [ -n "$BASE" ]; then
  git cat-file -e "$BASE^{commit}" 2>/dev/null || deny "judge gate: packet BASE ($BASE) is not a commit. Write the $BASE_REF sha the branch started from."
else
  git rev-parse -q --verify "$BASE_REF^{commit}" >/dev/null 2>&1 || deny "judge gate: packet has no BASE line and $BASE_REF does not exist here, so the checks commit cannot be located. Add 'BASE: <the $BASE_REF sha the branch started from>' to the packet."
  BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null) || deny "judge gate: packet has no BASE line and HEAD shares no history with $BASE_REF. Add 'BASE: <the $BASE_REF sha the branch started from>' to the packet."
fi
FIRST=$(git rev-list --reverse "$BASE..HEAD" -- "${TEST_PATHSPEC[@]}" | head -1)
[ -n "$FIRST" ] || deny "judge gate: no commit after BASE ($(git rev-parse --short "$BASE")) touches a test path, so there is no checks commit to lock. Write and commit the checks first (/ticket step 4), then the packet."
if [ "$(git rev-parse "$CHECKS_SHA^{commit}")" != "$FIRST" ]; then
  deny "judge gate: packet CHECKS_SHA ($(git rev-parse --short "$CHECKS_SHA")) is not the first commit after BASE that touches a test path; that is $(git rev-parse --short "$FIRST") '$(git log -1 --format=%s "$FIRST")'. The packet must name the first test-touching commit after BASE; a Correct check commit is never the CHECKS_SHA."
fi

# Deploy surface: a change that only works when the worker, the API and the migration roll in an order. The rule
# exists because of one promotion: a PR moved work onto a background task, its scope reviewer noted the deploy
# order, nobody acted on the note, the API was rolled before the worker and the old worker dropped the task. The
# order now lives in the packet as a DEPLOY_AND_PROMOTION line the scope reviewer writes (/ticket step 6); a
# surface change without it never reaches the judge, and the judge gets the file list so it can hold the line
# against the diff (prompt step 7). Config `deploy.paths` replaces the pathspecs and `deploy.patterns` the regex
# that marks a task or scheduled job (`git diff -G`, test paths excluded); `[]` and "" switch each half off.
DEPLOY_PATHSPEC=()
if cfg_has '.deploy.paths'; then
  while IFS= read -r p; do [ -n "$p" ] && DEPLOY_PATHSPEC+=("$p"); done <<< "$(cfg_lines '.deploy.paths')"
else
  DEPLOY_PATHSPEC=('.github/workflows/' 'Dockerfile*' '*/Dockerfile*' 'docker/' 'alembic/' 'migrations/' 'Makefile')
fi
if cfg_has '.deploy.patterns'; then DEPLOY_TASK_RE=$(cfg '.deploy.patterns' ''); else DEPLOY_TASK_RE='@(celery_app|app)\.task|@shared_task|beat_schedule|add_periodic_task'; fi
NOT_TESTS=(); for p in "${TEST_PATHSPEC[@]}"; do NOT_TESTS+=(":!$p"); done
DEPLOY_SURFACE=""
[ ${#DEPLOY_PATHSPEC[@]} -eq 0 ] || DEPLOY_SURFACE=$(git diff --name-only "$BASE" HEAD -- "${DEPLOY_PATHSPEC[@]}" 2>/dev/null)
[ -z "$DEPLOY_TASK_RE" ] || DEPLOY_SURFACE=$(printf '%s\n%s\n' "$DEPLOY_SURFACE" "$(git diff --name-only -G "$DEPLOY_TASK_RE" "$BASE" HEAD -- . "${NOT_TESTS[@]}" 2>/dev/null)")
DEPLOY_SURFACE=$(printf '%s\n' "$DEPLOY_SURFACE" | grep -v '^$' | sort -u)
DEPLOY_LINE=$(grep -E -m1 '^DEPLOY_AND_PROMOTION:' "$PACKET" | sed -E 's/^DEPLOY_AND_PROMOTION:[[:space:]]*//')
DEPLOY_WORDS=$(printf '%s' "$DEPLOY_LINE" | wc -w | tr -d ' ')
if [ -n "$DEPLOY_SURFACE" ] && [ "$DEPLOY_WORDS" -lt 10 ]; then
  deny "judge gate: the diff $(git rev-parse --short "$BASE")..$(git rev-parse --short HEAD) touches a deployable surface (a background task or scheduled job, a workflow, a Dockerfile, a migration, the Makefile) but the packet has no DEPLOY_AND_PROMOTION: line with at least ten words after the label (found $DEPLOY_WORDS). The scope reviewer writes it in /ticket step 6: what is deployed, in what order, on which release branch, and what breaks if the order is wrong; or 'none, no deploy-order dependency' with the reason. Touched:"$'\n'"$DEPLOY_SURFACE"
fi
DEPLOY_SURFACE_TEXT=${DEPLOY_SURFACE:-none}

# Mechanical lock: tests/ untouched since the checks commit, except "Correct check" commits.
DIRTY=$(git status --porcelain -- "${TEST_PATHSPEC[@]}" | head -5)
[ -z "$DIRTY" ] || deny "judge gate: uncommitted changes to test files (checks are locked after $CHECKS_SHA):"$'\n'"$DIRTY"
BAD=$(git log --format='%h %s' "$CHECKS_SHA..HEAD" -- "${TEST_PATHSPEC[@]}" | grep -v -E ' [A-Za-z0-9-]+: Correct check ' || true)
[ -z "$BAD" ] || deny "judge gate: test files changed after the checks commit $CHECKS_SHA in commits that are not 'Correct check' commits:"$'\n'"$BAD"
# A "Correct check" commit may only touch test files the checks commit itself created or changed.
CHECK_FILES=$(git show --name-only --format= "$CHECKS_SHA" -- "${TEST_PATHSPEC[@]}")
OUTSIDE=""
for c in $(git rev-list "$CHECKS_SHA..HEAD" -- "${TEST_PATHSPEC[@]}"); do
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$CHECK_FILES" | grep -qxF "$f" || OUTSIDE="$OUTSIDE"$'\n'"$(git log -1 --format=%h "$c") $f"
  done <<< "$(git show --name-only --format= "$c" -- "${TEST_PATHSPEC[@]}")"
done
[ -z "$OUTSIDE" ] || deny "judge gate: a 'Correct check' commit touches test files that are not this ticket's checks (not in $CHECKS_SHA). Unrelated test fixes go on their own branch from the base branch as their own PR, or are rebased to sit before the checks commit (then regenerate the packet):$OUTSIDE"

# Mechanical suite run (deterministic; the judge is not asked about tests). Any red test refuses the push:
# there is no accepted-failures list. A test that is already red on the base branch gets its own PR first.
SUITE=""
if [ "$KIND" != other ]; then
  SUITE_TIMEOUT=$(cfg '.suite.timeout' 300)
  # Config `suite.env_file` is loaded line by line (KEY=value lines only); `suite.env` values are
  # defaults, applied only to variables that are still unset.
  ENV_FILE=$(cfg '.suite.env_file' '.env.test')
  [ -f "$ENV_FILE" ] && while IFS= read -r line; do case "$line" in ''|\#*) continue;; [A-Za-z_]*=*) export "$line";; esac; done < "$ENV_FILE"
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    k=${kv%%=*}; v=${kv#*=}
    printf '%s' "$k" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || continue
    eval "[ -n \"\${$k+set}\" ] || export $k=\"\$v\""
  done <<< "$(cfg_lines '(.suite.env // {}) | to_entries | map("\(.key)=\(.value)")')"
  # Each step gets the smaller of its own timeout and what is left of the budget; exit 124 is the timeout firing.
  if [ "$KIND" = python ]; then
    SUITE_CMD=$(cfg '.suite.command' 'poetry run pytest tests/unit -q --continue-on-collection-errors -p no:cacheprovider')
    R=$(remaining); [ "$R" -gt 0 ] || out_of_time "the gate's $GATE_BUDGET_S s budget was spent before the unit suite started"
    T=$(( SUITE_TIMEOUT < R ? SUITE_TIMEOUT : R ))
    RAW=$(run_timed "$T" bash -c "$SUITE_CMD" 2>&1); SUITE_RC=$?
    [ "$SUITE_RC" -eq 124 ] && out_of_time "the unit suite did not finish within $T s"
    SUITE=$(printf '%s\n' "$RAW" | tail -1)
    # Red lines are the summary's "FAILED <id>" / "ERROR <path>" lines whose id starts under a test path,
    # so a test that prints the word FAILED cannot invent an id.
    RED_DIRS=$(printf '%s\n' "${TEST_PATHSPEC[@]}" | sed -E 's#/+$##; s/[.]/\\./g' | paste -sd'|' -)
    RED=$(printf '%s\n' "$RAW" | grep -E "^(FAILED|ERROR) ($RED_DIRS)(/|::| |$)" || true)
  else
    STALE=$(stale_node_modules 2>/dev/null || true)
    [ -z "$STALE" ] || deny "judge gate: node_modules does not match package-lock.json, so tsc and vitest results would be meaningless. Run 'npm ci' on this lockfile, then push again. Differences:"$'\n'"$STALE"
    TYPECHECK_CMD=$(cfg '.suite.typecheck_command' 'npx tsc --noEmit')
    SUITE_CMD=$(cfg '.suite.command' 'npx vitest run')
    R=$(remaining); [ "$R" -gt 0 ] || out_of_time "the gate's $GATE_BUDGET_S s budget was spent before the type check started"
    T=$(( SUITE_TIMEOUT < R ? SUITE_TIMEOUT : R ))
    TSC_RAW=$(run_timed "$T" bash -c "$TYPECHECK_CMD" 2>&1); TSC_RC=$?
    [ "$TSC_RC" -eq 124 ] && out_of_time "the type check did not finish within $T s"
    TSC=$(printf '%s\n' "$TSC_RAW" | grep -E 'error TS' || true)
    R=$(remaining); [ "$R" -gt 0 ] || out_of_time "the gate's $GATE_BUDGET_S s budget was spent before the test suite started"
    T=$(( SUITE_TIMEOUT < R ? SUITE_TIMEOUT : R ))
    RAW=$(run_timed "$T" bash -c "$SUITE_CMD" 2>&1); SUITE_RC=$?
    [ "$SUITE_RC" -eq 124 ] && out_of_time "the test suite did not finish within $T s"
    SUITE="tsc errors: $(printf '%s' "$TSC" | grep -c . ); vitest: $(printf '%s\n' "$RAW" | grep -E '^ +Tests ' | sed 's/^ *//')"
    RED=$(printf '%s\n%s\n' "$(printf '%s\n' "$RAW" | grep -E '^ FAIL ' | sed 's/^ *//')" "$TSC" | grep -v '^$' || true)
  fi
  # One id per red line: pytest "FAILED <nodeid> - <message>" / "ERROR <path> - <message>";
  # vitest " FAIL  <file> > <name>" with the prefix removed; a tsc "error TS" line as printed.
  if [ -n "$RED" ]; then
    if [ "$KIND" = python ]; then
      IDS=$(printf '%s\n' "$RED" | sed -E 's/^(FAILED|ERROR)[[:space:]]+//; s/[[:space:]]+-[[:space:]].*$//; s/[[:space:]]+$//')
    else
      IDS=$(printf '%s\n' "$RED" | sed -E 's/^FAIL[[:space:]]+//; s/[[:space:]]+$//')
    fi
    deny "judge gate: the suite is not green (suite: $SUITE). There is no accepted-failures list: every red test below is this branch's to fix; one that is already red on the base branch gets its own PR from the base branch first, then rebase:"$'\n'"$IDS"
  fi
  # A suite that never ran (the runner missing, a broken environment, nothing collected) prints no red lines
  # at all, so the exit status is what proves it ran green. A timeout (124) was handled above.
  if [ "$KIND" = python ]; then
    [ "$SUITE_RC" -eq 0 ] || deny "judge gate: the unit suite did not run to a green finish (pytest exit $SUITE_RC), so there is no evidence it is green. Last lines:"$'\n'"$(printf '%s\n' "$RAW" | tail -5)"
  else
    [ "$TSC_RC" -eq 0 ] && [ "$SUITE_RC" -eq 0 ] || deny "judge gate: the checks did not run to a green finish (tsc exit $TSC_RC, vitest exit $SUITE_RC), so there is no evidence they are green. Last lines:"$'\n'"$(printf '%s\n%s\n' "$TSC_RAW" "$RAW" | tail -8)"
  fi
fi

DIFF_STAT=$(git diff --stat "$CHECKS_SHA" HEAD | tail -30)
if [ "$KIND" = web ]; then DIFF_EXCLUDE="':!*.test.ts' ':!*.test.tsx' ':!*.spec.ts' ':!*.spec.tsx'"; else DIFF_EXCLUDE="':!tests'"; fi
PROMPT=$(cat <<PEOF
You are the judge for branch $BRANCH, about to be pushed. You decide whether it is done. You never edit files. Be strict; a builder is most likely to have fooled itself on vacuous checks and unwired code.

Read, in this order:
1. CLAUDE.md (Conventions and How to work).
2. The judge packet at $PACKET: the five-line spec (Goal, Acceptance, Out of scope, Verify, Files), the DEPLOY_AND_PROMOTION line, the Verify command and its output, and the round count. Trust the packet for the spec text only.
3. The checks: run \`git show $CHECKS_SHA --stat\` and read every test file it adds or changes. Each test must assert the behaviour in the Acceptance line. A test that would pass without the feature (asserts on a mock it set itself, asserts only that something exists or returns anything, never calls the code under test) is vacuous: FAIL, naming the test.
4. The code: run \`git diff $CHECKS_SHA HEAD -- . $DIFF_EXCLUDE\` and read it. Every change must serve the Goal line. Anything the Out of scope line excludes is a FAIL.
5. Wiring: for each new function, method or class in that diff, find a caller in the diff or in existing code with Grep. New code with no caller is a FAIL unless the spec says it is for a later ticket.
6. Verify evidence: the packet must show the Verify command and output demonstrating the Acceptance line. Missing or unconvincing output is a FAIL.
7. Deploy and promotion: the DEPLOY_AND_PROMOTION line of the packet must match the diff. If the diff adds or changes a background task or scheduled job, a workflow, a Dockerfile or a migration, the line must state the order in which the services (worker, API, migration) are rolled and on which release branch, and what breaks if the order is wrong; a line that says none while the diff touches one of those is a FAIL; a scope-reviewer note about deploy order (in the packet or the PR body) that the line does not carry is a FAIL. Files on the deploy surface in $BASE..HEAD, found mechanically (none means the diff touches no such path and adds no task or scheduled job): $DEPLOY_SURFACE_TEXT

The test-file lock (nothing in the test paths changed after the checks commit except Correct-check commits limited to the test files of this ticket) and the unit suite (every test green) were both checked mechanically before you were called (suite summary: $SUITE). Do not re-judge either; do not fail step 1 on the lock, and do not explain away any number. More generally: never rationalise a discrepancy. If the evidence for a step is missing or you could not check it, that step is a FAIL, not a PASS with a caveat.

Diff stat since the checks commit:
$DIFF_STAT

Answer with a short report: one line per step 1 to 7, PASS or FAIL with file:line or test name for every FAIL, so the builder can act without guessing. The final line must be exactly VERDICT: PASS or VERDICT: FAIL.
PEOF
)

JUDGE_MODEL=$(cfg '.judge.model' 'claude-fable-5-1')
JUDGE_TIMEOUT=$(cfg '.judge.timeout' 840)
# The judge may read, grep and run read-only git; config `judge.extra_allowed_tools` adds to that
# (default: the suite runners), so it can re-run a test it doubts. It can never write or change history.
ALLOWED="Read,Grep,Glob,Bash(git diff *),Bash(git show *),Bash(git log *),Bash(git grep *)"
EXTRA=$(cfg_lines '.judge.extra_allowed_tools' | paste -sd, -)
[ -n "$EXTRA" ] || [ -n "$(cfg '.judge.extra_allowed_tools' '')" ] || EXTRA="Bash(poetry run pytest *),Bash(npx vitest run *),Bash(npx tsc *)"
[ -z "$EXTRA" ] || ALLOWED="$ALLOWED,$EXTRA"
# The judge is not started with less than a minute of budget left; it never gets more than what remains.
R=$(remaining); [ "$R" -ge 60 ] || out_of_time "only $R s of the gate's $GATE_BUDGET_S s budget were left when the judge was due to start"
T=$(( JUDGE_TIMEOUT < R ? JUDGE_TIMEOUT : R ))
# The two variables mark a nested Claude Code session; the judge must start as a plain CLI run.
OUT=$( (unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; run_timed "$T" claude -p "$PROMPT" --model "$JUDGE_MODEL" --output-format json \
  --allowedTools "$ALLOWED" \
  --disallowedTools "Edit,Write,NotebookEdit,Bash(git push *),Bash(git commit *),Bash(git add *),Bash(git checkout *),Bash(git reset *),Bash(git rebase *),Bash(git merge *),Bash(rm *)") 2>&1); JUDGE_RC=$?
[ "$JUDGE_RC" -eq 124 ] && out_of_time "the judge did not finish within $T s"
[ "$(remaining)" -gt 0 ] || out_of_time "the gate ran past its $GATE_BUDGET_S s budget while the judge ran"
printf '%s' "$OUT" | grep -q 'Not logged in' && deny "judge gate: the claude CLI used for the headless judge is not logged in. Run 'claude login' once in a terminal (same account as the app), then push again."
REPORT=$(printf '%s' "$OUT" | jq -r '.result // empty' 2>/dev/null)
[ -n "$REPORT" ] || deny "judge gate: the judge did not return a report. Raw output (first lines):"$'\n'"$(printf '%s' "$OUT" | head -c 1500)"

# Usage and cost come back in the same JSON; keep them for the metrics file (.claude/metrics.csv: judge_tokens).
USAGE=$(printf '%s' "$OUT" | jq -r '"input=\(.usage.input_tokens // 0) cache_create=\(.usage.cache_creation_input_tokens // 0) cache_read=\(.usage.cache_read_input_tokens // 0) output=\(.usage.output_tokens // 0) cost_usd=\(.total_cost_usd // 0) duration_s=\(((.duration_ms // 0) / 1000) | floor)"' 2>/dev/null)
[ -n "$USAGE" ] || USAGE="unavailable"

# One dated section per run, appended: a FAIL followed by a PASS leaves both (judge_fails in the metrics file).
mkdir -p .claude/judge
VERDICT_FILE=".claude/judge/$BRANCH.verdict.md"
[ -s "$VERDICT_FILE" ] && printf '\n' >> "$VERDICT_FILE"
printf '%s\n%s\n\n%s\n' "# Judge verdict for $BRANCH at $HEAD_SHA ($(date -u +%Y-%m-%dT%H:%M:%SZ))" "Usage: $USAGE" "$REPORT" >> "$VERDICT_FILE"

if printf '%s' "$REPORT" | grep -Eq '^VERDICT: PASS[[:space:]]*$'; then
  jq -cn --arg m "Judge PASS for $BRANCH (report in .claude/judge/$BRANCH.verdict.md)." '{systemMessage:$m}'
else
  deny "judge gate: VERDICT FAIL for $BRANCH. Fix what is named, re-run verify, rewrite the packet, push again."$'\n\n'"$REPORT"
fi
