# Per-ticket metrics

`.claude/metrics.csv` in each target repo: one row per `/ticket` round-set (one packet, one push, one PR), the same columns in every repo, so `cat` of the files is the whole picture. Local-only, never committed. `/ticket` step 8 appends the row:

```
python3 -I ~/.claude/hooks/metrics-row.py <repo root> <branch> <pr> --mutants R/S --qa N --session-tokens N
```

It reads the packet, the verdict sections, git and `gh`; `--dry-run` prints the row; `--refresh <repo root>` re-reads `gh` for rows whose PR was open and fills the merge time; `--outcomes <repo root>` fills the three defect-escape columns (below). Timestamps are UTC to the minute. Blank means not captured; 0 means counted and zero.

## Columns

| column | meaning | source |
|---|---|---|
| repo, ticket, branch, pr, pr_state | identity; `ticket` is read from the branch with `ticket_key_regex` (config) and may carry a short tag by hand when one ticket has several rounds | branch, gh |
| round_date | the checks commit's date | git |
| checks | test functions the branch adds (BASE to HEAD, so Correct checks count); the helper counts added `def test_` lines, or `it(`/`test(` blocks including `.each`, so a table-driven block counts once | git |
| rounds | build-then-verify passes before green | packet `ROUNDS` |
| correct_checks | `Correct check` commits on the branch | git log |
| mutants_run, mutants_survived | the checks reviewer's mutation pass; blank when not counted | typed |
| judge_fails | `VERDICT: FAIL` sections in `.claude/judge/<branch>.verdict.md` | verdict file |
| qa_bounces | ticket-level: how often the ticket went from review-or-later back to development after the PR opened; blank when not measured | typed, or the `--outcomes` pass from the tracker's changelog |
| prod_incidents | Sentry issues first seen in the customers' environment after the PR reached the release branch, with a frame in a file the PR changed or a link to the ticket; blank until the PR is on that branch or while Sentry is unreachable | the `--outcomes` pass |
| human_approvals, human_review_comments, changes_requested | reviews, inline plus review-body plus issue comments, and change requests on the PR by anyone but the author or a bot | gh |
| plan_approved_utc, packet_utc, pushed_utc | file times of `.claude/judge/<branch>.plan.md`, `<branch>.md`, `<branch>.verdict.md`; blank when the file does not exist or a later round on the same branch overwrote it | file mtimes |
| pr_opened_utc, pr_merged_utc | as GitHub records them | gh |
| plan_to_push_min | pushed minus plan approved; the builder plus verify plus packet span | derived |
| open_to_merge_h | merged minus opened; the human review wait | derived |
| spec_started_utc | the packet's `SPEC_STARTED` line, written at step 2 | packet |
| session_tokens | input plus output tokens of the session, read at step 8 (`get_usage` in the app, `/cost` in the CLI) | typed |
| judge_tokens | sum of input, cache_create, cache_read and output over every `Usage:` line in the verdict file (all judge runs for the branch) | verdict file |
| interruptions | the packet's `INTERRUPTIONS` line: user messages after plan approval that changed scope, approach or a check; 0 when none | packet |
| note | anything that qualifies the numbers | hand |

## What the first weeks of rows showed

Thirty-four rows over two repos and two weeks, backfilled from the round logs, the packet file times and GitHub before the helper existed. Numbers rounded; they are here as an example of what the file answers, not as targets.

- plan_to_push_min: median about 70 minutes over the rows with a plan file, 53 without two multi-day spans. Shortest 16, longest same-day 120.
- open_to_merge_h: median 20 hours over 30 merged PRs, from 0.1 h (review PRs merged in the same sitting) to 100 h (a stacked set opened on a Thursday and merged the following Monday).
- Checks: 667 test functions, median 11.5 per row. 21 of 34 rows carry at least one Correct check commit. The 11 logged mutation passes ran 281 mutants and 40 survived (14 percent); every survivor was closed by a Correct check before the push.
- Rounds: 15 of 34 rows were green on the first run; median 2.
- QA bounces: 6 of the 16 ticketed rows bounced once. Every one was a design-review pass on a visual change, not a failed build, and each produced a follow-up row with a 0.1 to 1.4 h open_to_merge.
- Human review: 31 approvals, 0 comments, 0 change requests on 31 approved PRs, all by one reviewer. The columns stay because the zero is the finding: the only review the code gets is the harness's three reviewers plus the judge, so those are what the quality columns have to validate.
- Judge: 1 FAIL in 32 verdicts, caught by reading the Verify output against the Acceptance line (two pixels under the promised width).

