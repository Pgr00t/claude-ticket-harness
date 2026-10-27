# How it works

The harness turns one ticket into one PR inside one Claude Code session, with three things a prompt alone cannot provide: the tests are locked before the code is written, a push is refused unless a script and then a judge agree the branch is done, and every round leaves a row that a periodic review turns into rules.

## The loop

The `/ticket` skill (`skills/ticket/SKILL.md`) is the only procedure. In order:

1. **Read the ticket**, including comments.
2. **Five-line spec**: Goal, Acceptance, Out of scope, Verify, Files. The Verify line must hit the running application (a curl against the dev server, a worker task, a browser step), never the unit suite. Open questions are asked once, each with the answer that will be assumed.
3. **Plan and approval**: three lists (Checks, Edits, Verify). The user approves once and walks away.
4. **Checks**: tests written from the Acceptance line, run red for the stated reason, committed alone as `<KEY>: Add checks for ...`. That commit's hash is `CHECKS_SHA`.
5. **Build**: edit the source tree until the checks are green, ten rounds at most, then one refactor pass. A builder subagent on a cheaper model does steps 4 and 5; the parent session does the rest.
6. **Verify**: the diff gate (`git diff --quiet $CHECKS_SHA HEAD -- <tests>`), the Verify line, the suite, lint, three parallel reviewers (scope, vacuous checks, wiring; the checks reviewer mutates the build and names every mutant the checks let live), then one row in the round log.
7. **PR**: the judge packet, the push (gated), the PR, the metrics row.
8. **Close**, and every fifth row, the review that rewrites the "How to work" section of `CLAUDE.md`.

## The lock

Once the checks commit exists, the test paths are read-only for the session. The exception is a commit titled `<KEY>: Correct check <name>`, and it may touch only test files the checks commit itself created or changed. An unrelated test fix goes on its own branch, or is rebased to sit before the checks commit.

The skill states the rule; the gate enforces it with git:

- `git status --porcelain -- <test paths>` must be empty.
- `git log CHECKS_SHA..HEAD -- <test paths>` may contain only Correct check commits.
- Each Correct check commit's test files must be a subset of `git show --name-only CHECKS_SHA -- <test paths>`.

