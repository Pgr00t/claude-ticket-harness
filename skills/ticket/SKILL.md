---
name: ticket
description: Take one ticket from key to merged PR in a single session. Usage /ticket KEY-123
disable-model-invocation: true
---

# Ticket

One ticket, one session, one PR. The session starts with a five-line spec and a plan the user approves, then runs without interruption until the PR is open. The session is over when the PR is merged.

The loop inside the session is: write the checks, lock them, build until the checks are green, verify against the running thing, log the round. The checks are the contract; the builder may not touch them once they are committed.

The argument is a ticket key (`KEY-123`) or a ticket URL. Repo facts live in `CLAUDE.md` (layout, commands, deploy paths, conventions, Known failures, How to work) and in `docs/agents/`. Read `CLAUDE.md` before step 1 and treat it as the source of truth over anything written here. Its Layout line names the source tree and the test paths; below, `<src>` and `<tests>` mean those.

## 1. Read the ticket

Fetch the ticket the way `docs/agents/issue-tracker.md` says, including every comment and any linked design or wiki page. Then read the domain docs the way `docs/agents/domain.md` says, if the repo has them.

A ticket that spans two repos (an API and a web app, say) can run in one session: add the second repo to the session (the app's add-directory action, or ask the user to) and do the halves in order, the producer of the contract first. Each half is a full pass through steps 2 to 7 with its own spec, checks commit, packet and PR, in its own repo; the round log row goes in that repo's `.claude/loop-results.md`. Always address the other repo explicitly: `git -C <repo root> ...` for git, and run tests and formatters from that repo's root. The push gate judges the repo a push targets, so `git -C <root> push` is the form to use. If the user prefers one session per repo, name the other half in the spec's "Out of scope" line instead.

Done when: you can state the user-visible behaviour the ticket asks for in one sentence, and you know which comments change the original ask.

## 2. Write the five-line spec

Record the moment you start on it (`date -u +%Y-%m-%dT%H:%MZ`); that value is the packet's `SPEC_STARTED` line in step 7. Post the spec as the first thing the user sees, in exactly this shape:

```
Goal:         <one sentence, the behaviour the ticket asks for>
Acceptance:   <the observable result that proves it, one or two checks>
Out of scope: <what this PR leaves alone, including the other repo's half>
Verify:       <the command or QA step that demonstrates acceptance against the running app, not a unit-test line>
Files:        <the files you expect to change, from a first look at the code>
```

The Verify line must exercise the running thing: a curl against the dev server, a worker task run, or a browser step against the local app. The unit suite is step 6's job, not this line's. This is the only defence against code that passes every check and is never wired in.

Every open question goes under the spec in one batch, with the answer you will assume for each if the user says nothing. Ask once here; the rest of the session takes no questions.

Done when: each of the five lines is concrete enough that a reviewer could check the PR against it.

## 3. Plan and get approval

Enter plan mode. Explore the code the "Files" line names and whatever it pulls in. When the ticket touches more than one area (an endpoint plus a task plus a repository, say), spawn one Explore subagent per area in parallel and work from their conclusions rather than reading everything yourself. Write the plan as three lists, with the spec at the top:

1. **Checks**: the test functions you will write, one line each, named after the Acceptance line. Each line says what it asserts and why it must fail before the build.
2. **Edits**: the ordered changes under `<src>`.
3. **Verify**: the exact commands, starting with the spec's Verify line.

Exit plan mode and wait for approval. Approval of the plan is the user's approval for everything in steps 4 to 7. After approval the user walks away. From this point count interruptions: a user message that changes scope, approach or a check. The count is the packet's `INTERRUPTIONS` line; zero is a real value, so write 0 when there were none.

Done when: the plan is approved.

## Models, and who does what

The session runs on the strongest model available (Fable 5.1 at the time of writing; pick it in the model menu if a session shows something else). That model does steps 1 to 3 and 6 to 8: reading, spec, plan, verify, reviewers, packet, PR. Steps 4 and 5 are done by a **builder subagent on a cheaper model** (Opus 5.5 here): after the plan is approved, spawn one Agent with `model: "opus"`, `run_in_background: false`, and a brief that contains, verbatim: the five-line spec, the approved plan's three lists, the Layout line from `CLAUDE.md`, the branch name, and the full text of steps 4 and 5 below. Tell it to report back `CHECKS_SHA`, the final HEAD, the number of rounds, and the exact red-for-the-right-reason output from step 4. The parent does not edit code while the builder runs. If the builder reports `stuck`, relay its message to the user and stop. The judge at push time is a third process, on the model named by `judge.model` in `.claude/harness.json` (the strongest one by default), started by the gate script. A session cannot change its own model, so never try to switch mid-session; delegation is the mechanism.

## 4. Write and lock the checks

(Done by the builder subagent.) Start from the latest `main` on origin, not whatever the local `main` happens to be:

```bash
git fetch origin && git checkout -b <KEY>-<slug> origin/main
```

If the session is already on a branch for this ticket (a worktree the app created), rebase it onto `origin/main` before writing anything. Record the `origin/main` commit you started from; it goes in the PR body.

Write the tests from the plan's Checks list in `<tests>` (CLAUDE.md says where unit and integration tests live and how test files are named). Do not touch `<src>` yet.

Run the new tests. Every one must be red, and red for the reason the plan gives (an assertion on the missing behaviour, not an import error or a typo). A check that passes before the feature exists is not a check: fix the check. Run the full unit suite too; nothing outside Known failures may have changed.

Commit the tests alone, title `<KEY>: Add checks for <behaviour>`. Record the commit hash as `CHECKS_SHA`; it goes in the PR body and in the round log.

From this commit on, `<tests>` is locked for the session. If a check turns out to be wrong during the build, stop, write down why in the round log, and fix it in a separate commit titled `<KEY>: Correct check <name>` with the reason in the body. That commit replaces `CHECKS_SHA`. A silent edit to a test is a failed round. A Correct check commit may touch only test files the checks commit itself created or changed. A fix to any other test, a stale fixture in an unrelated file for example, is out of scope for this branch: put it on its own branch from `origin/main` as its own small PR, or rebase it to sit before the checks commit and regenerate the packet. The push gate enforces this mechanically.

Optional belt and braces when the user is still present: if a write-freeze skill is installed, point it at `<src>` so Edit and Write outside it are refused for the rest of the session. The mechanical gate in step 6 and the push gate in step 7 hold either way.

Done when: the checks commit exists, every new test is red for its stated reason, and the suite otherwise matches Known failures.

## 5. Build

(Done by the builder subagent.) Follow the plan's Edits list. Each round is: edit `<src>`, run the new tests, read the failures, repeat. Keep a change only when it turns a red check green without turning another one red.

Keep "Out of scope" out: a problem found on the way that the spec excludes becomes a note in the PR body (or a `TODOS.md` entry), not a change.

Cap: ten rounds. At the cap, stop, log the round as `stuck`, and leave the user a message naming the check that will not go green and what you tried. Do not loosen the check to get past it.

When every check is green, make one refactor pass over the code you added: names, duplication, dead branches. Run the checks again after it. Green, refactor, green is the TDD cycle; the refactor is skipped only when there is nothing to tidy.

Done when: every check from step 4 is green and the refactor pass has run.

## 6. Verify

(Back in the parent session, with the builder's report in hand.) Run, in this order:

1. The gate: `git diff --quiet $CHECKS_SHA HEAD -- <tests>`. It must print nothing. If it does not, the builder edited the checks; revert `<tests>` to `CHECKS_SHA` and go back to step 5. A corrected check per step 4 is the only exception, and it must have its own commit.
2. The "Verify" line from the spec, against the running app.
3. The tests for the touched area, then the full unit suite.
4. The format and lint checks CI runs (`CLAUDE.md` names the commands).
5. Review fan-out. Spawn three review subagents in parallel on `git diff $CHECKS_SHA HEAD`, each given the spec and one question only: does the code do what the Goal line says and nothing else; do the checks actually test the Acceptance line or could they pass vacuously; is every new function reachable from an endpoint, task or existing caller. The checks reviewer should mutate the build (flip a comparison, ignore an argument, drop a branch) and name every mutant the checks let live. Each returns findings with file and line. Fix the real ones, note the rest in the PR body under Out of scope, and run steps 1 to 4 again if anything changed.

Compare failures against Known failures in `CLAUDE.md`. A failure not on that line is yours: fix it before moving on. Record the counts you saw; they go in the PR body.

Append one line to `.claude/loop-results.md` for the ticket: date, key, number of checks, rounds taken, `green` or `stuck`, what failed along the way and why, and one note for How to work if a habit showed up (a check that was vacuous, a wiring gap the Verify line caught, a plan edit that was wrong). No note is fine; a made-up note is not.

Done when: the gate is clean, the Verify line passed, the only red tests are the ones Known failures lists, format and lint are clean, and the round is logged.

## 7. Open the PR

Write the judge packet first, at `.claude/judge/<branch>.md`, in exactly this shape (the gate script parses the two `KEY: value` lines, so keep them on their own lines near the top):

```
# Judge packet: <branch>
CHECKS_SHA: <full sha of the checks commit>
HEAD: <full sha of the commit being pushed>
BASE: <origin/main sha the branch started from>
ROUNDS: <n>
SPEC_STARTED: <the utc minute from step 2>
INTERRUPTIONS: <user messages that changed scope, approach or a check since plan approval; 0 if none>

## Spec
Goal: ...  Acceptance: ...  Out of scope: ...  Verify: ...  Files: ...   (the five lines from step 2)

## Counts
<the unit suite summary line from step 6>

## Verify
<the Verify command, then its output>
```

The push is gated by `~/.claude/hooks/judge-gate.sh`, a PreToolUse hook on every real push. It refuses the push, with the reason returned to you, when any of these fail: no packet; packet `HEAD` is not the current HEAD; uncommitted changes in `<tests>`; a commit after `CHECKS_SHA` touching `<tests>` whose title is not `<KEY>: Correct check ...`; a Correct check commit touching a test file the checks commit did not; a red test not listed in `.claude/known-failures.txt`. It then runs the suite itself (the command in `.claude/harness.json`) and hands the summary, the diff stat and the packet to a headless judge, which reads the checks, the diff and the Verify output and ends with `VERDICT: PASS` or `VERDICT: FAIL`. The verdict is appended to `<branch>.verdict.md` beside the packet, one dated section per run with a `Usage:` line (the judge's tokens and cost), so a FAIL followed by a PASS leaves both. On FAIL, fix what it names, re-run step 6, rewrite the packet with the new HEAD, and push again. Never edit the packet to argue with the judge, and never edit `.claude/judge/*.verdict.md`. If the gate says the claude CLI is not logged in, stop and tell the user; that is a one-time `claude login` on their side.

Push the branch with `git -C <repo root> push -u origin <branch>` so the gate judges the right repo. Open the PR with `gh pr create` against `main`. When `gh` is not authenticated, write a prefilled compare link instead and give it to the user:

```
https://github.com/<org>/<repo>/compare/main...<branch>?quick_pull=1&title=<urlencoded title>&body=<urlencoded body>
```

PR title: `<KEY>: <what changed>`. PR body sections, in order: **Why** (the goal, in the ticket's words), **What** (the edits, as behaviour), **Tests** (the checks commit hash, what was added, the counts from step 6), **To verify on QA** (the acceptance checks as steps a tester follows), **Out of scope** (carried over from the spec, plus anything parked). Save the link and the body to `.claude/<KEY>-pr.md` so they survive the session.

Draft the tracker comment that names the repo, the branch and the PR, and the transition to the review status, and show both to the user. Post or transition only if the approved plan says to.

Done when: the user has a PR link, the PR body matches the spec, and the `.claude/<KEY>-pr.md` note exists.

## 8. Close the session, and every fifth ticket review the loop

The PR being merged to `main` ends the session. Promotion to a release branch is a separate PR on its own schedule, per `CLAUDE.md`'s deploy paths. A repo fact learned this session (a command, a gotcha, a wrong assumption) is a one-line edit to the local `CLAUDE.md`, which is never committed, or a note to the user.

Right after the PR is open, append the ticket's row to `.claude/metrics.csv` (columns in `docs/metrics.md` of the harness repo):

```
python3 -I ~/.claude/hooks/metrics-row.py <repo root> <branch> <pr number> --mutants <run>/<survived> --qa <bounces so far, 0 if none> --session-tokens <n>
```

It reads the packet (`ROUNDS`, `SPEC_STARTED`, `INTERRUPTIONS`), the verdict sections (judge FAILs and tokens), git (checks, Correct checks, round date) and gh (PR state, times, approvals, comments). The three typed values come from the checks review (mutants), the tracker's history (bounces) and this session's usage: `get_usage` for this session in the app, `/cost` in the CLI, input plus output tokens. `--dry-run` prints the row without appending. The row log and the metrics row describe the same round, written at the same time.

At the fifth-ticket review below, first run `python3 -I ~/.claude/hooks/metrics-row.py --refresh <repo root>`, which re-reads gh for every row whose PR was still open and fills in the merge time; QA bounces that happened after a row was written are corrected by hand from the tracker's history.

When `.claude/loop-results.md` has five or more rows since the last review marker, run the review before closing:

1. Read every row since the marker. Look for the same failure or note appearing twice or more.
2. For each repeat, write one rule in the "How to work" section of `CLAUDE.md`: what to do differently, in one sentence, with the ticket keys it came from. Remove a rule that no round has needed since it was written.
3. Never change Known failures, the Commands table, or any file in `<tests>` from this review. The review edits habits, not checks.
4. Append a row `| <date> | review | | | marker | | <n> rules changed |` to the log.

Done when: the user has been told the PR is merged or what still blocks it, in one message, and the review row exists if one was due.
