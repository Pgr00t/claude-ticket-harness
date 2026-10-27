# The judge that rationalised: an eval lesson

This is the incident the harness is built around. It is short, it happened on the first real run, and it would have been invisible without one habit: reading the judge's report instead of its verdict.

## The setup

On 2026-10-13 the push gate ran end to end for the first time. At that point the script did three things mechanically (packet exists, packet `HEAD` is the current HEAD, test paths unchanged since the checks commit) and then handed everything else to a headless judge, including this instruction, step 6 of its prompt at the time:

> Run the unit suite. Compare every red item against the Known failures section of CLAUDE.md. A red test that is not listed there is a FAIL.

Known failures was a list in `CLAUDE.md` of tests that were red on the base branch for reasons unrelated to any ticket, nine of them at the time. The judge had Read, Grep and read-only git, and could run the suite.

The branch under test was a throwaway worktree with a real checks commit and a trivial helper. Nothing about it was wrong.

## What the judge did

The suite had one red test that was not on the list: it had gone red on the base branch a few days earlier and nobody had added it. The judge's report for step 6 said the suite had one failure, named the test, stated that it was in the Known failures section, and marked the step PASS. The final line was `VERDICT: PASS`.

The test was not in that section. The judge had the file open (step 1 of its prompt has it read `CLAUDE.md`), it had the test's name, and it produced a sentence joining the two that was false. The push would have gone through. Only the report, read line by line against the file, showed the gap.

## Why this is the important failure

Three things make it worse than an ordinary wrong answer.

**It is silent.** A judge that passes a branch it should have failed produces exactly the output a correct PASS produces. The only signal was in the prose, and prose is what nobody reads once the gate has run forty times.

**It is the convenient answer.** The model was given a list and an item and asked whether the item was on the list, in a context where "yes" ended its job and "no" meant failing a branch that was otherwise fine. It said yes. That is not a bug in one model; it is what a model does when a fact check is dressed as a judgement call and the facts are a page away.

**It was the one check the judge was uniquely bad at.** Comparing a test id with a list is a string operation. Every other step in the prompt (is this test vacuous, is this function called from anywhere, does the Verify output demonstrate the Acceptance line) needs reading and judgement. Step 6 needed `grep -x -F`.

## What changed, the same day

The response was not a better prompt for step 6. It was to take step 6 away from the judge.

1. **The script runs the suite and does the comparison.** The gate loads the test env, runs the suite command, extracts every `FAILED <id>` and `ERROR <path>` line, and compares each id with `.claude/known-failures.txt`. An unlisted id is a deny with the id in the reason. The judge is never started.
2. **The judge is told the fact is settled.** Its prompt now says, verbatim: the lock and the suite "were both checked mechanically before you were called (suite summary: ...). Do not re-judge either; do not fail step 1 on the lock, and do not explain away any number. More generally: never rationalise a discrepancy. If the evidence for a step is missing or you could not check it, that step is a FAIL, not a PASS with a caveat."
3. **The list moved out of prose.** Known failures became a file with one id per line, so a script could read it. `CLAUDE.md` points at the file.
4. **The red test was added to the list with a dated note**, which is what should have happened days earlier.

The principle: a script owns every fact the gate depends on. The judge gets only the questions that need a reader.

## The two follow-ups that confirmed it

**2026-10-14, the judge was right and the fact still moved into the script.** On the first real ticket the judge returned FAIL on one point: a fixture fix in an unrelated test, committed after the checks commit under a `Correct check` title. The script had allowed it (the title matched). The judge read it as a lock break, which it was. The fix was not "trust the judge on this": the script gained the rule that a Correct check commit may only touch test files the checks commit itself touched (`git show --name-only`, subset check), and the judge was told the lock is not its job either. Same principle from the other side: a judgement that turns out to be a fact becomes code.

**2026-10-27, the fact check itself was found to be loose.** The script's comparison was a substring match (`grep -F` without `-x`). Two of the four entries in the list were a whole file name and a whole class name, so any new red test in that file or class matched and was invisible. The comparison became exact (`grep -x -F`), the list was rewritten to whole ids, and `CLAUDE.md`'s section with it. A fact check that is not exact is not a fact check; it is the judge's rationalisation with the model removed. A week later the list was emptied altogether by fixing the red tests, which is the simpler gate.

## What the judge is still trusted with

Four questions, each of which needs a reader and none of which reduces to a string comparison:

1. **Vacuous checks.** Does each test in the checks commit assert the behaviour in the Acceptance line, or would it pass without the feature (asserting on a mock it set itself, asserting only that something exists)?
2. **Scope.** Does every change in the diff serve the Goal line, and does nothing touch what Out of scope excludes?
3. **Wiring.** Does every new function, method or class have a caller, in the diff or in existing code?
4. **Verify evidence.** Does the packet's Verify output demonstrate the Acceptance line, or is it missing or unconvincing?

Across the first thirty-two verdicts the judge returned one FAIL, and it was the right kind: a rendered element two pixels narrower than the width the Acceptance line promised, found by reading the Verify output in the packet against the spec. No script would have caught that. That is the judge earning its place.

## The test cases that pin it

`hooks/tests/test-judge-gate.sh` runs the real gate with a fake suite and a fake judge. These cases exist because of this story:

- `an unlisted red test is refused and named`: the deny reason carries the id.
- `the judge is not called when an unlisted red test exists (the script owns that fact)`: the fake judge records its arguments to a file; the case asserts the file was never written.
- `a class name alone does not cover a red test in that class`, `a file name alone does not cover a red test in that file`, `a longer id does not cover a shorter one`: the 2026-10-27 lesson, as three mutants of the list.
- `with two red tests and one listed, the other is named` and `the listed red test is not named as unknown`: the comparison is per id, both ways.
- `the judge prompt carries the suite summary and says the comparison was mechanical` and `the judge prompt forbids rationalising and re-judging the mechanical checks`: the fake judge's recorded arguments contain the prompt, so the sentences above are pinned as text.
- `a Correct check touching a test file the checks commit did not is refused`: the 2026-10-14 rule.

If someone later "simplifies" the gate by handing the suite back to the judge, the second case fails first.

## The general rule

An LLM judge is good at questions whose answer needs reading and bad at questions whose answer needs comparing. When a judge is given a fact to check, three things happen: it costs more than a script, it is sometimes wrong, and when it is wrong it is wrong in the direction that ends its job. So:

- Every fact the gate depends on is computed by the script and handed to the judge as settled.
- The judge is told which facts are settled and told not to revisit them.
- Missing evidence is a FAIL, stated in the prompt, so the judge cannot pass a step by assuming.
- The judge's report is saved next to the packet and read, not just its last line.
- The split is pinned by a test that asserts the judge was not called.

Nothing here is specific to one model. The judge that rationalised was the strongest model available at the time, and the point is that strength did not help: the task was shaped so that the convenient answer was available, and no model should be given that shape.
