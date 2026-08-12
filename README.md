# git-scripts
Some useful `git-`scripts.

# git report

```
git report            # cache hit -> print it; miss -> run the gate (pre-commit), cache on success, print
git report --record   # attest only: write the entry for the current key, run nothing
git report --capture [--] <cmd> [args...]
                      # run <cmd> transparently, leaving its output for --record to fold in
```

A cached, dependency-aware report of whether a repo's `pre-commit` gate passes. The cache key covers this
repo and any repos it declares as dependencies, not just this repo's `HEAD` -- useful when repos are
installed/linked against each other so that a dependency's commit changes this repo's behaviour without
moving this repo's own `HEAD`.

**A cache hit says it is one**, on its first line, naming when the entry was produced and at which `HEAD`:

```
git-report: btw, this report is cached -- produced at 2026-08-12T16:14:02+09:00 for HEAD c9ce6a68..., and replayed because nothing in the key has changed since. Nothing was re-run.
```

*Above* the content, never below: a note under a wall of output is read after the reader has already
believed the numbers are fresh. It goes to stdout along with the report rather than to stderr, because
its position relative to the content is the whole point of it. Every entry therefore begins with a
`git-report-cache at=... head=...` header line, and the report is everything after that line -- a hit
prints the notice, then that body. Entries are written to a temp file in the cache directory and
renamed, so a reader hitting the same key mid-write sees either no entry or a whole one.

**Dependency file:** a file named `.git-report-deps` at a repo's root, one relative repo path per line,
blank lines and lines starting with `#` ignored. No file means no dependencies.

**The key:** for each repo in `[dependencies..., self]`, hash `git diff HEAD`, `git status --porcelain`, and
the *contents* of its untracked files (`git ls-files --others --exclude-standard`, so an ignored file is
still ignored) alongside its `HEAD`. A dirty repo is therefore keyed by its actual content, not by a boolean
flag: two different uncommitted states never collide, and a clean repo always collapses to the same
canonical hash. All of that, plus a hash of `git-report` itself, is hashed together into the final key. Both
modes compute this identically.

The untracked contents are load-bearing rather than thorough. `git diff HEAD` covers tracked changes only
and `status --porcelain` prints an untracked file's *name* but never a byte of it, so editing an untracked
module in a dependency used to leave the key unchanged and replay a report from before the edit. It costs
one read per untracked file in a dependency, and nothing for the repo being reported on: a dirty own tree,
untracked files included, is refused before the key is computed.

**`--record`** writes an attestation (`gate passed at <hash>, recorded at commit time`) instead of running
the gate -- meant to be called right after a commit succeeds, when the commit succeeding is already proof
the gate passed. It refuses on a dirty own tree, same as the default mode: `pre-commit` validates only the
staged state, so unstaged changes surviving the commit mean the tree isn't what was validated.

## `--capture`: making a recorded entry carry the gate's numbers

A recorded entry is the entry a worker meets most often -- they start on a clean tree at the recorded
`HEAD`, hit the cache, and get whatever is in it. An attestation alone gives them a colour where a number
was needed: a baseline is *"how many tests before I started"*, and its whole point is to catch a test
silently disappearing, which `Passed` cannot show. A worker once re-ran a full suite under `pytest` purely
to recover the `3196 passed` the gate had already computed and thrown away.

`--record` cannot see that number by itself: it runs as a *post-commit* hook, so its sibling hooks' output
is long gone. So the gate's own test hook hands it over. **The per-repo change is one line** -- prefix the
existing entry, and change nothing else about the hook:

```yaml
      - id: pytest-cov-floor
        name: pytest -m "not slow" + coverage floor
        entry: git report --capture -- pytest -m "not slow" --cov=src/terea --cov-fail-under=63
```

`--capture` runs the command, passes its stdout through untouched, exits with the command's own status, and
leaves a copy at `.git/info/git-report/pending`. `--record` folds that copy into the entry it writes, under
the attestation line, so every cache hit afterwards carries the suite's numbers. Nothing else in the hook
changes, and the same one line is the whole change in every repo. Also add `verbose: true` to that hook if
it isn't there already, for the *un*cached path: `pre-commit` discards a passing hook's stdout, so without
it a fresh `git report` prints `Passed` and throws the same number away.

