#!/usr/bin/env bash
# PostToolUse(Bash) hook: after a `git push` of a feature branch has succeeded, publish the judge's verdict for
# the pushed head as a GitHub commit status on that sha (context judge-gate/verdict), so a CI job can require it
# (ci/require-judge-verdict.yaml is one such job).
#   success  "VERDICT: PASS <utc>"           a `# Judge verdict for <branch> at <sha> (<utc>)` section ending in
#                                            VERDICT: PASS exists in .claude/judge/<branch>.verdict.md
#   failure  "no judge verdict for this sha" no such section: the push was not gated (hook timed out across a
#                                            sleep, hook skipped, pushed from a plain shell)
# Never blocks: always prints {} and exits 0. What it did or skipped goes to ~/.claude/hooks/logs/judge-status.log.
#
# Config, from .claude/harness.json in the repo the push targets (every key optional):
#   protected_branches   branches that are never gated, so never statused (default main, master, release/*)
#   status.context       the status context (default judge-gate/verdict; a CI job that requires it must agree)
#   status.gh_user       a gh account to pin the call to (`gh auth token --user`), for a machine with several
#                        accounts signed in; default none, so gh's active account posts. JUDGE_STATUS_GH_USER
#                        in the environment wins over the config.
#
# The push recognition below (the regex block, `git -C <path>` and the last `cd <path>` before the push) is a
# copy of judge-gate.sh's, not a `source`: the gate runs the suite and the judge at top level, so sourcing it
# would run them. tests/test-push-regex-sync.sh fails when the two regex blocks differ.
set -u
LOG="${JUDGE_STATUS_LOG:-$HOME/.claude/hooks/logs/judge-status.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null; }
finish() { echo '{}'; exit 0; }

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$CMD" ] || finish
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
printf '%s' "$CMD" | grep -Eq "$PUSH_RE" || finish
# A dry run prints the same "-> branch" line as a real push but moves nothing.
printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push[^;&|]*[[:space:]](--dry-run|-n)([[:space:]]|$)' && { log "skip: dry run: $CMD"; finish; }

# The push must have completed. Bash's tool_response carries stdout/stderr/interrupted, not an exit status, and
# the push is usually piped through tail, so read git's own report: a ref update line or "Everything up-to-date",
# and no rejection.
INTERRUPTED=$(printf '%s' "$INPUT" | jq -r '.tool_response.interrupted // false' 2>/dev/null)
[ "$INTERRUPTED" = "true" ] && { log "skip: interrupted: $CMD"; finish; }
OUTPUT=$(printf '%s' "$INPUT" | jq -r 'if (.tool_response|type) == "object" then ((.tool_response.stdout // "") + "\n" + (.tool_response.stderr // "")) else ((.tool_response // "") | tostring) end' 2>/dev/null)
if printf '%s' "$OUTPUT" | grep -Eq '\[(rejected|remote rejected|remote failure)\]|failed to push|^fatal:|^error:'; then
  log "skip: push failed: $CMD"; finish
fi
if ! printf '%s' "$OUTPUT" | grep -Eq '(\[new branch\]|\[new tag\]|[0-9a-f]+\.\.\.?[0-9a-f]+)[[:space:]]+[^[:space:]]+[[:space:]]->[[:space:]][^[:space:]]+|Everything up-to-date'; then
  log "skip: output shows no completed push: $CMD"; finish
fi

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null); [ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$CWD" 2>/dev/null || { log "skip: cannot enter cwd $CWD"; finish; }
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
      *'$'*) log "skip: push targets '$TARGET' but it cannot be entered from $CWD: the hook reads the command text literally and does not expand shell variables, so spell the path out (git -C /full/path push)" ;;
      *) log "skip: push targets '$TARGET' but it cannot be entered from $CWD" ;;
    esac
    finish
  fi
fi
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { log "skip: not a git repo: $PWD"; finish; }
cd "$ROOT" || finish

# --- configuration (the same file and defaults as judge-gate.sh) -----------------------------
CONFIG="$ROOT/.claude/harness.json"
{ [ -f "$CONFIG" ] && jq -e . "$CONFIG" >/dev/null 2>&1; } || CONFIG=""
cfg() { # $1 = jq path, $2 = default; scalars only
  local v=""
  [ -n "$CONFIG" ] && v=$(jq -r "$1 // empty" "$CONFIG" 2>/dev/null)
  printf '%s' "${v:-$2}"
}
cfg_lines() { # $1 = jq path to an array; one element per line, nothing when absent
  [ -n "$CONFIG" ] && jq -r "($1 // [])[]" "$CONFIG" 2>/dev/null
}
CONTEXT=$(cfg '.status.context' 'judge-gate/verdict')
GH_USER="${JUDGE_STATUS_GH_USER:-$(cfg '.status.gh_user' '')}"

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || finish
[ "$BRANCH" = HEAD ] && { log "skip: detached HEAD is not gated"; finish; }
PROTECTED=$(cfg_lines '.protected_branches')
[ -n "$PROTECTED" ] || PROTECTED=$'main\nmaster\nrelease/*'
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  case "$BRANCH" in $pat) log "skip: branch $BRANCH is not gated"; finish;; esac
done <<< "$PROTECTED"
SHA=$(git rev-parse HEAD 2>/dev/null) || finish

# The latest section for this exact sha that ends in VERDICT: PASS; its timestamp becomes the description.
VERDICT_FILE=".claude/judge/$BRANCH.verdict.md"
TS=""
if [ -f "$VERDICT_FILE" ]; then
  TS=$(awk -v sha="$SHA" '
    /^# Judge verdict for / {
      cur = ""; ts = ""
      if (index($0, " at " sha " (")) { cur = sha; s = $0; sub(/^.* at [0-9a-f]+ \(/, "", s); sub(/\).*$/, "", s); ts = s }
      next
    }
    cur == sha && /^VERDICT: PASS[[:space:]]*$/ { found = ts }
    END { print found }' "$VERDICT_FILE")
fi
if [ -n "$TS" ]; then STATE=success; DESC="VERDICT: PASS $TS"; else STATE=failure; DESC="no judge verdict for this sha"; fi

URL=$(git remote get-url origin 2>/dev/null) || { log "skip: no origin remote in $ROOT"; finish; }
printf '%s' "$URL" | grep -Eq '(^|[@/.])github\.com[:/]' || { log "skip: origin is not a GitHub remote: $URL"; finish; }
SLUG=$(printf '%s' "$URL" | sed -E 's#^.*github\.com[:/]##; s#\.git$##; s#/+$##')
case "$SLUG" in */*) ;; *) log "skip: cannot read owner/repo from origin: $URL"; finish;; esac

# With several gh accounts signed in the active one is machine-wide, so a configured account is pinned by token.
if [ -n "$GH_USER" ]; then
  TOKEN=$(gh auth token --user "$GH_USER" 2>/dev/null) || TOKEN=""
  [ -n "$TOKEN" ] && export GH_TOKEN="$TOKEN"
fi
if RESP=$(gh api -X POST "repos/$SLUG/statuses/$SHA" -f state="$STATE" -f context="$CONTEXT" -f description="$DESC" 2>&1); then
  log "posted $STATE repos/$SLUG/statuses/$SHA branch=$BRANCH description=\"$DESC\""
else
  log "gh api failed for repos/$SLUG/statuses/$SHA ($STATE, branch=$BRANCH): $(printf '%s' "$RESP" | head -c 300)"
fi
finish