## Capture

Everything the helper needs is written as a side effect of the loop: `SPEC_STARTED` and `INTERRUPTIONS` by the skill at steps 2 and 7, the `Usage:` line by the gate per judge run, the plan file at approval. Only three values are typed (mutants, QA bounces, session tokens) because nothing on disk knows them. At the fifth-ticket review, `--refresh` fills merge times; QA bounces that happened after a row was written are corrected by hand.

The metric that would validate the whole apparatus is the escape rate: human review comments per PR, QA bounces per ticket, production incidents traced to a merged ticket. The three columns below carry it, one source each.

## Outcomes: defect escape rate

Three columns, one source each. In all three, blank means not measured (the source was unreachable, the row has nothing to look up, or the ticket has not reached that stage yet) and 0 means measured and zero. The pass never writes a 0 it did not count.

**qa_bounces (the tracker).** A bounce is one status transition in the issue's changelog, dated after the row's `pr_opened_utc`, that leaves a review-or-later status (`outcomes.jira.late_statuses`, default In Review and Done) for a development one (`outcomes.jira.early_statuses`, default In Progress and Reopened). A workflow with stations between review and done (In QA, Ready for release) lists them as late statuses, so leaving them backwards counts too. Each transition counts once; a row with several keys sums them. Transitions before the PR opened are development churn, not escapes. A row whose ticket field has no key is written blank, whatever was typed before, since 0 would claim a measurement. Cannot see: a defect fixed through a new ticket while the original moves forward; feedback given outside the tracker; whether a bounce was the build's fault or a spec change.

**prod_incidents (Sentry).** The time the ticket reached customers is the committer date of the first first-parent commit on `origin/<outcomes.release_branch>` that contains the PR's merge commit (a promotion merge; every ticket in one promotion shares that instant). An incident is a Sentry issue in `outcomes.sentry.projects` and environment `outcomes.sentry.environment` whose `firstSeen` is after that time, and which either has, in its latest event, a stack frame whose filename is a file the PR changed (suffix match on whole path components either way, so `app/x.py` matches `/srv/app/app/x.py`, but a bare basename never matches) or carries a linked tracker issue (Sentry's external-issues list or the issue's annotations) whose key is one of the row's tickets. An issue that matches two PRs counts on both rows. Cannot see: anything on a pre-production environment (a QA finding, not a production one); wrong behaviour that raises nothing; an incident whose frames are in files the PR did not touch although the PR caused it; a regression of an issue Sentry had already grouped; incidents reported in chat and never in Sentry. A PR that has not reached the release branch is blank, not 0: the question has not been asked yet.

**human_review_comments (GitHub).** Review comments on the PR by anyone but the PR author or a bot account: every comment in every review thread, the PR's conversation comments, and the summary text of a submitted review when it is non-empty; an approval with no text adds nothing (approvals are `human_approvals`). Cannot see: feedback given outside GitHub; a comment deleted before the pass ran; a reviewer who approved without reading.

### Outcomes pass

`python3 -I hooks/metrics-row.py --outcomes <repo root> [--since YYYY-MM-DD] [--dump-dir DIR] [--dry-run]` rewrites only `qa_bounces`, `human_review_comments` and `prod_incidents` on the rows whose `round_date` is on or after `--since` (default `outcomes.since`, else every row) and adds the `prod_incidents` column to a file that lacks it; every other cell is written back as read. GitHub comes from `gh`; Jira from the REST API with `ATLASSIAN_EMAIL` and `ATLASSIAN_API_TOKEN` (site from `ATLASSIAN_SITE` or `outcomes.jira.site`); Sentry from the REST API with `SENTRY_AUTH_TOKEN` (scopes `org:read`, `event:read`, `project:read`), all read from the environment or the file `outcomes.secrets_file` names. A source without its token, site, org or release branch is reported as unreachable at the end of the run and its cells are left exactly as they were, never zeroed. A session that has a tracker or Sentry connector but no token can save the connector's JSON answers under `--dump-dir` (`jira/issue__<KEY>.json` holding the REST issue object with its `changelog`; `sentry/projects__<org>__<project>__issues.json` holding the REST issue list; `sentry/issues__<id>__events__latest.json` holding the REST event) and the pass reads those instead; a missing file is unreachable, not zero. Run it before any workflow review, on every target repo; `prod_incidents` only starts to mean something a week or so after a promotion, so a review written the day after one reads blanks, not zeros. Test: `python3 -I hooks/tests/test-metrics-row.py`.