**A capture is stamped with the tree it ran against** (`git write-tree` at pre-commit time is exactly the
tree the new commit will carry, since `pre-commit` stashes everything unstaged), and `--record` uses it only
if the stamp matches the commit it is attesting. This is load-bearing rather than belt-and-braces: a hook
with `types_or: [python]` is *skipped* on a docs-only commit, so without the stamp such a commit would
inherit an earlier commit's numbers as if they were its own. The copy is deleted once read, matched or not.

**When no capture matches, the entry says so** and names the one-line remedy, rather than leaving the
reader to wonder whether the gate had nothing to say:

```
gate passed at c9ce6a68..., recorded at commit time

this entry carries no gate output: no run was captured for this commit tree.
Either this repo's test hook is not wired for capture (see README.md), or it
was skipped because the commit touched no files it selects. For a report with
numbers now:
    rm '/path/to/.git/info/git-report/<key>' && git report
```

That is also what an unwired repo gets: the honest sentence, never a number belonging to something else.

**`--capture` never refuses and never fails a commit.** Every step of setting the capture up may fail into
a plain `exec "$@"`, which leaves nothing at all between the caller and the command. Two details are
deliberate rather than incidental: only stdout is teed (merging `stderr` would reorder the command's two
streams and drag unrelated noise into the entry), and it is a foreground pipeline rather than a process
substitution around an `exec`, because procsub leaves the copy being written by a process nobody waits for
-- so output can surface *after* the wrapper exits and a caller reading its log the moment the wrapper
returns can read a truncated one. `git mutate` is exactly such a caller. During a sweep `--capture` writes
nothing and `exec`s, since a mutated run's output is not a report of this tree.

**Wiring `--record` into a commit:** add a hook to `.pre-commit-config.yaml` with `stages: [post-commit]`,
`always_run: true`, `pass_filenames: false`, and `entry: git report --record`, then run `pre-commit install
--hook-type post-commit` once per repo. A hook with no explicit `stages:` runs at *every* installed hook
type by default -- so once `post-commit` is installed, every other hook lacking its own `stages:` will also
fire again after each commit unless the config sets `default_stages: [pre-commit]` at the top level. Add
that line before adding a post-commit hook to an existing config, or the whole gate silently re-runs after
every commit.

Run `tests/test-git-report.sh` to exercise the cache/key logic against throwaway repos.

When `git report` refuses on a dirty tree it also says whether a `git mutate` sweep is in flight, since a
sweep dirties the tree on purpose while a mutation is applied.

# git mutate

```
git mutate <mutations-file> [name...]   # run every mutation, or only the named ones
git mutate --check <mutations-file>     # guards only: mutate nothing, run no tests
git mutate --recover                    # restore from a stale sweep's snapshot; cmp-verify
  --cmd <shell command>   test command, instead of the pytest hook in .pre-commit-config.yaml
  --timeout <seconds>     per-mutation timeout (default 900)
```

**Run it unpiped.** A sweep is slow — one full test run per mutation, plus a baseline — and it prints one
line per mutation as that mutation finishes, so an unpiped run is a live progress report. Filtering it
through `grep`/`head` buys nothing: the sweep is not spammy (three header lines, one line per mutation, then
the report). It costs the progress, because the filter blocks until the sweep ends — a run that is stuck,
timing out, or refusing every anchor then looks exactly like one that is working. `head` is worse: it can
SIGPIPE the sweep mid-mutation, which is the one way to leave a tree needing `--recover`.

Runs a mutation sweep: for each mutation, guard it, snapshot the files it touches, apply it, run the test
suite, restore the tree, and report **which tests reddened and whether they reddened by an assertion or by
an error**. The point of the tool is that last distinction: an assertion kill means a test checks the
behaviour, an error kill means the mutation merely broke the code and proves nothing about the tests.

**The mutations file** is TOML, so anchors are literal multi-line strings needing no escaping:

```toml
[[mutation]]
name = "anchor-never-sent"
[[mutation.edit]]
file = "src/autorp/claims.py"
old = '''        "history": _history_anchor(played),'''
new = '''        "history": [],'''
```

A mutation is a *list* of edits, so a two-part mutation (add something here, drain it there) stays
declarative instead of needing special-casing in the tool. Note TOML's rule that a newline immediately
after the opening `'''` is dropped, which is what lets a multi-line anchor start on its own line.

## Nothing persistent -- and why a committed mutations file is not offered

**The tool is stateless.** Mutations are passed in for one invocation and forgotten. The file is scratch: it
belongs in `.gitignore`, never in a commit.

