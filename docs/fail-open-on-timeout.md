# A PreToolUse hook that times out fails open

The second incident the harness is built around, after [the judge that rationalised](judge-leniency.md). This one was not the judge's fault, or the script's. It was the hook runtime's contract, which nothing in the gate had been written against.

## What happened

A push on a gated feature branch went out with no verdict on record. The gate had not been skipped: the transcript showed it started for that push, then recorded as `hook_cancelled` with `timedOut: true` against the hook's 900 s timeout, and the push landed four seconds later. The laptop had gone to sleep with the lid closed while the gate was running the suite and the judge. The hook's timer is wall-clock, so by the next wake it had expired. Claude Code treats a PreToolUse hook that exceeds its timeout as cancelled and runs the tool anyway.

Two more Bash calls in the same session were cancelled the same way. One of them was a command the gate denies in under a second (its `cd <path>` target did not exist), yet it was cancelled too: the hook process itself was not running when the clock ran out, because the machine was asleep. Each of the three calls had been issued within seconds of a brief wake, so the turn resumed, spawned the hook, and slept again.

From inside the session it looked like the push "went through in seconds". The session's own notes said so.

## What reproduces

A throwaway setup: a bare `origin.git`, a work checkout on a feature branch with no packet, a copy of the hooks block pointing at a wrapper that logs each invocation and then runs the real gate, and a second copy pointing at a script that sleeps 20 s and then denies, with `timeout: 5`. Each case ran headlessly (`claude -p "<run exactly: git push -u origin feat-probe>" --permission-mode <mode> --allowedTools Bash --settings <copy>`), and `origin` was reset between cases.

| case | gate ran | push landed |
|---|---|---|
| plain shell `git push` | no | yes: the hook is a Claude-side check only; git itself has no gate |
| `claude -p`, `--permission-mode auto`, the real gate | yes | no, denied: no packet |
| `claude -p`, `--permission-mode bypassPermissions`, the real gate | yes | no, denied the same way: bypass does not skip hooks |
| `claude -p`, auto, a slow deny with `timeout: 5` | started, never reached its deny | yes; the model reported "The push succeeded" |

The last row reproduced on two CLI versions (2.1.296 and 2.1.309). The suspected "auto mode skips user-level hooks" did not reproduce at all.

## Why it matters

A gate is a hook that legitimately runs for minutes: the suite, then a judge that reads a diff and thinks. Its original hook timeout (900 s) sat only 60 s above the judge's own cap (840 s), so a slow judge or a sleep of any length put the push on the wrong side of the timer. Any PreToolUse hook on a laptop is exposed to this when the lid closes mid-turn; a gate is exposed most.

The deeper point is the one from the leniency incident, from the other side. There the judge was given a fact to check and rationalised it; here the runtime was trusted with a decision (what to do when the check does not finish) and its default was the wrong direction. A gate must fail closed, and it cannot rely on anything outside the script to do that.

## What changed

Three things, all in this repo:

1. **The gate keeps its own clock** (`hooks/judge-gate.sh`, config `budget`, default 1200 s). Every slow step gets the smaller of its own timeout and what is left of the budget; a step that exceeds it, or a budget that is spent before the judge can start, is a deny that says so and tells the user to push again with the machine awake. The hook timeout in `settings.example.json` is 7200 s, and the test suite asserts it is at least twice the budget, so the gate always answers before the runtime stops waiting. The deny is a Claude-side refusal: a sleep long enough to outlive 7200 s still lets the tool run, which is why the next two exist.
2. **The verdict is published where CI can see it** (`hooks/judge-status.sh`, a PostToolUse hook on Bash). After every successful feature-branch push it posts a commit status on the pushed sha, context `judge-gate/verdict`: `success` with `VERDICT: PASS <utc>` when a PASS section for that exact sha exists in `.claude/judge/<branch>.verdict.md`, `failure` with `no judge verdict for this sha` otherwise. It never blocks, and it logs what it did or skipped to `~/.claude/hooks/logs/judge-status.log`.
3. **A CI job requires that status** (`ci/require-judge-verdict.yaml`). On every pull request to the base branch by a gated author, the job fails when the head sha has no `success` status in that context, so a push the gate never finished judging is red on the PR instead of invisible. Drafts, other authors and release or bot branches are exempt, so the job is safe to make required.

Still true after all three: the status hook is also a hook, so a sleep can lose the status post too. The CI job then fails the PR for lack of a status, which is the right direction to fail in; re-posting is one run of the status hook, and the job is re-run by hand.

## What to take from it

- Read the runtime's contract for the thing you are relying on, before relying on it. "A hook can deny" and "a hook that does not answer denies" are different promises, and only the first one was made.
- Keep the timeout you control far inside the one you do not, and make the inner one refuse.
- Leave a trace that something downstream checks. The ungated push was found days later, by reading a transcript. With the status and the CI job it is found by the PR going red.
