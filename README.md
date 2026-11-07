# claude-ticket-harness

A checks-first workflow for Claude Code: one ticket, one session, one PR, with the tests locked before the code is written and a push that a script and then a judge must both allow.

It is five hooks, one skill, a CI job and a config file:

- **`hooks/judge-gate.sh`**: a PreToolUse hook that refuses `git push` on a feature branch unless a judge packet exists for the current HEAD, the packet's checks commit is the first commit after the base that touches a test path, the test files are unchanged since that commit, a diff that touches a deployable surface (a background task, a workflow, a Dockerfile, a migration) carries a `DEPLOY_AND_PROMOTION` line, the suite ran to a green finish, and a headless Claude judge returns `VERDICT: PASS`. Everything before the judge is computed by the script. The judge is only asked what needs a reader: vacuous checks, scope, wiring, verify evidence, and whether the deploy line matches the diff. The gate keeps its own wall-clock budget and refuses the push when a step cannot finish inside it, because a hook that outlives its timeout fails open.
- **`hooks/judge-status.sh`**: a PostToolUse hook that, after a successful feature-branch push, posts the judge's verdict for the pushed sha as a GitHub commit status (`judge-gate/verdict`), so that `ci/require-judge-verdict.yaml` can fail a pull request whose head was never judged.
- **`hooks/format-on-edit.sh`**: a PostToolUse hook that formats each edited file with the tools of the repo that owns it.
- **`hooks/link-worktree-local-files.sh`**: a SessionStart hook that symlinks the untracked harness files into a git worktree, so parallel sessions work.
- **`hooks/metrics-row.py`**: one row per round in a CSV, from the packet, the verdict file, git and `gh`; an `--outcomes` pass later fills the defect-escape columns from the tracker, GitHub and Sentry.
- **`skills/ticket/SKILL.md`**: the `/ticket` procedure. Spec, plan, approval, then checks red and committed, build, verify against the running app, packet, push, PR, round log, and a review every five rows that rewrites the rules the session works by.

`docs/how-it-works.md` has the whole mechanism. `hooks/tests/` runs the real scripts against throwaway repos with fake `poetry`, `claude` and `gh` binaries, 304 cases, about twenty seconds.

## The judge that rationalised

The gate exists in its present shape because of one run. On 2026-10-13, the first time the judge ran for real, its prompt asked it to compare the suite's red tests against a list of known failures. The suite had one red test that was not on the list. The judge's report named the test, said it was on the list, and passed. It was not on the list. Nothing else was wrong with the branch, so the push would have gone through, and the only trace was one false sentence in a report nobody reads once the gate has run forty times.

The fix was not a better sentence in the prompt. The script took the suite over: it ran the suite and compared ids itself, exactly, and denied the push before the judge was started. Since 2026-10-30 there is no list at all: the base branch is green, so any red test is a deny. The judge is told which facts were settled mechanically, told not to revisit them, told never to rationalise a discrepancy and to treat missing evidence as FAIL. A test case asserts that when a red test exists the judge process is never invoked. The judge keeps the questions that need a reader, and its one real FAIL since then was the right kind: a rendered width two pixels under what the spec promised, found by reading the verify output.

Scripts for facts, models for judgement. The full story, including the two follow-ups that confirmed the rule from the other side, is in [`docs/judge-leniency.md`](docs/judge-leniency.md).

## The hook that timed out

The second incident was the runtime's, not the judge's. A laptop went to sleep while the gate was running the suite and the judge; the hook's wall-clock timeout expired before the next wake, and Claude Code treats a PreToolUse hook that times out as cancelled and runs the tool anyway. The push went out with no verdict, and the session's own notes said it had "gone through in seconds". Reproduced headlessly with a hook that sleeps past a five-second timeout and then denies: the model reports that the push succeeded.

The gate now keeps its own clock (`budget` in the config, default 1200 s, with the hook timeout in `settings.example.json` at least twice that, which the tests assert) and refuses the push when a step cannot finish in time. Since a refusal from inside the hook cannot survive a sleep that outlives the outer timeout either, the verdict is also published as a commit status after every push, and a CI job fails the pull request when the head sha has none. The write-up is [`docs/fail-open-on-timeout.md`](docs/fail-open-on-timeout.md).

## The assignment that hid the push

The third bypass was a regex gap, found on 2026-11-07. The hooks recognise a push by matching the command text, and the match accepted an `env NAME=value git push` prefix but not a plain `NAME=value git push` one. A session pinning its GitHub account with `GH_TOKEN=$(gh auth token --user X) git -C "/worktree" push -u origin branch` was therefore seen by neither hook: no judge ran, no commit status was posted, and the CI job's red check was the only trace. Both hooks now share one marker-delimited block of regexes that accepts any number of leading `NAME=value` assignments (bare, quoted, `$VAR`, `${...}` or `$(...)`), and `hooks/tests/test-push-regex-sync.sh` fails when the two copies drift. A related limit is now stated in the denial: the hook reads the command text literally, so `git -C "$WT" push` is refused with a message that says to spell the path out.