The tempting design is a `mutations.toml` checked into each repo and re-run as a suite. It is not offered,
because anchors are coupled to the code's current *text* while tests are coupled to its *behaviour*, so the
two decay apart. Measured on rp-stack's own campaign: of 8 load-bearing mutations from tasks two weeks old,
**5 no longer matched anything**. Worse than decay, one surviving anchor (`max_tokens=1`) had come to match
**only a docstring** -- prose describing behaviour that had since been removed. A persistent mutation would
have passed its own uniqueness guard, mutated a comment, reddened nothing, and reported *"this behaviour has
no killing mutation"*: a false alarm indistinguishable from a real finding. A stale mutation file is worse
than no mutation file.

## What it refuses, and why each guard exists

`count == 1` alone is not enough, so there are four guards. Every one of them refuses that mutation loudly,
names the offending edit, and lets the rest of the sweep run.

* **Each edit's `old` must occur exactly once** in its file -- *every* edit, with no privileged first one.
  Edits are applied to an in-memory buffer in declaration order and each is counted against the buffer as
  it will actually be patched, so a later edit whose anchor became ambiguous is caught as well. A
  `replace(old, new, 1)` caps the substitutions but never asserts there was one to make; it will silently
  patch whichever occurrence comes first and report a confident result about the wrong line.
* **`new` must differ from `old`** -- otherwise it is a no-op by construction.
* **After applying, the content must actually differ from the tree.** This is the backstop that catches what
  the other two do not, including two edits that cancel out. A mutation that leaves the tree byte-identical
  and reports "reddened nothing" is the worst output this tool can produce, being indistinguishable from a
  real finding.
* **An anchor sitting in a comment or docstring is refused.** The heuristic is crude and stated: a `#`
  earlier on the match's own line, an anchor that is itself a `#` comment, or an odd number of `"""`/`'''`
  before the match. It catches the `max_tokens=1` case above. It misses `//` and `/* */`, and it can
  false-positive on a file whose triple quotes are unbalanced by a raw string -- in which case pick a
  different anchor, which costs one line of a scratch file.

## Classifying a kill

Read from pytest's `--tb=line` summary, one line per failure, and beware two traps that were both measured.

**Strip ANSI first.** With `FORCE_COLOR` set, the line really begins `\x1b[31mFAILED`, and escape codes sit
*inside* the test id too, so stripping must come before the id is extracted. CO and a worker once ran the
same harness over the same mutations and got 0 red and 6 red purely from this. `git mutate` strips
`\x1b\[[0-9;]*m` from every line and also sets `NO_COLOR=1` for the child; the parse depends on neither.

**Do not classify on the string `AssertionError`.** pytest *rewrites* assertions, so a genuine assertion
failure usually carries no exception name at all:

```
FAILED ...::test_the_walk_interleaves  - assert [244, 331, 721] == [244, 331, 434]
FAILED ...::test_the_anchor_is_ordered - AssertionError: render must greet by name
FAILED ...::test_it_refuses            - Failed: DID NOT RAISE <class 'ValueError'>
ERROR  tests/test_claims.py            - NameError: name 'undefined_label' is not defined
```

The first three are assertion kills; only the last is an error kill. The rule: on the text after `" - "`, a
leading `assert`, `AssertionError:` or pytest's own `Failed:` is an **assertion** kill; a named exception is
an **error** kill; an `ERROR` line is always an error kill, since a collection failure means the tests never
ran. Anything else is reported as **unclassifiable** rather than being folded silently into either bucket.
Blind spots: a helper that raises its own exception type to signal a failed expectation reads as an error
kill, and an assertion message beginning with something exception-shaped reads as an assertion kill. Both
are visible in the reported message text.

Four things are set for the child, all load-bearing:

| | why |
|---|---|
| `-p no:randomly` | test order must be identical across mutations or the reddened sets are not comparable; harmless where the plugin is absent |
| `--tb=line` | makes the summary line -- the classification substrate -- exist |
| `-rfE` | pytest's default already includes these report chars; saying it out loud means a repo's own `-r` cannot take the summary away |
| `COLUMNS=1000` | pytest truncates each summary line to the terminal width, and a pipe means 80 columns: a test with a long id loses its failure text entirely, leaving a line nothing can classify |

## The test command

