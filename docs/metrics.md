# Per-ticket metrics

`.claude/metrics.csv` in each target repo: one row per `/ticket` round-set (one packet, one push, one PR), the same columns in every repo, so `cat` of the files is the whole picture. Local-only, never committed. `/ticket` step 8 appends the row:

```
python3 -I ~/.claude/hooks/metrics-row.py <repo root> <branch> <pr> --mutants R/S --qa N --session-tokens N
```

It reads the packet, the verdict sections, git and `gh`; `--dry-run` prints the row; `--refresh <repo root>` re-reads `gh` for rows whose PR was open and fills the merge time. Timestamps are UTC to the minute. Blank means not captured; 0 means counted and zero.

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
| qa_bounces | ticket-level: how often the ticket went from QA back to development; blank when it has not reached QA | typed, from the tracker's history |
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

The metric that would validate the whole apparatus is the escape rate: human review comments per PR, QA bounces per ticket, production incidents traced to a merged ticket. The file has the first two columns; the third is a note until there is a place it is recorded.
