# TASK: a failing suite we cannot parse is "not measured", never "reddened nothing"

**Repo:** `git-scripts/` only. **Blocks making the tool portable** — it is being packaged as a skill for
other projects, and outside pytest it currently gives a confidently wrong answer.

---

## The defect

`py_classify` parses pytest's summary lines (`^(FAILED|ERROR)\s+…`). Any other test runner produces zero
matches, and **zero matches is treated as "reddened nothing"** — a survivor, a finding, exit 2.

**Reproduced.** A throwaway git repo, a two-line `mod.py`, and a shell test script printing Go-style
`--- FAIL: TestAdd` and exiting 1. The mutation (`a + b` → `a - b`) genuinely breaks the code and the suite
genuinely fails:

```
[1/1] break-add ... reddened nothing
  break-add: reddened nothing.
      No test in this run distinguishes the mutated code from the original.
git-mutate: 0 killed by assertion, 1 finding(s), 0 not measured.
```

**A well-defended behaviour reported as undefended, in the tool whose entire purpose is to prevent exactly
that.** Worse than an error, because the report reads as a real finding and its wording is emphatic.

## The fix

**The test command's exit status is already captured** — `st` in `run_test_cmd`, currently only compared
against 124 for the timeout. Use it: **a non-zero exit with nothing classifiable is `unclassified`, not
`survived`.**

- Keep the existing `n_u > 0` unclassifiable path; this adds the case where the summary yielded *nothing at
  all* while the command still failed.
- **A zero exit with nothing classifiable is a genuine survivor** and must stay one — that is the healthy
  case the tool is built to report. Pin both.
- The baseline run needs the same reasoning: a baseline that exits non-zero while parsing nothing is not "no
  pre-existing failures", it is a suite this tool cannot read. **Refuse to sweep**, naming the command, since
  every mutation afterwards would be unmeasurable.
- Say in the refusal *why* — the classifier is pytest-shaped — and point at `--cmd`. An operator on another
  runner needs to know the tool cannot score their suite, not merely that it declined.

**Out of scope:** teaching the classifier other runners' formats. That is a real feature and a separate
decision; this task makes the gap **loud** rather than silent.

## Bug handling (MANDATORY)

Any other bug found: **fix it in a separate commit** and describe it. If a fix looks risky, stop and describe
it rather than guessing.

## Tests

- **A failing-but-unparseable run is reported as not measured**, using a fixture repo whose test command
  emits a non-pytest failure format and exits non-zero. This is the regression; without it the fix is
  unpinned.
- **A passing run that parses nothing is still a survivor** — the pair is what proves the exit status is
  doing the work rather than a blanket suppression.
- The baseline refusal fires, names the command, and exits without sweeping.
- Exit status precedence is unchanged for every case that already worked; the existing suite stays green.
- Each test fails if the behaviour it names is removed; **report counts per behaviour**, measured.
- No test writes outside its temp dir.

## Conventions (inlined — the whole contract)

- **Never** commit with `--no-verify`. **Never** install any package or software without asking first.
- Commit **atomically**, in `git-scripts/` only. Stage **by explicit path**; never `git add -A`.
- End commit messages with: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- Bash, matching the existing header and usage-comment style; run `tests/test-git-mutate.sh`.
- Update `README.md` — the exit-status table documents what 2 and 3 mean, and 3 gains a case.

## Acceptance criteria (CO verifies)

1. A failing, unparseable run reports **not measured** (exit 3); a passing unparseable run still reports a
   survivor (exit 2). Both pinned.
2. The baseline refuses to sweep on an unreadable failing suite, naming the command and `--cmd`.
3. The refusal explains that the classifier is pytest-shaped.
4. Existing tests stay green; counts per behaviour reported and measured.