Default: the repo's own gate, found the way `git report` finds it -- the single pytest hook in
`.pre-commit-config.yaml`. Zero or several candidates and the tool refuses rather than guessing, and asks
for `--cmd`.

**The tension.** A narrow test subset is fast but can miss a mutation reddening something outside it, while
running the whole `pre-commit` gate is slow and, worse, not measurable: `ruff` or `basedpyright` failing
reddens the gate while reddening no test, which would print as *"reddened nothing"* -- a broken measurement
wearing a finding's clothes. The resolution is to run the gate's *own* pytest hook with the gate's own
selection (`-m "not slow"` and the like, so nothing is narrowed by this tool), minus `--cov*` (a coverage
floor failing is not a test reddening, and coverage would be paid once per mutation for nothing), plus the
four settings above.

**A baseline run comes first.** If the unmutated suite errors, the sweep refuses: nothing is measurable when
the suite does not even import, since every mutation would look like a kill. If the unmutated suite merely
has failing tests, they are named loudly and excluded from every mutation's kills -- a test already red
cannot be a kill. And if the unmutated suite exits non-zero while matching no line the classifier
recognises at all, the sweep refuses too, naming the command and pointing at `--cmd`: that is not "no
pre-existing failures", it is a suite this pytest-shaped classifier cannot read, and every mutation
afterwards would be unmeasurable.

## The tree, and saying so

The snapshot is taken **by the tool, immediately before it mutates, from the tree it is about to change.** A
snapshot populated earlier by something else would silently revert any legitimate edit made since: a
data-loss bug wearing a safety mechanism's clothing.

Restore happens on every exit path -- normal, non-zero, timeout, `^C`, `SIGTERM` -- and restores **every**
file snapshotted during the sweep, not only the ones the current mutation touched, so a mutation that died
mid-write is cleaned up too. Each restored file is verified with `cmp`. There is **no `git checkout`
anywhere**: the tree may hold uncommitted work, and a sweep must preserve it byte-for-byte.

While a mutation is applied the tree really is modified and the gate really is red, so a sweep announces
itself three ways: a lock directory at `.git/git-mutate.lock` (holding the pid, the snapshot and its
manifest), a banner on stderr, and an untracked `MUTATION-SWEEP-IN-PROGRESS` marker at the repo root.
**Do not gitignore that marker** -- its whole job is to be glaring in `git status`, so that anything
sampling the repo mid-sweep sees a measurement in flight instead of concluding a mutation was left behind.
A second concurrent sweep in the same repo refuses rather than interleaving.

A sweep killed with `SIGKILL` cannot restore itself; nothing else leaves a mutated tree. The next sweep
detects the stale lock and refuses, naming the files that may still be mutated and pointing at
`git mutate --recover`, which restores them from that snapshot and `cmp`-verifies. Recovery is never
automatic, for the same reason the snapshot is never inherited.

## Reporting and exit status

One line per mutation, then findings first: a mutation that reddened nothing, then one reddened only by
error, then anything not measured, then the kills, each with the specific test names. **No percentage and no
score:** *"killed 9/10"* invites chasing a number, while *"this mutation reddened nothing"* and *"this
mutation reddened 3, all by NameError"* invite thought.

| exit | meaning |
|---|---|
| 0 | every selected mutation was measured and killed by at least one assertion |
| 1 | usage or environment error -- nothing was measured |
| 2 | **findings**: a mutation reddened nothing, or was reddened only by errors |
| 3 | **not measured**: a mutation was refused, timed out, produced an unclassifiable line, or failed while matching nothing the classifier recognises at all |
| 4 | restore verification failed -- the tree may still be mutated |
| 130 | interrupted; the tree was restored |

Precedence when several apply is 4 > 3 > 2. A survivor is a *finding*, never a tool failure: conflating the
two would make the tool useless in a pipeline.

**Why python3 appears in a bash script:** two operations must not be mis-escaped -- parsing literal
multi-line anchors, and counting and replacing a literal multi-line substring -- and `sed`/`grep` cannot do
either without quoting the anchor, which is exactly how a previous harness came to print `ANCHOR 0x --
skipped` for every mutation. Those two, plus the summary-line regex, are embedded `python3` heredocs using
only the standard library (`tomllib`, so python 3.11+); orchestration, locking, snapshot/restore and
reporting are bash. Run `tests/test-git-mutate.sh` to exercise all of it against throwaway repos.

# Other resources

* https://github.com/fanquake/core-review
