#!/usr/bin/env bash
# PreToolUse(Bash) hook: gate `git push` behind (1) a mechanical lock check and
# (2) a headless Claude judge. Allows everything that is not a real git push.
# Output: {} to allow, or hookSpecificOutput.permissionDecision=deny with reasons.
#
# Site-specific values (suite command, protected branches, judge model, ...) come from
# .claude/harness.json in the repo the push targets; every key is optional and the defaults
# below apply when the file or the key is absent. See docs/how-it-works.md, "Configuration".
set -u
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
# Exact match on an actual push command, not the best-effort "if" filter.
# Command position only: line start, after ; & | && ||, or inside $( ... ). A bare "(" is
# deliberately not accepted, so the hook matcher string quoted inside a heredoc does not count.
printf '%s' "$CMD" | grep -Eq '(^|[;&|]|&&|\|\||\$\()[[:space:]]*(env[[:space:]]+[^;&|]*[[:space:]])?git[[:space:]]+(-C[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:]]+)[[:space:]]+)?push([[:space:]]|$)' || { echo '{}'; exit 0; }

deny() { jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty'); [ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$CWD" 2>/dev/null || { echo '{}'; exit 0; }
# The push may target another repo than the session's folder: honour `git -C <path> push`
# and the last `cd <path>` that precedes the push in the command text.
TARGET=$(printf '%s' "$CMD" | grep -Eo 'git[[:space:]]+-C[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:]]+)[[:space:]]+push' | tail -1 | sed -E 's/^git[[:space:]]+-C[[:space:]]+//; s/[[:space:]]+push$//; s/^["'"'"']//; s/["'"'"']$//')
if [ -z "$TARGET" ]; then
  PRE=$(printf '%s' "$CMD" | sed -E 's/(^|[;&|]|&&|\|\|)[[:space:]]*git[[:space:]]+push.*$//')
  TARGET=$(printf '%s' "$PRE" | grep -Eo '(^|[;&|]|&&|\|\|)[[:space:]]*cd[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:];&|]+)' | tail -1 | sed -E 's/^.*cd[[:space:]]+//; s/^["'"'"']//; s/["'"'"']$//')
fi
if [ -n "$TARGET" ]; then
  TARGET="${TARGET/#\~/$HOME}"
  cd "$TARGET" 2>/dev/null || deny "judge gate: the push targets '$TARGET' but that directory cannot be entered from $CWD."
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
# `timeout` is GNU coreutils; a stock macOS does not have it. Run without a limit when absent.
run_timed() { # $1 = seconds, $@ = command
  if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi
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

# Mechanical suite run and known-failures comparison (deterministic; the judge is not asked about tests).
SUITE=""
if [ "$KIND" != other ]; then
  KNOWN=".claude/known-failures.txt"
  [ -f "$KNOWN" ] || deny "judge gate: $KNOWN is missing. It lists the accepted red items (see CLAUDE.md, Known failures)."
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
  if [ "$KIND" = python ]; then
    SUITE_CMD=$(cfg '.suite.command' 'poetry run pytest tests/unit -q --continue-on-collection-errors -p no:cacheprovider')
    RAW=$(run_timed "$SUITE_TIMEOUT" bash -c "$SUITE_CMD" 2>&1)
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
    TSC=$(run_timed "$SUITE_TIMEOUT" bash -c "$TYPECHECK_CMD" 2>&1 | grep -E 'error TS' || true)
    RAW=$(run_timed "$SUITE_TIMEOUT" bash -c "$SUITE_CMD" 2>&1)
    SUITE="tsc errors: $(printf '%s' "$TSC" | grep -c . ); vitest: $(printf '%s\n' "$RAW" | grep -E '^ +Tests ' | sed 's/^ *//')"
    RED=$(printf '%s\n%s\n' "$(printf '%s\n' "$RAW" | grep -E '^ FAIL ' | sed 's/^ *//')" "$TSC" | grep -v '^$' || true)
  fi
  # Known items match a whole id, never a substring (a file or class name alone would hide every new red
  # test inside it). One id per red line: pytest "FAILED <nodeid> - <message>" / "ERROR <path> - <message>";
  # vitest " FAIL  <file> > <name>" with the prefix removed; a tsc "error TS" line as printed.
  PATTERNS=$(grep -v -E '^[[:space:]]*(#|$)' "$KNOWN" | sed -E 's/[[:space:]]+$//' || true)
  if [ -n "$RED" ]; then
    if [ "$KIND" = python ]; then
      IDS=$(printf '%s\n' "$RED" | sed -E 's/^(FAILED|ERROR)[[:space:]]+//; s/[[:space:]]+-[[:space:]].*$//; s/[[:space:]]+$//')
    else
      IDS=$(printf '%s\n' "$RED" | sed -E 's/^FAIL[[:space:]]+//; s/[[:space:]]+$//')
    fi
    if [ -n "$PATTERNS" ]; then UNKNOWN=$(printf '%s\n' "$IDS" | grep -v -x -F -f <(printf '%s\n' "$PATTERNS") || true); else UNKNOWN="$IDS"; fi
    [ -z "$UNKNOWN" ] || deny "judge gate: red tests not listed in $KNOWN (suite: $SUITE). Each line of that file is one whole test id (the pytest node id, or the vitest FAIL line without its prefix); a file or class name alone matches nothing. Fix them or, if they are pre-existing on the base branch, add the ids with a dated comment:"$'\n'"$UNKNOWN"
  fi
fi

DIFF_STAT=$(git diff --stat "$CHECKS_SHA" HEAD | tail -30)
if [ "$KIND" = web ]; then DIFF_EXCLUDE="':!*.test.ts' ':!*.test.tsx' ':!*.spec.ts' ':!*.spec.tsx'"; else DIFF_EXCLUDE="':!tests'"; fi
PROMPT=$(cat <<PEOF
You are the judge for branch $BRANCH, about to be pushed. You decide whether it is done. You never edit files. Be strict; a builder is most likely to have fooled itself on vacuous checks and unwired code.

Read, in this order:
1. CLAUDE.md (the Known failures section and Conventions).
2. The judge packet at $PACKET: the five-line spec (Goal, Acceptance, Out of scope, Verify, Files), the Verify command and its output, and the round count. Trust the packet for the spec text only.
3. The checks: run \`git show $CHECKS_SHA --stat\` and read every test file it adds or changes. Each test must assert the behaviour in the Acceptance line. A test that would pass without the feature (asserts on a mock it set itself, asserts only that something exists or returns anything, never calls the code under test) is vacuous: FAIL, naming the test.
4. The code: run \`git diff $CHECKS_SHA HEAD -- . $DIFF_EXCLUDE\` and read it. Every change must serve the Goal line. Anything the Out of scope line excludes is a FAIL.
5. Wiring: for each new function, method or class in that diff, find a caller in the diff or in existing code with Grep. New code with no caller is a FAIL unless the spec says it is for a later ticket.
6. Verify evidence: the packet must show the Verify command and output demonstrating the Acceptance line. Missing or unconvincing output is a FAIL.

The test-file lock (nothing in the test paths changed after the checks commit except Correct-check commits limited to the test files of this ticket) and the unit suite (compared against the known-failures list) were both checked mechanically before you were called (suite summary: $SUITE). Do not re-judge either; do not fail step 1 on the lock, and do not explain away any number. More generally: never rationalise a discrepancy. If the evidence for a step is missing or you could not check it, that step is a FAIL, not a PASS with a caveat.

Diff stat since the checks commit:
$DIFF_STAT

Answer with a short report: one line per step 1 to 6, PASS or FAIL with file:line or test name for every FAIL, so the builder can act without guessing. The final line must be exactly VERDICT: PASS or VERDICT: FAIL.
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
# The two variables mark a nested Claude Code session; the judge must start as a plain CLI run.
OUT=$( (unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; run_timed "$JUDGE_TIMEOUT" claude -p "$PROMPT" --model "$JUDGE_MODEL" --output-format json \
  --allowedTools "$ALLOWED" \
  --disallowedTools "Edit,Write,NotebookEdit,Bash(git push *),Bash(git commit *),Bash(git add *),Bash(git checkout *),Bash(git reset *),Bash(git rebase *),Bash(git merge *),Bash(rm *)") 2>&1)
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