The range is `CHECKS_SHA..HEAD` without `--first-parent`, so a branch that merged the base branch into itself fails the lock (the base branch's own checks commits land in the range). Rebase instead, then rewrite the packet.

## The gate

`hooks/judge-gate.sh` is a PreToolUse hook on every Bash call. It answers `{}` within a few milliseconds for anything that is not a push, and gates the rest in this order, stopping at the first failure with a deny and a reason the session can act on:

1. **Is it a push?** An exact regex for `git push` or `git -C <path> push` in command position (line start, after `;`, `&`, `|`, `&&`, `||`, or inside `$(`). `echo "git push"` and a heredoc line `(git push)` are not pushes. The hook's own `if` filter in settings is deliberately absent: it was a prefix match, and both `git -C <root> push` and `cd <worktree> && git push` bypassed it.
2. **Which repo?** `git -C <path>` wins, then the last `cd <path>` before the push in the command text, then the session's cwd. A path that cannot be entered is a deny, not a pass-through.
3. **Which branch?** `main`, `master` and `release/*` (or `protected_branches` from the config) are never gated.
4. **Packet.** `.claude/judge/<branch>.md` must exist, its `CHECKS_SHA` must be a commit, its `HEAD` must be the current HEAD.
5. **Lock**, as above.
6. **Suite.** The repo's suite command runs (pytest for a python repo, tsc then vitest for a web one; `kind: other` skips this). Every red id is compared with `.claude/known-failures.txt` as a whole id: a file or class name in the list covers nothing. An unlisted red id is a deny. The judge is never asked about this; see `judge-leniency.md` for why.
7. **Judge.** `claude -p` with a prompt, the packet, the diff stat and the suite summary; read-only tools only. The report is appended to `.claude/judge/<branch>.verdict.md` with a dated header and a `Usage:` line (tokens, cost, seconds from the CLI's JSON). `VERDICT: PASS` allows the push; anything else denies it with the report.

Every step is covered by `hooks/tests/test-judge-gate.sh`, which runs the real script against throwaway repos with fake `poetry` and `claude` binaries on PATH. The script was written without tests and debugged in production for two weeks (a filter that over-matched, a `deny()` defined after its first call, an apostrophe that broke a heredoc under bash 3.2, a `git -C` that bypassed the gate, a merge that broke the lock range); each of those is a case now.

## The judge

The judge is a separate `claude -p` process. It reads, in order: `CLAUDE.md`, the packet, the checks commit, the diff since the checks commit excluding tests, callers for every new function (wiring), and the Verify output in the packet. It answers one line per step and a final `VERDICT: PASS` or `VERDICT: FAIL`.

It is told, in the prompt, that the lock and the suite were checked mechanically before it was called, not to re-judge them, never to rationalise a discrepancy, and that missing evidence for a step is a FAIL and not a PASS with a caveat.

Its tools: Read, Grep, Glob, read-only git, and the suite runners (so it can re-run a test it doubts). Edit, Write and every history-changing git command are disallowed explicitly, because `claude -p` reads the project's own allowlist and that may include `git commit`.

The judge's model and timeout come from `judge.model` and `judge.timeout` in the config; the default is the strongest model available.

## The round log and the review

`.claude/loop-results.md` in the target repo takes one row per round: date, ticket, checks written, round, result, what failed and why, a note for How to work. The note is written only when a habit showed up; a made-up note is worse than none.

Every five rows the skill runs a review: repeats become one-sentence rules in the "How to work" section of `CLAUDE.md`, with the ticket keys they came from; a rule no round has needed is removed. The review never touches Known failures, the Commands table or a test. This is the only place the harness learns, and it only learns if the review runs; the first review on one of the source repos happened after thirteen rows, and found six rules.

## The metrics

`hooks/metrics-row.py` appends one row per round-set to `.claude/metrics.csv` from the packet, the verdict file, git and `gh`. Three values are typed because nothing on disk knows them: mutants run and survived, QA bounces, session tokens. `docs/metrics.md` has the columns and what the first weeks of rows showed. The point of the file is the quality columns (human review comments, changes requested, QA bounces, judge FAILs), not the speed ones: they are the only way to tell whether the judge and the three reviewers earn their cost.

## The other two hooks

**`format-on-edit.sh`** (PostToolUse on Edit and Write) formats the one file that was touched with the tools of the repo that owns it, found by walking up to the nearest `pyproject.toml`, `package.json` or `.claude/harness.json`. Defaults: black then isort for `.py`; prettier then eslint for `.ts/.tsx/.js/.jsx`; stylelint then prettier for `.scss/.css`; prettier for `.json/.md` in a web repo. `formatters` in the config replaces any of these per extension. It never fails the edit.

**`link-worktree-local-files.sh`** (SessionStart) makes parallel sessions in git worktrees possible when the harness files are untracked by design. In a linked worktree it symlinks each of `CLAUDE.md .claude docs/agents TODOS.md .env .env.test node_modules` (or `worktree_links` from the main checkout's config) that the main checkout has and the worktree lacks, links `.venv` to the main checkout's poetry environment, and appends bare-path excludes to the shared `.git/info/exclude` because a `dir/` ignore pattern does not match a symlink. It also warns when `node_modules` was installed for a different lockfile than the branch's.

## Configuration

Everything site-specific lives in `.claude/harness.json` in the target repo. The file and every key are optional; a missing key means the default below. The gate denies a push when the file exists but is not valid JSON, so a typo cannot silently restore a default. `harness.example.json` at the repo root shows every key.

| key | default | read by |
|---|---|---|
| `kind` | detected: `python` when `pyproject.toml` and `tests/` exist, `web` when `package.json` exists, else `other` | gate |
| `test_paths` | `["tests/"]`; for web `["*.test.ts","*.test.tsx","*.spec.ts","*.spec.tsx","__tests__/*"]` | gate (lock pathspecs and the paths red ids must start under) |
| `protected_branches` | `["main","master","release/*"]` (globs) | gate |
| `suite.command` | python: `poetry run pytest tests/unit -q --continue-on-collection-errors -p no:cacheprovider`; web: `npx vitest run` | gate |
| `suite.typecheck_command` | web: `npx tsc --noEmit` | gate |
| `suite.env_file` | `.env.test` (loaded line by line, `KEY=value` lines only, before the suite) | gate |
| `suite.env` | `{}`; defaults for variables that are still unset after the env file | gate |
| `suite.timeout` | `300` seconds (needs coreutils `timeout`; without it the suite runs unbounded) | gate |
| `judge.model` | `claude-fable-5-1` | gate |
| `judge.timeout` | `840` seconds | gate |
| `judge.extra_allowed_tools` | `["Bash(poetry run pytest *)","Bash(npx vitest run *)","Bash(npx tsc *)"]`, added to Read, Grep, Glob and read-only git; `[]` removes them | gate |
| `ticket_key_regex` | `\b[A-Z]{2,}-\d+` (Python syntax) | metrics-row.py, to read the ticket from the branch name |
| `worktree_links` | `["CLAUDE.md",".claude","docs/agents","TODOS.md",".env",".env.test","node_modules"]` | link hook (read from the main checkout) |
| `formatters` | the defaults above, keyed by extension; `{file}` is the path, `""` disables | format hook |

Two things stay hard-coded on purpose. The packet is always `.claude/judge/<branch>.md` and the known-failures list `.claude/known-failures.txt`, because the skill, the gate and the metrics helper all name them. The Correct-check title is `<anything>: Correct check <name>` so the key format never matters to the lock.

## Files the harness writes in a target repo

All under `.claude/`, which stays untracked (`.git/info/exclude`):

| file | written by | read by |
|---|---|---|
| `harness.json` | you | every hook |
| `known-failures.txt` | you (one whole test id per line, comments allowed) | gate |
| `judge/<branch>.plan.md` | the session, at plan approval (optional) | metrics (plan time) |
| `judge/<branch>.md` | the session, step 7 | gate, judge, metrics |
| `judge/<branch>.verdict.md` | the gate, appended per run | metrics, you |
| `loop-results.md` | the session, step 6 | the review, step 8 |
| `metrics.csv` | `metrics-row.py` | you |
| `<KEY>-pr.md` | the session, step 7 | you |