## Install

Requirements: bash 3.2 or newer (macOS's own bash is fine), git, jq, python3 (for the metrics helper and its test), `gh` logged in (for the status hook and the metrics helper), and Claude Code with the `claude` CLI logged in (`claude login`, once, same account as the app). GNU coreutils `timeout` is optional: with it the suite and the judge are cut short at their time limits, without it a hung step is only caught by the budget checks between steps.

1. Clone and run the tests. They touch nothing outside a temp dir.

   ```bash
   git clone https://github.com/Pgr00t/claude-ticket-harness.git && cd claude-ticket-harness && bash hooks/tests/run-tests.sh
   ```

2. Copy the hooks to where the settings block expects them.

   ```bash
   mkdir -p ~/.claude/hooks && cp hooks/*.sh hooks/metrics-row.py ~/.claude/hooks/
   ```

3. Merge the four entries from `settings.example.json` into the `hooks` block of `~/.claude/settings.json`. With jq, when there is no `hooks` block yet:

   ```bash
   jq -s '.[0] * .[1]' ~/.claude/settings.json settings.example.json > /tmp/settings.json && mv /tmp/settings.json ~/.claude/settings.json
   ```

   With an existing block, append each array by hand. The PreToolUse entry has no `if` filter on purpose: the script decides in a few milliseconds whether a command is a push. Its `timeout` (7200) is not the gate's working time but the ceiling the gate's own `budget` must stay well under; lower both together or not at all.

4. In each target repo:
   - `mkdir -p .claude && cp <harness>/harness.example.json .claude/harness.json`, then edit it: the suite command, the env file, the protected branches, the deploy surface, the ticket key regex, and `status.gh_user` when more than one `gh` account is signed in. Every key is optional; `docs/how-it-works.md` lists the defaults.
   - Copy `skills/ticket/SKILL.md` to `.claude/skills/ticket/SKILL.md`.
   - Optionally copy `ci/require-judge-verdict.yaml` to `.github/workflows/`, put the gated GitHub logins in its `GATED_AUTHORS`, and make the `require-judge-verdict` check required on the base branch. Without it the commit status is posted and nothing reads it.
   - Write a `CLAUDE.md` with a Layout line (source tree and test paths), a Commands table, a Suite baseline line (the green counts on the base branch), Conventions, and an empty "How to work" section for the review to fill.
   - Add `.claude/` and `CLAUDE.md` to `.git/info/exclude` if they are not to be committed. The worktree hook relies on the main checkout having them.

5. Start a session in the repo and run `/ticket KEY-123`.

## What it does not do

- It does not make the builder honest by itself. The lock and the gate are enforcement for the test files and the push; everything the skill says about specs, reviewers and the Verify line is still a procedure the session follows or does not.
- It does not gate a push made outside a Claude Code session. The hooks are local to the machine and the session; a push from a plain terminal is not gated, and a hook that outlives its timeout is not either. What it does is leave a trace: the status hook marks every pushed sha as judged or not, and the CI job turns a missing verdict into a red pull request.
- It does not evaluate the judge. The leniency story is one incident and one fix; there is no labelled set of past branches measuring how often the judge is right. That is the next thing to build.
- It does not replace human review. The metrics file exists to measure whether the harness's reviewers and judge earn their cost against human review comments and QA bounces; it cannot answer that yet.
- It parses two suite formats, pytest and vitest plus tsc. A repo of any other kind runs with `kind: other`, which skips the suite and keeps the packet, the lock and the judge.
- It assumes one ticket per branch, a packet named after the branch, and a `Correct check` commit title. Those names are shared between the skill, the gate and the metrics helper and are not configurable.
- It assumes a green base branch. There is no list of accepted red tests: a test that is red on the base branch gets its own PR first. The first version of the gate had such a list, and `docs/judge-leniency.md` explains why it went.

## Layout

```
hooks/                      the five scripts, read .claude/harness.json in the target repo
hooks/tests/                one test file per hook, run-tests.sh runs them all
skills/ticket/SKILL.md      the /ticket procedure
ci/require-judge-verdict.yaml  the workflow that fails a PR whose head sha has no judge verdict status
docs/how-it-works.md        the loop, the lock, the gate, the judge, the log, the metrics, the config
docs/judge-leniency.md      the 2026-10-13 incident as an eval lesson
docs/fail-open-on-timeout.md  the 2026-11-02 ungated push: a hook that times out fails open
docs/metrics.md             the CSV columns and what the first weeks showed
harness.example.json        every config key with its default
settings.example.json       the four hook entries for ~/.claude/settings.json
```

## Licence

MIT, Paras Singhal, 2026.
