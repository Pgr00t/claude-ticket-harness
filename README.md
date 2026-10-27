# claude-ticket-harness

A checks-first workflow for Claude Code: one ticket, one session, one PR, with the tests locked before the code is written and a push that a script and then a judge must both allow.

It is four hooks, one skill and a config file:

- **`hooks/judge-gate.sh`**: a PreToolUse hook that refuses `git push` on a feature branch unless a judge packet exists for the current HEAD, the test files are unchanged since the checks commit, the suite's red tests are all on the known-failures list, and a headless Claude judge returns `VERDICT: PASS`. The first three are computed by the script. The judge is only asked what needs a reader: vacuous checks, scope, wiring, verify evidence.
- **`hooks/format-on-edit.sh`**: a PostToolUse hook that formats each edited file with the tools of the repo that owns it.
- **`hooks/link-worktree-local-files.sh`**: a SessionStart hook that symlinks the untracked harness files into a git worktree, so parallel sessions work.
- **`hooks/metrics-row.py`**: one row per round in a CSV, from the packet, the verdict file, git and `gh`.
- **`skills/ticket/SKILL.md`**: the `/ticket` procedure. Spec, plan, approval, then checks red and committed, build, verify against the running app, packet, push, PR, round log, and a review every five rows that rewrites the rules the session works by.

`docs/how-it-works.md` has the whole mechanism. `hooks/tests/` runs the real scripts against throwaway repos with fake `poetry` and `claude` binaries, 96 cases, about ten seconds.

## The judge that rationalised

The gate exists in its present shape because of one run. On 2026-10-13, the first time the judge ran for real, its prompt asked it to compare the suite's red tests against a list of known failures. The suite had one red test that was not on the list. The judge's report named the test, said it was on the list, and passed. It was not on the list. Nothing else was wrong with the branch, so the push would have gone through, and the only trace was one false sentence in a report nobody reads once the gate has run forty times.

The fix was not a better sentence in the prompt. The script now runs the suite and compares ids itself, exactly, and denies the push before the judge is started. The judge is told which facts were settled mechanically, told not to revisit them, told never to rationalise a discrepancy and to treat missing evidence as FAIL. A test case asserts that when an unlisted red test exists the judge process is never invoked. The judge keeps the questions that need a reader, and its one real FAIL since then was the right kind: a rendered width two pixels under what the spec promised, found by reading the verify output.

Scripts for facts, models for judgement. The full story, including the two follow-ups that confirmed the rule from the other side, is in [`docs/judge-leniency.md`](docs/judge-leniency.md).

## Install

Requirements: bash 3.2 or newer (macOS's own bash is fine), git, jq, python3 (for the metrics helper and its test), and Claude Code with the `claude` CLI logged in (`claude login`, once, same account as the app). GNU coreutils `timeout` is optional: with it the suite and the judge get time limits, without it they run unbounded.

1. Clone and run the tests. They touch nothing outside a temp dir.

   ```bash
   git clone https://github.com/Pgr00t/claude-ticket-harness.git && cd claude-ticket-harness && bash hooks/tests/run-tests.sh
   ```

2. Copy the hooks to where the settings block expects them.

   ```bash
   mkdir -p ~/.claude/hooks && cp hooks/*.sh hooks/metrics-row.py ~/.claude/hooks/
   ```

3. Merge the three entries from `settings.example.json` into the `hooks` block of `~/.claude/settings.json`. With jq, when there is no `hooks` block yet:

   ```bash
   jq -s '.[0] * .[1]' ~/.claude/settings.json settings.example.json > /tmp/settings.json && mv /tmp/settings.json ~/.claude/settings.json
   ```

   With an existing block, append each array by hand. The PreToolUse entry has no `if` filter on purpose: the script decides in a few milliseconds whether a command is a push.

4. In each target repo:
   - `mkdir -p .claude && cp <harness>/harness.example.json .claude/harness.json`, then edit it: the suite command, the env file, the protected branches, the ticket key regex. Every key is optional; `docs/how-it-works.md` lists the defaults.
   - Create `.claude/known-failures.txt` (empty, or one whole test id per line for tests that are red on the base branch).
   - Copy `skills/ticket/SKILL.md` to `.claude/skills/ticket/SKILL.md`.
   - Write a `CLAUDE.md` with a Layout line (source tree and test paths), a Commands table, a Known failures section, Conventions, and an empty "How to work" section for the review to fill.
   - Add `.claude/` and `CLAUDE.md` to `.git/info/exclude` if they are not to be committed. The worktree hook relies on the main checkout having them.

5. Start a session in the repo and run `/ticket KEY-123`.

## What it does not do

- It does not make the builder honest by itself. The lock and the gate are enforcement for the test files and the push; everything the skill says about specs, reviewers and the Verify line is still a procedure the session follows or does not.
- It does not run in CI. The hooks are local to the machine and the Claude Code session; a push from a plain terminal is not gated.
- It does not evaluate the judge. The leniency story is one incident and one fix; there is no labelled set of past branches measuring how often the judge is right. That is the next thing to build.
- It does not replace human review. The metrics file exists to measure whether the harness's reviewers and judge earn their cost against human review comments and QA bounces; it cannot answer that yet.
- It parses two suite formats, pytest and vitest plus tsc. A repo of any other kind runs with `kind: other`, which skips the suite and keeps the packet, the lock and the judge.
- It assumes one ticket per branch, a packet named after the branch, and a `Correct check` commit title. Those names are shared between the skill, the gate and the metrics helper and are not configurable.
- The known-failures list is a crutch for a red base branch. The simpler gate is a green suite and an empty list.

## Layout

```
hooks/                      the four scripts, read .claude/harness.json in the target repo
hooks/tests/                one test file per hook, run-tests.sh runs them all
skills/ticket/SKILL.md      the /ticket procedure
docs/how-it-works.md        the loop, the lock, the gate, the judge, the log, the metrics, the config
docs/judge-leniency.md      the 2026-10-13 incident as an eval lesson
docs/metrics.md             the CSV columns and what the first weeks showed
harness.example.json        every config key with its default
settings.example.json       the three hook entries for ~/.claude/settings.json
```

## Licence

MIT, Paras Singhal, 2026.
