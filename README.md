# git-scripts
Some useful `git-`scripts.

# git report

```
git report            # cache hit -> print it; miss -> run the gate (pre-commit), cache on success, print
git report --record   # attest only: write the entry for the current key, run nothing
```

A cached, dependency-aware report of whether a repo's `pre-commit` gate passes. The cache key covers this
repo and any repos it declares as dependencies, not just this repo's `HEAD` -- useful when repos are
installed/linked against each other so that a dependency's commit changes this repo's behaviour without
moving this repo's own `HEAD`.

**Dependency file:** a file named `.git-report-deps` at a repo's root, one relative repo path per line,
blank lines and lines starting with `#` ignored. No file means no dependencies.

**The key:** for each repo in `[dependencies..., self]`, hash `git diff HEAD` plus `git status --porcelain`
(so a dirty repo is keyed by its actual diff content, not a boolean flag -- two different uncommitted states
never collide, and a clean repo always collapses to the same canonical hash) alongside its `HEAD`. All of
that, plus a hash of `git-report` itself, is hashed together into the final key. Both modes compute this
identically.

**`--record`** writes a synthesized attestation (`gate passed at <hash>, recorded at commit time`) instead
of running the gate -- meant to be called right after a commit succeeds, when the commit succeeding is
already proof the gate passed. It refuses on a dirty own tree, same as the default mode: `pre-commit`
validates only the staged state, so unstaged changes surviving the commit mean the tree isn't what was
validated.

**Wiring `--record` into a commit:** add a hook to `.pre-commit-config.yaml` with `stages: [post-commit]`,
`always_run: true`, `pass_filenames: false`, and `entry: git report --record`, then run `pre-commit install
--hook-type post-commit` once per repo. A hook with no explicit `stages:` runs at *every* installed hook
type by default -- so once `post-commit` is installed, every other hook lacking its own `stages:` will also
fire again after each commit unless the config sets `default_stages: [pre-commit]` at the top level. Add
that line before adding a post-commit hook to an existing config, or the whole gate silently re-runs after
every commit.

Run `tests/test-git-report.sh` to exercise the cache/key logic against throwaway repos.

# Other resources

* https://github.com/fanquake/core-review
