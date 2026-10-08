#!/bin/bash
#
# Copyright (c) 2026 Karl-Johan Alm
# Distributed under the MIT software license, see the accompanying
# file LICENSE or http://www.opensource.org/licenses/mit-license.php.
#
# Test suite for git-mutate. Builds throwaway repos under a temp dir with a trivial fake
# suite; touches nothing outside that temp dir, and needs no network and no LLM. Each test
# names the behaviour it pins -- see the final summary for the full mapping.
#
# The fixture suite carries all four shapes a pytest failure takes, because the tool's
# reason to exist is telling an assertion kill from an error kill and a classifier that
# only knows "AssertionError:" passes a one-shape test and is wrong in production.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${GIT_MUTATE_BIN:-$HERE/../git-mutate}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0
OUT=""
ST=0

ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  ok: $1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $1"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        ok "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

assert_status() { assert_eq "$1" "$2" "$ST"; }

assert_contains() {
    local desc="$1" needle="$2"
    case "$OUT" in
        *"$needle"*) ok "$desc" ;;
        *) fail "$desc (output has no '$needle')" ;;
    esac
}

assert_missing() {
    local desc="$1" needle="$2"
    case "$OUT" in
        *"$needle"*) fail "$desc (output unexpectedly has '$needle')" ;;
        *) ok "$desc" ;;
    esac
}

assert_identical() {
    local desc="$1" a="$2" b="$3"
    if cmp -s "$a" "$b"; then ok "$desc"; else fail "$desc ('$a' and '$b' differ)"; fi
}

assert_no_sweep_state() {
    local repo="$1" desc="$2"
    if [ -e "$repo/.git/git-mutate.lock" ]; then
        fail "$desc (lock left behind)"
    elif [ -e "$repo/MUTATION-SWEEP-IN-PROGRESS" ]; then
        fail "$desc (marker left behind)"
    else
        ok "$desc"
    fi
}

assert_clean_tree() {
    local repo="$1" desc="$2" dirty
    dirty=$(git -C "$repo" status --porcelain)
    if [ -z "$dirty" ]; then ok "$desc"; else fail "$desc (tree is dirty: $dirty)"; fi
}

# Runs git-mutate inside a repo, capturing both streams and the exit status.
mutate() {
    local repo="$1"; shift
    OUT=$( (cd "$repo" && "$SCRIPT" "$@") 2>&1 )
    ST=$?
}

# As mutate(), with the named file connected to the tool's standard input.
mutate_stdin() {
    local repo="$1" input="$2"; shift 2
    OUT=$( (cd "$repo" && "$SCRIPT" "$@" < "$input") 2>&1 )
    ST=$?
}

init_repo() {
    local repo="$1"
    git init -q "$repo"
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name test
}

commit_all() {
    local repo="$1" msg="$2"
    (cd "$repo" && git add -A && git commit -q -m "$msg")
}

HAVE_PYTEST=1
command -v pytest >/dev/null 2>&1 || HAVE_PYTEST=0

need_pytest() {
    [ "$HAVE_PYTEST" -eq 1 ] && return 0
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    echo "  SKIP: pytest is not on PATH, so this test cannot run its fake suite"
    return 1
}

# --- the fixture -------------------------------------------------------------------------
#
# A repo whose fake suite fails in all four shapes pytest produces:
#   test_walk_returns_the_steps    a rewritten bare `assert x == y`  ->  "assert [...] == [...]"
#   test_render_greets_by_name     an assert with a message          ->  "AssertionError: ..."
#   test_parse_refuses_non_numbers pytest.raises not raising         ->  "Failed: DID NOT RAISE ..."
#   test_label_is_plain            reachable only via a NameError    ->  "NameError: ..."
# The first three are assertion kills, the last is an error kill.
make_fixture() {
    local repo="$1"
    init_repo "$repo"
    mkdir -p "$repo/tests"

    cat > "$repo/.gitignore" <<'EOF'
__pycache__/
.pytest_cache/
EOF

    # An empty conftest.py at the root is what puts the root on sys.path for the suite.
    : > "$repo/conftest.py"

    cat > "$repo/helper.py" <<'EOF'
def prefix():
    return ">> "
EOF

    cat > "$repo/mod.py" <<'EOF'
"""Fake module under mutation.

Prose that a decayed anchor could still match, the way a stale max_tokens=1 anchor came
to match only a docstring: mutating it would redden nothing and read exactly like a real
finding.
"""

from helper import prefix


def walk():
    steps = [244, 331, 721]
    return steps


def render(name):
    return "hello " + name


def parse(text):
    if not text.isdigit():
        raise ValueError("not a number")
    return int(text)


def label():
    # comment bait: bait_in_comment sits in a comment, not in code
    return "plain"


def banner(name):
    return prefix() + name


def unchecked(n):
    return n * 2


def twin_a():
    value = 7
    return value


def twin_b():
    value = 7
    return value
EOF

    cat > "$repo/tests/test_mod.py" <<'EOF'
import pytest

from mod import banner, label, parse, render, walk


def test_walk_returns_the_steps():
    assert walk() == [244, 331, 721]


def test_render_greets_by_name():
    assert render("bo") == "hello bo", "render must greet by name"


def test_parse_refuses_non_numbers():
    with pytest.raises(ValueError):
        parse("nope")


def test_parse_reads_numbers():
    assert parse("12") == 12


def test_label_is_plain():
    assert label() == "plain"


def test_banner_uses_the_prefix():
    assert banner("x") == ">> x"
EOF

    commit_all "$repo" "fixture"
}

# The three mutations the fixture is built around: one killed by assertions in all three
# assertion shapes, one killed only by an error, one no test distinguishes at all.
write_main_mutations() {
    cat > "$1" <<'EOF'
[[mutation]]
name = "assert-shapes"
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [244, 331, 434]'''
[[mutation.edit]]
file = "mod.py"
old = '''    return "hello " + name'''
new = '''    return "hello"'''
[[mutation.edit]]
file = "mod.py"
old = '''        raise ValueError("not a number")'''
new = '''        return 0'''

[[mutation]]
name = "error-only"
[[mutation.edit]]
file = "mod.py"
old = '''    return "plain"'''
new = '''    return undefined_label'''

[[mutation]]
name = "unchecked-doubling"
[[mutation.edit]]
file = "mod.py"
old = '''    return n * 2'''
new = '''    return n * 3'''
EOF
}

# A test command that is instant on the unmutated tree and hangs once the mutation is
# applied -- the baseline run must not be the slow one, or a --timeout test would only ever
# pin the baseline timing out.
write_slow_runner() {
    cat > "$1" <<'EOF'
#!/bin/bash
grep -q 'SLOW_MARKER' mod.py && sleep 60
exit 0
EOF
    chmod +x "$1"
}

write_slow_mutation() {
    cat > "$1" <<'EOF'
[[mutation]]
name = "slow-one"
[[mutation.edit]]
file = "mod.py"
old = '''    return n * 2'''
new = '''    return n * 2  # SLOW_MARKER'''
EOF
}

# Waits for a backgrounded sweep to have a mutation applied and in flight.
wait_for_mutation() {
    local repo="$1" needle="$2" i
    for i in $(seq 1 200); do
        grep -q "$needle" "$repo/mod.py" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

# Starts a sweep in the background with SIGINT deliverable, and sets SWEEP_PID. Two traps
# live here:
#   - A shell sets SIGINT to SIG_IGN for the children it starts asynchronously, and a signal
#     ignored on entry cannot be trapped -- so a plain `git-mutate & kill -INT` would test
#     nothing at all. Resetting the disposition before exec is what makes the ^C path real.
#   - The pid is returned in a global rather than through $(...): a command substitution runs
#     in a subshell, the sweep would be that subshell's child, and `wait` in the test would
#     answer 127 for a process it does not own while the sweep ran on unsupervised.
SWEEP_PID=""
start_interruptible_sweep() {
    local repo="$1" log="$2"; shift 2
    ( cd "$repo" && exec python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$SCRIPT" "$@" ) > "$log" 2>&1 &
    SWEEP_PID=$!
}

# --- test 1: the four failure shapes are classified, error-only proves nothing ------------

test1() {
    echo "test 1: assertion kills and error kills are classified apart, in all four shapes"
    need_pytest || return 0
    local d="$WORK/t1" repo="$WORK/t1/repo"
    mkdir -p "$d"
    make_fixture "$repo"
    write_main_mutations "$d/mutations.toml"

    mutate "$repo" --cmd pytest "$d/mutations.toml"

    assert_contains "a bare rewritten assert is an assertion kill" \
        "assertion tests/test_mod.py::test_walk_returns_the_steps -- assert"
    assert_contains "an AssertionError: failure is an assertion kill" \
        "assertion tests/test_mod.py::test_render_greets_by_name -- AssertionError:"
    assert_contains "a 'Failed: DID NOT RAISE' failure is an assertion kill" \
        "assertion tests/test_mod.py::test_parse_refuses_non_numbers -- Failed: DID NOT RAISE"
    assert_contains "the three-shape mutation reports 3 assertion and 0 error kills" \
        "assert-shapes: reddened 3 -- 3 by assertion, 0 by error."
    assert_contains "a NameError failure is an error kill" \
        "error     tests/test_mod.py::test_label_is_plain -- NameError:"
    assert_contains "an error-only kill is reported as proving nothing" \
        "error-only: reddened 1, ALL BY ERROR -- proves nothing."
    assert_missing "an error-only kill is not counted as an assertion kill" \
        "error-only: reddened 1 -- 1 by assertion"
    assert_clean_tree "$repo" "the tree is clean after the sweep"
    assert_no_sweep_state "$repo" "no lock or marker survives the sweep"
}

# --- test 2: classification survives colorized output ------------------------------------

test2() {
    echo "test 2: parsing survives colorized output (ANSI codes sit inside the test id)"
    need_pytest || return 0
    local d="$WORK/t2" repo="$WORK/t2/repo" plain colored
    mkdir -p "$d"
    make_fixture "$repo"
    write_main_mutations "$d/mutations.toml"

    # --color=yes beats the NO_COLOR git-mutate sets for the child, so this really does
    # feed ANSI escapes through the parser.
    cat > "$d/color_runner.sh" <<'EOF'
#!/bin/bash
exec pytest -p no:randomly --tb=line -rfE --color=yes
EOF
    chmod +x "$d/color_runner.sh"

    mutate "$repo" --cmd pytest "$d/mutations.toml"
    plain=$(printf '%s\n' "$OUT" | grep -E '^\[[0-9]+/')
    mutate "$repo" --cmd "$d/color_runner.sh" "$d/mutations.toml"
    colored=$(printf '%s\n' "$OUT" | grep -E '^\[[0-9]+/')

    assert_eq "colorized and uncolored runs classify identically" "$plain" "$colored"
    assert_contains "the colorized run really did find the assertion kills" \
        "reddened 3: 3 by assertion, 0 by error"
}

# --- test 3: every refusal, on every edit, with the rest of the sweep still running -------

test3() {
    echo "test 3: bad anchors, no-op mutations and prose anchors are refused, loudly"
    need_pytest || return 0
    local d="$WORK/t3" repo="$WORK/t3/repo"
    mkdir -p "$d"
    make_fixture "$repo"
    cp "$repo/mod.py" "$d/mod.before"
    # A TOML preset: the triple-quoted block here is a VALUE -- the artifact under test --
    # not commentary about code, which is why the same syntax gets the opposite verdict.
    cat > "$repo/preset.toml" <<'TOMLEOF'
version = 1
instruction = """You are enacting a scene.
- Their words are theirs: never write for them.
"""
TOMLEOF
    commit_all "$repo" "add a preset"

    cat > "$d/refusals.toml" <<'EOF'
[[mutation]]
name = "anchor-missing"
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [1, 2, 3]'''
new = '''    steps = [9, 9, 9]'''

[[mutation]]
name = "anchor-ambiguous"
[[mutation.edit]]
file = "mod.py"
old = '''    value = 7'''
new = '''    value = 8'''

[[mutation]]
name = "late-edit-ambiguous"
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [244, 331, 434]'''
[[mutation.edit]]
file = "mod.py"
old = '''    value = 7'''
new = '''    value = 8'''

[[mutation]]
name = "noop-same"
[[mutation.edit]]
file = "mod.py"
old = '''    return n * 2'''
new = '''    return n * 2'''

[[mutation]]
name = "cancel-out"
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [244, 331, 434]'''
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 434]'''
new = '''    steps = [244, 331, 721]'''

[[mutation]]
name = "comment-anchor"
[[mutation.edit]]
file = "mod.py"
old = '''bait_in_comment'''
new = '''bait_mutated'''

[[mutation]]
name = "docstring-anchor"
[[mutation.edit]]
file = "mod.py"
old = '''max_tokens=1'''
new = '''max_tokens=2'''

[[mutation]]
name = "toml-value-anchor"
[[mutation.edit]]
file = "preset.toml"
old = '''never write for them'''
new = '''write for them freely'''

[[mutation]]
name = "still-runs"
[[mutation.edit]]
file = "mod.py"
old = '''    return "hello " + name'''
new = '''    return "hello"'''
EOF

    mutate "$repo" --cmd pytest "$d/refusals.toml"

    assert_contains "an anchor matching nothing is refused, naming the count" \
        "anchor-missing: REFUSED -- edit 1/1: anchor occurs 0x in 'mod.py'"
    assert_contains "an anchor matching twice is refused, naming the count" \
        "anchor-ambiguous: REFUSED -- edit 1/1: anchor occurs 2x in 'mod.py'"
    assert_contains "a LATER edit's ambiguous anchor is refused too, naming which edit" \
        "late-edit-ambiguous: REFUSED -- edit 2/2: anchor occurs 2x in 'mod.py'"
    assert_contains "a 'new' identical to 'old' is refused" \
        "noop-same: REFUSED -- edit 1/1: 'new' is identical to 'old'"
    assert_contains "edits that cancel out are refused by the byte-identical backstop" \
        "cancel-out: REFUSED -- every edit applied, yet the file content is byte-identical"
    assert_contains "an anchor in a '#' comment is caught" \
        "comment-anchor: REFUSED -- edit 1/1: the anchor sits after a '#' on its line"
    assert_contains "an anchor in a docstring is caught, naming file and line" \
        "docstring-anchor: REFUSED -- edit 1/1: the anchor sits inside a triple-quoted block (docstring or string literal) (mod.py:3)"
    # The pair is the point: identical syntax, opposite verdict. TOML has triple-quoted
    # strings too, but there the block is a VALUE -- for a prompt preset it is the artifact
    # under test -- so refusing it leaves a real behaviour unmeasured.
    assert_missing "the same syntax in a TOML value is NOT refused -- there it is the artifact" \
        "toml-value-anchor: REFUSED"
    assert_contains "a refused mutation does not stop the rest of the sweep" \
        "still-runs: reddened 1 -- 1 by assertion, 0 by error."
    assert_contains "refusals are surfaced as an incomplete measurement, not as survivors" \
        "== NOT MEASURED -- the sweep is incomplete here =="
    assert_status "refusals exit 3 (not measured), not 0 and not 2" 3
    assert_identical "a refused mutation leaves the file untouched" "$d/mod.before" "$repo/mod.py"
    assert_clean_tree "$repo" "the tree is clean after a sweep full of refusals"
}

# --- test 4: a mutation reddening nothing is surfaced first -------------------------------

test4() {
    echo "test 4: a mutation that reddens nothing is reported prominently, above the kills"
    need_pytest || return 0
    local d="$WORK/t4" repo="$WORK/t4/repo" findings_at killed_at survivor_at
    mkdir -p "$d"
    make_fixture "$repo"
    write_main_mutations "$d/mutations.toml"

    mutate "$repo" --cmd pytest "$d/mutations.toml"

    assert_contains "a survivor says so in plain words" "unchecked-doubling: reddened nothing."
    assert_missing "the report carries no score or percentage" "Killed "
    assert_missing "the report carries no ratio" "/3 killed"

    findings_at=$(printf '%s\n' "$OUT" | grep -n '== FINDINGS' | cut -d: -f1)
    survivor_at=$(printf '%s\n' "$OUT" | grep -n 'unchecked-doubling: reddened nothing' | cut -d: -f1)
    killed_at=$(printf '%s\n' "$OUT" | grep -n '== KILLED BY ASSERTION' | cut -d: -f1)
    if [ -n "$findings_at" ] && [ -n "$killed_at" ] && [ "$findings_at" -lt "$killed_at" ]; then
        ok "findings are printed before the kills"
    else
        fail "findings are printed before the kills (findings at '$findings_at', kills at '$killed_at')"
    fi
    if [ -n "$survivor_at" ] && [ -n "$killed_at" ] && [ "$survivor_at" -lt "$killed_at" ]; then
        ok "the survivor itself is above the kills"
    else
        fail "the survivor itself is above the kills (survivor at '$survivor_at')"
    fi
    assert_status "a survivor is a finding (exit 2), not a tool failure" 2
}

# --- test 5: a multi-edit mutation across two files applies and restores all of them ------

test5() {
    echo "test 5: a multi-file mutation applies every edit and restores every touched file"
    local d="$WORK/t5" repo="$WORK/t5/repo"
    mkdir -p "$d"
    make_fixture "$repo"
    cp "$repo/mod.py" "$d/mod.before"
    cp "$repo/helper.py" "$d/helper.before"

    cat > "$d/twofile.toml" <<'EOF'
[[mutation]]
name = "two-files"
[[mutation.edit]]
file = "helper.py"
old = '''    return ">> "'''
new = '''    return "!! "'''
[[mutation.edit]]
file = "mod.py"
old = '''    return prefix() + name'''
new = '''    return prefix() + name.upper()'''
EOF

    # The test command is the probe: it samples the tree from inside the mutated window.
    cat > "$d/probe.sh" <<EOF
#!/bin/bash
cp mod.py "$d/probe.mod"
cp helper.py "$d/probe.helper"
git status --porcelain > "$d/probe.status"
exit 0
EOF
    chmod +x "$d/probe.sh"

    mutate "$repo" --cmd "$d/probe.sh" "$d/twofile.toml"

    if grep -q 'name.upper()' "$d/probe.mod"; then
        ok "the first file's edit was applied while the command ran"
    else
        fail "the first file's edit was applied while the command ran"
    fi
    if grep -q '"!! "' "$d/probe.helper"; then
        ok "the second file's edit was applied while the command ran"
    else
        fail "the second file's edit was applied while the command ran"
    fi
    assert_identical "mod.py is restored byte-identical" "$d/mod.before" "$repo/mod.py"
    assert_identical "helper.py is restored byte-identical" "$d/helper.before" "$repo/helper.py"
    assert_clean_tree "$repo" "no touched file is left modified"
}

# --- test 6: the marker makes the transient dirtiness visible ----------------------------

test6() {
    echo "test 6: while a mutation is applied, the marker and the dirty file are both visible"
    local d="$WORK/t6" repo="$WORK/t6/repo"
    mkdir -p "$d"
    make_fixture "$repo"
    write_slow_mutation "$d/slow.toml"

    cat > "$d/probe.sh" <<EOF
#!/bin/bash
git status --porcelain > "$d/probe.status"
exit 0
EOF
    chmod +x "$d/probe.sh"

    mutate "$repo" --cmd "$d/probe.sh" "$d/slow.toml"

    if grep -q '^?? MUTATION-SWEEP-IN-PROGRESS$' "$d/probe.status"; then
        ok "anything sampling the repo mid-sweep sees the marker in git status"
    else
        fail "anything sampling the repo mid-sweep sees the marker in git status (saw: $(cat "$d/probe.status"))"
    fi
    if grep -q '^ M mod.py$' "$d/probe.status"; then
        ok "the mutated file really is modified in that window"
    else
        fail "the mutated file really is modified in that window"
    fi
    assert_no_sweep_state "$repo" "the marker is gone once the sweep ends"
    assert_clean_tree "$repo" "the tree is clean once the sweep ends"
}

# --- test 7: restore on a failing command, on a timeout, and on ^C ------------------------

test7() {
    echo "test 7: the tree is restored and cmp-verified on every exit path"
    local d="$WORK/t7" repo="$WORK/t7/repo"
    mkdir -p "$d"
    make_fixture "$repo"
    write_slow_mutation "$d/slow.toml"
    write_slow_runner "$d/slow_runner.sh"
    cp "$repo/mod.py" "$d/mod.before"

    # (a) the test command exits non-zero
    mutate "$repo" --cmd 'exit 7' "$d/slow.toml"
    assert_identical "restored after a test command exiting non-zero" "$d/mod.before" "$repo/mod.py"
    assert_no_sweep_state "$repo" "no state left after a test command exiting non-zero"

    # (b) the test command hangs and is timed out
    mutate "$repo" --timeout 2 --cmd "$d/slow_runner.sh" "$d/slow.toml"
    assert_contains "a timeout is reported as not measured, never as 'reddened nothing'" \
        "slow-one: NOT MEASURED -- the test command timed out after 2s"
    assert_missing "a timeout is not reported as a survivor" "slow-one: reddened nothing"
    assert_status "a timeout exits 3 (not measured)" 3
    assert_identical "restored after a timeout" "$d/mod.before" "$repo/mod.py"
    assert_no_sweep_state "$repo" "no state left after a timeout"

    # (c) the sweep is interrupted while a mutation is applied -- the case that loses a tree
    start_interruptible_sweep "$repo" "$d/int.log" --cmd "$d/slow_runner.sh" "$d/slow.toml"
    if wait_for_mutation "$repo" SLOW_MARKER; then
        ok "the sweep really had the mutation applied when it was interrupted"
    else
        fail "the sweep really had the mutation applied when it was interrupted"
    fi
    kill -INT "$SWEEP_PID" 2>/dev/null
    wait "$SWEEP_PID"
    ST=$?
    OUT=$(cat "$d/int.log")
    assert_contains "an interrupt says it is restoring the tree" "INT received -- killing the test command and restoring the tree"
    assert_status "an interrupted sweep exits 130" 130
    assert_identical "restored after an interrupt" "$d/mod.before" "$repo/mod.py"
    assert_no_sweep_state "$repo" "no state left after an interrupt"
    assert_clean_tree "$repo" "the tree is clean after an interrupt"
}

# --- test 8: the snapshot is the tool's own, taken at mutation time -----------------------

test8() {
    echo "test 8: the snapshot is taken at mutation time, never read from a pre-existing one"
    local d="$WORK/t8" repo="$WORK/t8/repo"
    mkdir -p "$d"
    make_fixture "$repo"
    write_slow_mutation "$d/slow.toml"

    # Uncommitted work in the tree. A "restore" that reverted to HEAD, or to a snapshot
    # taken by something else earlier, would silently eat it.
    printf '\n\ndef wip_addition():\n    return "work in progress"\n' >> "$repo/mod.py"
    cp "$repo/mod.py" "$d/mod.wip"

    mutate "$repo" --cmd 'true' "$d/slow.toml"
    assert_identical "uncommitted work survives a sweep byte-identical" "$d/mod.wip" "$repo/mod.py"
    if [ -n "$(git -C "$repo" diff --name-only)" ]; then
        ok "the sweep restored the working tree, not HEAD (no git checkout)"
    else
        fail "the sweep restored the working tree, not HEAD (no git checkout)"
    fi

    # A stale snapshot left by a dead sweep must never be applied on its own.
    mkdir -p "$repo/.git/git-mutate.lock/snap"
    printf 'pid=999999\nstarted=long ago\nmutations=/nowhere\n' > "$repo/.git/git-mutate.lock/info"
    printf 'STALE SNAPSHOT CONTENT\n' > "$repo/.git/git-mutate.lock/snap/0001"
    printf '0001\tmod.py\n' > "$repo/.git/git-mutate.lock/manifest"

    mutate "$repo" --cmd 'true' "$d/slow.toml"
    assert_status "a stale sweep's state makes the next sweep refuse" 1
    assert_contains "the refusal names the files that may still be mutated" \
        "it had snapshotted these files, which may still be mutated:"
    assert_contains "the refusal points at --recover instead of acting" \
        "run 'git mutate --recover' to restore them"
    assert_identical "a stale snapshot is NOT applied behind the user's back" "$d/mod.wip" "$repo/mod.py"

    # --recover is the explicit, user-invoked path, and it does restore.
    mutate "$repo" --recover
    assert_status "--recover exits 0" 0
    assert_contains "--recover says what it restored" "restoring          mod.py"
    if grep -q 'STALE SNAPSHOT CONTENT' "$repo/mod.py"; then
        ok "--recover restores from the snapshot it was pointed at"
    else
        fail "--recover restores from the snapshot it was pointed at"
    fi
    assert_no_sweep_state "$repo" "--recover clears the lock and marker"
}

# --- test 9: a second concurrent sweep refuses -------------------------------------------

test9() {
    echo "test 9: a second concurrent sweep in the same repo refuses rather than interleaving"
    local d="$WORK/t9" repo="$WORK/t9/repo"
    mkdir -p "$d"
    make_fixture "$repo"
    write_slow_mutation "$d/slow.toml"
    write_slow_runner "$d/slow_runner.sh"
    cp "$repo/mod.py" "$d/mod.before"

    start_interruptible_sweep "$repo" "$d/first.log" --cmd "$d/slow_runner.sh" "$d/slow.toml"
    if ! wait_for_mutation "$repo" SLOW_MARKER; then
        fail "the first sweep reached its mutation (cannot test concurrency without it)"
        kill -INT "$SWEEP_PID" 2>/dev/null; wait "$SWEEP_PID" 2>/dev/null
        return 0
    fi

    mutate "$repo" --cmd 'true' "$d/slow.toml"
    assert_status "the second sweep refuses" 1
    assert_contains "the refusal says a sweep is already in flight" \
        "sweep is already in flight"
    assert_contains "the refusal explains why interleaving is not allowed" \
        "Refusing to interleave"
    if grep -q SLOW_MARKER "$repo/mod.py"; then
        ok "the second sweep left the first sweep's mutation alone"
    else
        fail "the second sweep left the first sweep's mutation alone"
    fi

    kill -INT "$SWEEP_PID" 2>/dev/null
    wait "$SWEEP_PID" 2>/dev/null
    assert_identical "the first sweep still restores its own mutation" "$d/mod.before" "$repo/mod.py"
    assert_no_sweep_state "$repo" "no state survives both sweeps"
}

# --- test 10: --check guards without mutating or testing ----------------------------------

test10() {
    echo "test 10: --check validates every guard, runs no tests and writes nothing"
    local d="$WORK/t10" repo="$WORK/t10/repo" counter
    mkdir -p "$d"
    make_fixture "$repo"
    write_main_mutations "$d/mutations.toml"
    counter="$d/ran"

    cat > "$d/counting_runner.sh" <<EOF
#!/bin/bash
echo RAN >> "$counter"
exit 0
EOF
    chmod +x "$d/counting_runner.sh"

    mutate "$repo" --check --cmd "$d/counting_runner.sh" "$d/mutations.toml"
    assert_status "--check on sound anchors exits 0" 0
    assert_contains "--check reports each mutation as ok" "ok       assert-shapes"
    assert_contains "--check states what it checked" "every anchor is unique, in code, and changes the file."
    if [ ! -f "$counter" ]; then ok "--check ran no test command"; else fail "--check ran no test command"; fi
    assert_clean_tree "$repo" "--check left the tree untouched"
    assert_no_sweep_state "$repo" "--check took no lock and wrote no marker"

    mutate_stdin "$repo" "$d/mutations.toml" --check - assert-shapes
    assert_status "--check accepts TOML on standard input" 0
    assert_contains "stdin input can still select mutations by name" \
        "git-mutate --check: 1 mutation(s) from -"

    mutate_stdin "$repo" "$d/mutations.toml" --cmd true - assert-shapes
    assert_status "a full sweep accepts TOML on standard input" 2
    assert_contains "the stdin mutation is measured" "assert-shapes: reddened nothing."
    assert_clean_tree "$repo" "the stdin sweep restores the tree"
    assert_no_sweep_state "$repo" "the stdin sweep leaves no lock or marker"

    cat > "$d/bad.toml" <<'EOF'
[[mutation]]
name = "gone-stale"
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [1, 2, 3]'''
new = '''    steps = [9, 9, 9]'''
EOF
    mutate "$repo" --check "$d/bad.toml"
    assert_status "--check exits 3 when a guard would refuse" 3
    assert_contains "--check names the refusal" "REFUSED  gone-stale  edit 1/1: anchor occurs 0x"
}

# --- test 11: the test command comes from the repo's own gate ------------------------------

test11() {
    echo "test 11: the default test command is the gate's own pytest hook, minus coverage"
    need_pytest || return 0
    local d="$WORK/t11" repo="$WORK/t11/repo"
    mkdir -p "$d"
    make_fixture "$repo"
    write_main_mutations "$d/mutations.toml"

    cat > "$repo/.pre-commit-config.yaml" <<'EOF'
default_stages: [pre-commit]
repos:
  - repo: local
    hooks:
      - id: ruff-check
        name: ruff check
        entry: ruff check --force-exclude
        language: system
      - id: pytest-cov-floor
        name: pytest + coverage floor
        entry: pytest -m "not slow" --cov=mod --cov-fail-under=100
        language: system
        pass_filenames: false
EOF
    commit_all "$repo" "add a gate"

    mutate "$repo" "$d/mutations.toml" unchecked-doubling
    assert_contains "the hook's own selection is kept, coverage dropped, flags added" \
        'test command (.pre-commit-config.yaml): pytest -m "not slow" -p no:randomly --tb=line -rfE'
    assert_missing "the coverage floor is not part of the mutation command" "--cov"

    # Two pytest hooks: guessing which one measures behaviour is not the tool's call.
    cat > "$repo/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: local
    hooks:
      - id: pytest-fast
        name: pytest (fast)
        entry: pytest tests/test_mod.py
        language: system
      - id: pytest-full
        name: pytest (full)
        entry: pytest -m "not slow"
        language: system
EOF
    mutate "$repo" "$d/mutations.toml" unchecked-doubling
    assert_status "two pytest hooks make the tool refuse rather than guess" 1
    assert_contains "the refusal lists the candidates and asks for --cmd" \
        "refusing to guess which one measures behaviour. Pass one with --cmd."
    assert_no_sweep_state "$repo" "a command-resolution failure leaves no lock or marker"
}

# --- test 12: the baseline decides what a kill can even mean -------------------------------

test12() {
    echo "test 12: tests already red before any mutation are excluded, and an erroring suite refuses"
    need_pytest || return 0
    local d="$WORK/t12" repo="$WORK/t12/repo"
    mkdir -p "$d"
    make_fixture "$repo"

    # Uncommitted work has left one test red. A mutation reddening only that test proves
    # nothing about the mutation.
    sed -i 's/    steps = \[244, 331, 721\]/    steps = [244, 331, 999]/' "$repo/mod.py"
    cat > "$d/base.toml" <<'EOF'
[[mutation]]
name = "hits-only-the-already-red-test"
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 999]'''
new = '''    steps = [1, 1, 1]'''
EOF

    mutate "$repo" --cmd pytest "$d/base.toml"
    assert_contains "an already-failing test is called out before the sweep" \
        "WARNING: 1 test(s) already fail before any mutation:"
    assert_contains "the warning names the already-red test" \
        "tests/test_mod.py::test_walk_returns_the_steps"
    assert_contains "a mutation reddening only an already-red test is a survivor, not a kill" \
        "hits-only-the-already-red-test: reddened nothing."
    assert_status "that survivor is a finding (exit 2)" 2
    git -C "$repo" checkout -- mod.py

    # A suite that does not even import cannot measure anything.
    sed -i 's/^from mod import/from mod import nonexistent_symbol, /' "$repo/tests/test_mod.py"
    write_main_mutations "$d/mutations.toml"
    mutate "$repo" --cmd pytest "$d/mutations.toml"
    assert_status "an erroring baseline refuses the sweep" 1
    assert_contains "the refusal says the unmutated suite is red with errors" \
        "the unmutated suite is red with errors:"
    assert_contains "the refusal explains why nothing is measurable" \
        "every mutation would look like a kill."
    assert_no_sweep_state "$repo" "a refused baseline leaves no lock or marker"
    git -C "$repo" checkout -- tests/test_mod.py
}

# --- the go-style fixture: a runner whose failures are real but not pytest-shaped --------
#
# `py_classify` only knows pytest's `FAILED`/`ERROR` summary lines. Any other runner's failure
# text -- Go's `--- FAIL: TestAdd` here -- matches nothing at all, so this fixture pins that a
# genuinely broken, genuinely failing suite is reported as "not measured", never as a survivor.
make_go_fixture() {
    local repo="$1"
    init_repo "$repo"

    cat > "$repo/.gitignore" <<'EOF'
__pycache__/
EOF

    cat > "$repo/mod.py" <<'EOF'
def add(a, b):
    return a + b


def unused():
    return 1
EOF

    # -B: no .pyc is ever written. Without it, a mutation two edits later can reuse a stale
    # cached bytecode from an earlier mutation whose source happened to match on mtime and
    # size (same-second writes, same-length text) -- a real trap, not hypothetical here, since
    # "return 1" and "return 2" are the same length.
    cat > "$repo/runner.sh" <<'EOF'
#!/bin/bash
python3 -B -c "import mod; assert mod.add(2, 3) == 5" \
    && { echo "--- PASS: TestAdd"; exit 0; } \
    || { echo "--- FAIL: TestAdd"; exit 1; }
EOF
    chmod +x "$repo/runner.sh"

    commit_all "$repo" "go-style fixture"
}

write_go_mutations() {
    cat > "$1" <<'EOF'
[[mutation]]
name = "break-add"
[[mutation.edit]]
file = "mod.py"
old = '''    return a + b'''
new = '''    return a - b'''

[[mutation]]
name = "touch-unused"
[[mutation.edit]]
file = "mod.py"
old = '''    return 1'''
new = '''    return 2'''
EOF
}

# --- test 14: a failing-but-unparseable run is not measured, never a survivor -------------

test14() {
    echo "test 14: a genuinely-failing, unparseable run is 'not measured', never 'reddened nothing'"
    local d="$WORK/t14" repo="$WORK/t14/repo"
    mkdir -p "$d"
    make_go_fixture "$repo"
    write_go_mutations "$d/mutations.toml"

    mutate "$repo" --cmd "$repo/runner.sh" "$d/mutations.toml"

    assert_contains "a mutation that genuinely breaks the code and fails is NOT MEASURED" \
        "break-add: NOT MEASURED --"
    assert_missing "it is never reported as a well-defended survivor" \
        "break-add: reddened nothing"
    assert_contains "the pin proves it -- a mutation the runner never exercises IS a survivor" \
        "touch-unused: reddened nothing."
    assert_status "unclassified beats a plain finding: exit 3, not 2" 3
    assert_contains "counts are reported per behaviour" \
        "0 killed by assertion, 1 finding(s), 1 not measured."
    assert_clean_tree "$repo" "the tree is clean after a run with an unclassifiable failure"
    assert_no_sweep_state "$repo" "no lock or marker survives a run with an unclassifiable failure"
}

# --- test 15: a baseline that fails unreadably refuses to sweep at all --------------------

test15() {
    echo "test 15: an unreadable failing baseline refuses to sweep, naming the command and --cmd"
    local d="$WORK/t15" repo="$WORK/t15/repo"
    mkdir -p "$d"
    make_go_fixture "$repo"
    # Break add() before any mutation runs: the unmutated tree already fails the runner's
    # check, in the same unparseable Go-style shape.
    sed -i 's/    return a + b/    return a - b/' "$repo/mod.py"
    commit_all "$repo" "pre-broken baseline"
    write_go_mutations "$d/mutations.toml"

    mutate "$repo" --cmd "$repo/runner.sh" "$d/mutations.toml"

    assert_status "an unreadable failing baseline refuses (exit 1), it does not sweep" 1
    assert_contains "the refusal names the command" "$repo/runner.sh"
    assert_contains "the refusal points at --cmd" "--cmd"
    assert_contains "the refusal explains the classifier is pytest-shaped" "pytest-shaped"
    assert_no_sweep_state "$repo" "a refused baseline leaves no lock or marker"
}

# --- test 16: the help text teaches the format, and teaches it correctly -------------------
#
# A worker went looking for README.md to learn the TOML schema, because `-h` did not carry
# it. The help now does -- and a documented example that the tool's own guards would refuse
# is worse than no example, so the test does not eyeball the text: it extracts the example
# out of the help, builds the file that example names, and puts it through --check.

test16() {
    echo "test 16: -h carries the mutations-file format, and the example it shows is real"
    local d="$WORK/t16" repo="$WORK/t16/repo"
    mkdir -p "$d"
    init_repo "$repo"

    "$SCRIPT" -h > "$d/help.txt" 2>"$d/help.err"
    assert_eq "-h exits 0" 0 "$?"
    OUT=$(cat "$d/help.err")
    assert_eq "-h writes the help to stdout, not stderr" "" "$OUT"

    OUT=$(cat "$d/help.txt")
    assert_contains "the help names the top-level table" "[[mutation]]"
    assert_contains "the help names the edit table" "[[mutation.edit]]"
    assert_contains "the help says the file is TOML" "TOML"
    assert_contains "the help recommends stdin as the primary workflow" "Prefer a heredoc into 'git mutate -'"
    assert_contains "the worked example is an executable stdin invocation" "git mutate - <<'TOML'"
    assert_contains "the help gives the stdin form for guard-only checks" "git mutate --check -"
    assert_contains "the help documents the uniqueness guard" "exactly once"
    assert_contains "the help documents the prose-anchor refusal" "docstring"
    assert_contains "the help says stdin input is ephemeral" "THE INPUT IS EPHEMERAL"

    # Pull the first [[mutation]] block out of the help and dedent it -- whatever it says
    # today -- then build the tree it describes: each file it names, holding exactly the
    # anchors it declares. The fixture is derived from the documentation, so it cannot be a
    # second copy of it that drifts.
    if ! python3 - "$d/help.txt" "$d/example.toml" "$repo" <<'PY'
import os
import sys
import tomllib

help_txt, out, root = sys.argv[1], sys.argv[2], sys.argv[3]

lines = open(help_txt, encoding="utf-8").read().splitlines()
start = next(i for i, l in enumerate(lines) if l.strip() == "[[mutation]]")
end = start
while end < len(lines) and lines[end].strip() not in ("", "TOML"):
    end += 1
block = "\n".join(l[2:] if l.startswith("  ") else l for l in lines[start:end]) + "\n"
with open(out, "w", encoding="utf-8") as fh:
    fh.write(block)

doc = tomllib.loads(block)                       # the example must be valid TOML at all
mut = doc["mutation"][0]
assert isinstance(mut.get("name"), str) and mut["name"], "the example has no name"

files = {}
edits = mut.get("edit") or [mut]                 # either spelling of the same thing
for edit in edits:                               # ...carrying every key the parser requires
    for key in ("file", "old", "new"):
        assert isinstance(edit.get(key), str), "the example edit has no string %r" % key
    files.setdefault(edit["file"], []).append(edit["old"])

for rel, anchors in files.items():               # each anchor, once, and nothing else
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path) or root, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n\n".join(anchors) + "\n")
PY
    then
        fail "the example in -h is not a parseable mutations file"
        return 0
    fi
    ok "the example in -h is valid TOML with name, file, old and new"
    commit_all "$repo" "the files the help's example names"

    mutate "$repo" --check "$d/example.toml"
    assert_status "the example passes every guard the tool actually enforces" 0
    assert_contains "and --check confirms it names a real, unique, in-code anchor" \
        "every anchor is unique, in code, and changes the file."

    OUT=$("$SCRIPT" --check 2>&1); ST=$?
    assert_status "a usage error still prints the terse usage, not the whole manual" 1
    assert_contains "and the terse usage points at -h for the format" "git mutate -h"
    assert_missing "the terse usage does not inline the schema" "[[mutation.edit]]"
}

# --- test 13: exit status distinguishes clean, finding and not-measured -------------------

test13() {
    echo "test 13: exit status separates a clean sweep, a finding, and a broken measurement"
    need_pytest || return 0
    local d="$WORK/t13" repo="$WORK/t13/repo"
    mkdir -p "$d"
    make_fixture "$repo"
    write_main_mutations "$d/mutations.toml"

    mutate "$repo" --cmd pytest "$d/mutations.toml" assert-shapes
    assert_status "every mutation killed by an assertion exits 0" 0

    mutate "$repo" --cmd pytest "$d/mutations.toml" unchecked-doubling
    assert_status "a survivor exits 2" 2

    mutate "$repo" --cmd pytest "$d/mutations.toml" error-only
    assert_status "an error-only kill exits 2 as well: it is a finding" 2

    mutate "$repo" --cmd pytest "$d/mutations.toml" no-such-mutation
    assert_status "an unknown mutation name is a usage error (exit 1)" 1
    assert_contains "the usage error names the mutation asked for" "no mutation named 'no-such-mutation'"
}

# --- test 17: the fast tier narrows without ever inventing a kill --------------------------
#
# The tier exists because mutations cluster: the same few tests kill most of them, so after
# the first kill the rest can try that set first. It is safe only because a kill is monotone
# -- more tests can add reddened tests, never remove one -- so an assertion kill in the subset
# settles the verdict, while everything else falls through to the full suite. These pin both
# halves: that it fires and agrees with --no-fast, and that a finding never comes from it.

# A suite big enough that a subset is visibly not the whole thing, with two separate killers.
make_cluster_fixture() {
    local repo="$1" i
    init_repo "$repo"
    mkdir -p "$repo/tests"
    : > "$repo/conftest.py"
    cat > "$repo/mod.py" <<'EOF'
def walk():
    steps = [244, 331, 721]
    return steps


def render(name):
    return "hello " + name


def unchecked(n):
    return n * 2
EOF
    cat > "$repo/tests/test_mod.py" <<'EOF'
from mod import render, walk


def test_walk_returns_the_steps():
    assert walk() == [244, 331, 721]


def test_render_greets_by_name():
    assert render("bo") == "hello bo"
EOF
    for i in $(seq 1 30); do
        printf '\n\ndef test_padding_%s():\n    assert 1 == 1\n' "$i" >> "$repo/tests/test_mod.py"
    done
    commit_all "$repo" "cluster fixture"
}

write_cluster_mutations() {
    cat > "$1" <<'EOF'
[[mutation]]
name = "walk-first"
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [999, 331, 721]'''

[[mutation]]
name = "walk-second"
[[mutation.edit]]
file = "mod.py"
old = '''    return steps'''
new = '''    return steps[:2]'''

[[mutation]]
name = "render-broken"
[[mutation.edit]]
file = "mod.py"
old = '''    return "hello " + name'''
new = '''    return "hello"'''

[[mutation]]
name = "survivor"
[[mutation.edit]]
file = "mod.py"
old = '''    return n * 2'''
new = '''    return n * 3'''
EOF
}

# mod.walk is checked by a test that only passes because an earlier test primed module state.
# Run alone it fails -- so an unguarded fast tier would score it as the NEXT mutation's kill
# and swallow a survivor. This is the fixture that makes that failure reachable.
make_order_dependent_fixture() {
    local repo="$1"
    init_repo "$repo"
    mkdir -p "$repo/tests"
    : > "$repo/conftest.py"
    cat > "$repo/mod.py" <<'EOF'
STATE = {}


def prime():
    STATE["ready"] = True


def walk():
    steps = [244, 331, 721]
    return steps


def unchecked(n):
    return n * 2
EOF
    cat > "$repo/tests/test_mod.py" <<'EOF'
from mod import STATE, prime, walk


def test_a_primes_the_state():
    prime()
    assert STATE["ready"] is True


def test_b_needs_the_primed_state_and_walk():
    assert STATE.get("ready") is True
    assert walk() == [244, 331, 721]
EOF
    commit_all "$repo" "order dependent fixture"
}

write_iso_mutations() {
    cat > "$1" <<'EOF'
[[mutation]]
name = "break-walk"
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [999, 331, 721]'''

[[mutation]]
name = "must-survive"
[[mutation.edit]]
file = "mod.py"
old = '''    return n * 2'''
new = '''    return n * 3'''
EOF
}

test17() {
    echo "test 17: the fast tier narrows the sweep without ever inventing a kill"
    need_pytest || return 0
    local d="$WORK/t17" repo="$WORK/t17/repo" iso="$WORK/t17/iso" fast="" slow=""
    mkdir -p "$d"
    make_cluster_fixture "$repo"
    write_cluster_mutations "$d/mutations.toml"

    mutate "$repo" --cmd "python3 -m pytest -q" "$d/mutations.toml"
    fast="$OUT"
    assert_status "a sweep with the fast tier still exits 2 for the survivor" 2
    assert_contains "the header says the fast tier is on" "fast tier: on"
    assert_contains "a later mutation in the cluster is settled by the primed kill set" \
        "by assertion in the 1-test candidate set -- full suite not run"
    assert_contains "and the report says the full suite was not run for it" \
        "The full suite was not run: one assertion kill settles it"

    # The finding must come from a complete run, never from the subset.
    assert_contains "the survivor is still reported as reddening nothing" \
        "survivor: reddened nothing."
    # Line-scoped on purpose: a glob over the whole transcript would match the "candidate set"
    # wording of a DIFFERENT mutation further down the report.
    if printf '%s\n' "$fast" | grep "survivor" | grep -q "candidate set"; then
        fail "the survivor verdict came from the subset, not the full suite"
    else
        ok "the survivor verdict did not come from the subset"
    fi

    mutate "$repo" --no-fast --cmd "python3 -m pytest -q" "$d/mutations.toml"
    slow="$OUT"
    assert_status "--no-fast reaches the same exit status" 2
    assert_eq "the fast tier changes no verdict: the summary line is identical" \
        "$(printf '%s' "$slow" | sed -n 's/.*: \([0-9]* killed by assertion.*\)/\1/p')" \
        "$(printf '%s' "$fast" | sed -n 's/.*: \([0-9]* killed by assertion.*\)/\1/p')"

    # A test that passes in the suite but fails alone must not become the next mutation's kill.
    make_order_dependent_fixture "$iso"
    write_iso_mutations "$d/iso.toml"
    mutate "$iso" --cmd "python3 -m pytest -q" "$d/iso.toml"
    assert_contains "a test red only in isolation is not credited as a kill" \
        "must-survive: reddened nothing."
    assert_status "so the survivor is still a finding (exit 2)" 2

    # Appending ids to a command that names its own paths would widen the run; refuse to.
    mutate "$repo" --cmd "python3 -m pytest -q tests/" "$d/mutations.toml" survivor
    assert_contains "a command naming its own path turns the fast tier off, and says why" \
        "already names a path or test id"
    mutate "$repo" --env go --cmd "python3 -m pytest -q" "$d/mutations.toml" survivor
    assert_contains "a non-pytest env turns the fast tier off, and says why" \
        "only the pytest env selects by test id"
    mutate "$repo" --no-fast --cmd "python3 -m pytest -q" "$d/mutations.toml" survivor
    assert_contains "--no-fast says so plainly in the header" \
        "fast tier: off (disabled with --no-fast)"
}


# --- test 18: the caller's 'tests' hint is a hint, and never a filter ----------------------
#
# 'tests' says "I expect these to fail". It only decides what the fast tier tries FIRST, so
# it can be wrong, stale, or absent without changing a single verdict. What it buys is the
# first mutation of a sweep, which otherwise pays a full run before anything is primed.

write_hinted_mutations() {
    cat > "$1" <<'EOF'
[[mutation]]
name = "hinted-kill"
tests = ["tests/test_mod.py::test_walk_returns_the_steps"]
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [999, 331, 721]'''

[[mutation]]
name = "stale-hint"
tests = ["tests/test_mod.py::test_renamed_last_week"]
[[mutation.edit]]
file = "mod.py"
old = '''    return "hello " + name'''
new = '''    return "hello"'''

[[mutation]]
name = "hinted-survivor"
tests = ["tests/test_mod.py::test_walk_returns_the_steps"]
[[mutation.edit]]
file = "mod.py"
old = '''    return n * 2'''
new = '''    return n * 3'''
EOF
}

test18() {
    echo "test 18: a 'tests' hint steers the fast tier without steering any verdict"
    need_pytest || return 0
    local d="$WORK/t18" repo="$WORK/t18/repo"
    mkdir -p "$d"
    make_cluster_fixture "$repo"
    write_hinted_mutations "$d/mutations.toml"

    mutate "$repo" --check "$d/mutations.toml"
    assert_status "--check accepts a mutation carrying 'tests'" 0
    assert_contains "and --check says how many tests it expects to fail" \
        "[expects 1 test(s) to fail]"

    mutate "$repo" --cmd "python3 -m pytest -q" "$d/mutations.toml"
    # The point of the hint: mutation 1 needs no priming run first.
    assert_contains "the FIRST mutation is settled by the hint, with nothing primed yet" \
        "[1/3] hinted-kill ... reddened 1 by assertion in the 1-test candidate set"
    # A stale id makes pytest collect nothing at all, so it must be said out loud.
    assert_contains "a stale hint is reported rather than passing as a silent slowdown" \
        "stale-hint: selected no test that could be collected"
    assert_contains "and the stale-hinted mutation is still measured, by the full suite" \
        "stale-hint: reddened 1 -- 1 by assertion, 0 by error."
    # A hint pointing at a test the mutation cannot redden must not manufacture anything.
    assert_contains "a hint cannot turn a survivor into a kill" \
        "hinted-survivor: reddened nothing."
    assert_status "so the sweep still exits 2 for the finding" 2

    # Same file, hints removed: every verdict must be identical.
    sed '/^tests = /d' "$d/mutations.toml" > "$d/nohints.toml"
    mutate "$repo" --cmd "python3 -m pytest -q" "$d/nohints.toml"
    assert_status "dropping every hint changes no exit status" 2
    assert_contains "and no verdict: the survivor is still the survivor" \
        "hinted-survivor: reddened nothing."

    # The parser refuses a malformed hint rather than quietly ignoring it.
    cat > "$d/bad.toml" <<'EOF'
[[mutation]]
name = "bad-hint"
tests = "tests/test_mod.py::test_walk_returns_the_steps"
[[mutation.edit]]
file = "mod.py"
old = '''    return n * 2'''
new = '''    return n * 3'''
EOF
    mutate "$repo" --check "$d/bad.toml"
    assert_status "a 'tests' that is not an array is a usage error" 1
    assert_contains "and it says what 'tests' must be" "must be a non-empty array of test ids"
}


# --- test 20: a green baseline that ran nothing refuses, and a stale report cannot rescue it -

# The mirror of test 15. There the baseline failed unreadably; here it *passes*, having
# executed no tests at all -- the shape a mistyped selector produces, since Surefire takes a
# comma-separated list and an unmatched selector plus -Dsurefire.failIfNoSpecifiedTests=false
# exits green having run nothing. Left unguarded, every mutation afterwards reports "reddened
# nothing", which reads as a survivor and is a measurement that never happened.
#
# The third case is the one with teeth: Surefire's XML persists on disk, so a run that executes
# nothing leaves the previous run's reports in place. Counting those would report the earlier
# run's total, the guard would not fire, and the sweep would proceed on a stale measurement.
make_surefire_fixture() {
    local repo="$1" tests_attr="$2"
    init_repo "$repo"

    cat > "$repo/mod.py" <<'EOF'
def add(a, b):
    return a + b
EOF

    mkdir -p "$repo/target/surefire-reports"
    if [ -n "$tests_attr" ]; then
        cat > "$repo/runner.sh" <<EOF
#!/bin/bash
d="\$(cd "\$(dirname "\$0")" && pwd)"
mkdir -p "\$d/target/surefire-reports"
printf '<testsuite name="Mod" tests="%s" failures="0" errors="0" skipped="0"/>\n' "$tests_attr" \
    > "\$d/target/surefire-reports/TEST-Mod.xml"
exit 0
EOF
    else
        cat > "$repo/runner.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
    fi
    chmod +x "$repo/runner.sh"

    printf '%s\n' \
        '[[mutation]]' \
        'name = "add-subtracts"' \
        '[[mutation.edit]]' \
        'file = "mod.py"' \
        "old = \"\"\"    return a + b\"\"\"" \
        "new = \"\"\"    return a - b\"\"\"" \
        > "$repo/mutations.toml"
    commit_all "$repo" "surefire fixture"
}

test20() {
    echo "test 20: a green baseline that executed no tests refuses, and a stale report cannot rescue it"
    local d="$WORK/t20"
    mkdir -p "$d"

    make_surefire_fixture "$d/none" ""
    mutate "$d/none" --env mvn --cmd "$d/none/runner.sh" "$d/none/mutations.toml"
    assert_status "a green baseline that ran nothing refuses (exit 1), it does not sweep" 1
    assert_contains "the refusal says how many tests ran" "executed 0 tests"
    assert_contains "the refusal explains why a survivor would be fiction" "reddened nothing"
    assert_contains "the refusal points at the selector, which is the usual cause" "comma-separated"
    assert_no_sweep_state "$d/none" "a refused baseline leaves no lock or marker"

    make_surefire_fixture "$d/some" "2"
    mutate "$d/some" --env mvn --cmd "$d/some/runner.sh" "$d/some/mutations.toml"
    assert_missing "a baseline that really ran tests is not refused" "executed 0 tests"

    make_surefire_fixture "$d/stale" ""
    mkdir -p "$d/stale/target/surefire-reports"
    printf '<testsuite name="Old" tests="7" failures="0" errors="0" skipped="0"/>\n' \
        > "$d/stale/target/surefire-reports/TEST-Old.xml"
    touch -d "2020-01-01 00:00:00" "$d/stale/target/surefire-reports/TEST-Old.xml"
    mutate "$d/stale" --env mvn --cmd "$d/stale/runner.sh" "$d/stale/mutations.toml"
    assert_status "a previous run's report does not count as this run's measurement" 1
    assert_contains "the stale report is not mistaken for tests this run executed" "executed 0 tests"
}

# --- test 19: an expectation that did not come true is said out loud ----------------------
#
# The case this exists for: you name test_x, test_y does the killing instead. The verdict is
# a clean "killed by assertion" and the sweep exits 0, so without this the fact that your
# expectation was wrong is invisible -- you would have to notice that the test named in the
# report is not the test you named, across every mutation in the sweep.

write_expectation_mutations() {
    cat > "$1" <<'EOF'
[[mutation]]
name = "wrong-expectation"
tests = ["tests/test_mod.py::test_walk_returns_the_steps"]
[[mutation.edit]]
file = "mod.py"
old = '''    return "hello " + name'''
new = '''    return "hello"'''

[[mutation]]
name = "right-expectation"
tests = ["tests/test_mod.py::test_walk_returns_the_steps"]
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [999, 331, 721]'''
EOF
}

test19() {
    echo "test 19: an expectation the run did not bear out is reported, without changing the verdict"
    need_pytest || return 0
    local d="$WORK/t19" repo="$WORK/t19/repo"
    mkdir -p "$d"
    make_cluster_fixture "$repo"
    write_expectation_mutations "$d/mutations.toml"

    mutate "$repo" --cmd "python3 -m pytest -q" "$d/mutations.toml"
    assert_status "every mutation was killed by an assertion, so the sweep is clean (exit 0)" 0
    assert_contains "the section names the mutation and the test that did not fail" \
        "wrong-expectation: expected 'tests/test_mod.py::test_walk_returns_the_steps' to fail; it passed."
    assert_contains "the summary counts the unmet expectation" "1 expectation(s) not met"
    assert_contains "and says the verdict itself still stands" \
        "What is wrong here is the expectation, not the measurement."
    # The mutation was still killed -- by the OTHER test. The expectation is what was wrong.
    assert_contains "the mutation is still reported as killed, by the test that did redden" \
        "test_render_greets_by_name"
    # An expectation that came true is not mentioned at all.
    case "$OUT" in
        *"right-expectation: expected"*)
            fail "an expectation that came true was reported anyway" ;;
        *) ok "an expectation that came true is not mentioned" ;;
    esac

    # A hint that reddens only by error is not a met expectation either.
    cat > "$d/erroring.toml" <<'EOF'
[[mutation]]
name = "hint-errors-only"
tests = ["tests/test_mod.py::test_walk_returns_the_steps"]
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = undefined_name'''
EOF
    mutate "$repo" --cmd "python3 -m pytest -q" "$d/erroring.toml"
    assert_contains "a hint that only errors is not counted as met, and says why" \
        "failed only by error, which proves nothing about the behaviour"
    assert_status "an error-only kill is still a finding (exit 2), unchanged by the expectation" 2
}


# --- test 23: a bare hint for a parametrized test owns its parametrizations -----------------
#
# pytest reports a parametrized test only under its '[param]' ids, so a hint naming the bare
# function never compared equal to any row and was reported as having PASSED -- when it had
# failed by assertion in every case. A false entry here is worse than none: it tells the caller
# a test does not defend a behaviour when it does. The '[' is the boundary on both sides:
# 'test_step' must not claim 'test_stepbar[...]', and 'test_step[0]' must not claim its siblings.
make_param_fixture() {
    local repo="$1"
    init_repo "$repo"
    mkdir -p "$repo/tests"
    : > "$repo/conftest.py"
    cat > "$repo/mod.py" <<'EOF'
def walk():
    steps = [244, 331, 721]
    return steps


def render(name):
    return "hello " + name
EOF
    cat > "$repo/tests/test_mod.py" <<'EOF'
import pytest

from mod import render, walk


@pytest.mark.parametrize("i", [0, 1, 2])
def test_step(i):
    assert walk()[i] == [244, 331, 721][i]


@pytest.mark.parametrize("name", ["bo", "al"])
def test_stepbar(name):
    assert render(name) == "hello " + name
EOF
    commit_all "$repo" "param fixture"
}

test23() {
    echo "test 23: a bare hint for a parametrized test is matched against its parametrizations"
    need_pytest || return 0
    local d="$WORK/t23" repo="$WORK/t23/repo" h="tests/test_mod.py::test_step"
    mkdir -p "$d"
    make_param_fixture "$repo"
    cat > "$d/mutations.toml" <<EOF
[[mutation]]
name = "every-case-fails"
tests = ["$h"]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [0, 0, 0]'''

[[mutation]]
name = "one-case-fails"
tests = ["$h", "$h[2]"]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [244, 331, 0]'''

[[mutation]]
name = "assertion-and-error"
tests = ["$h"]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [0, 331]'''

[[mutation]]
name = "sibling-param"
tests = ["$h[0]"]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [244, 331, 1]'''

[[mutation]]
name = "only-the-prefix-fails"
tests = ["$h"]
file = "mod.py"
old = '''    return "hello " + name'''
new = '''    return "hello"'''
EOF
    mutate "$repo" --cmd "python3 -m pytest -q" "$d/mutations.toml"
    assert_status "every mutation was killed by an assertion (exit 0)" 0
    assert_missing "a bare hint that failed by assertion in every case is met" \
        "every-case-fails: expected"
    assert_missing "a bare hint is met when any case fails by assertion, the others passing" \
        "one-case-fails: expected"
    assert_missing "a bare hint is met by an assertion case even when another case errored" \
        "assertion-and-error: expected"
    assert_contains "a single-parameter hint matches only itself, not a failing sibling" \
        "sibling-param: expected '$h[0]' to fail; it passed."
    assert_contains "'test_step' does not claim 'test_stepbar[...]'; its own cases passed" \
        "only-the-prefix-fails: expected '$h' to fail; it passed."
    assert_contains "the count holds exactly the two hints that really did not fail" \
        "2 expectation(s) not met"

    # No parametrization failed by assertion, some errored: unmet, naming the errored cases.
    cat > "$d/erroring.toml" <<EOF
[[mutation]]
name = "cases-error-only"
tests = ["$h"]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [244, 331]'''
EOF
    mutate "$repo" --cmd "python3 -m pytest -q" "$d/erroring.toml"
    assert_contains "a bare hint whose cases only errored is unmet, naming those cases" \
        "cases-error-only: expected '$h' to fail; it failed only by error, which proves nothing about the behaviour -- errored in [2], and nothing it names failed by assertion."
    assert_status "an error-only kill is still a finding (exit 2), unchanged by the expectation" 2
}


# --- test 24: a class, module or directory hint owns its tests; a red one is not "passed" --
#
# Two more ways a hint read "passed" when it had not. A hint naming a class, module or
# directory selects many tests but equals none of their ids. And a hint naming a test that is
# already red -- before any mutation, or on the clean tree as the fast tier runs it -- is
# dropped from the rows, so its silence meant nothing. That one is neither met nor unmet: it is
# reported apart, and counted apart, rather than inflating the unmet count.
make_hint_scope_fixture() {
    local repo="$1"
    init_repo "$repo"
    mkdir -p "$repo/tests" "$repo/tests_more" "$repo/tests_red"
    : > "$repo/conftest.py"
    cat > "$repo/mod.py" <<'EOF'
STATE = {}


def prime():
    STATE["ready"] = True


def walk():
    steps = [244, 331, 721]
    return steps


def render(name):
    return "hello " + name


def lookup(key):
    return {"a": 1}[key]
EOF
    cat > "$repo/tests/test_mod.py" <<'EOF'
from mod import STATE, prime, render, walk


def test_a_primes_the_state():
    prime()
    assert STATE["ready"] is True


def test_b_needs_the_primed_state():
    assert STATE.get("ready") is True


class TestWalk:
    def test_steps(self):
        assert walk() == [244, 331, 721]


class TestWalkbar:
    def test_greets(self):
        assert render("bo") == "hello bo"
EOF
    cat > "$repo/tests_red/test_red.py" <<'EOF'
import pytest


def test_known_broken():
    assert 1 == 2


@pytest.mark.parametrize("i", [0, 1])
def test_half(i):
    assert i == 0
EOF
    cat > "$repo/tests_more/test_more.py" <<'EOF'
from mod import lookup


def test_lookup():
    assert lookup("a") == 1
EOF
    commit_all "$repo" "hint scope fixture"
}

test24() {
    echo "test 24: class, module and directory hints own their tests; an already-red hint is not 'passed'"
    need_pytest || return 0
    local d="$WORK/t24" repo="$WORK/t24/repo" m="tests/test_mod.py" r="tests_red/test_red.py"
    mkdir -p "$d"
    make_hint_scope_fixture "$repo"
    cat > "$d/mutations.toml" <<EOF
[[mutation]]
name = "class-hint"
tests = ["$m::TestWalk"]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [999, 331, 721]'''

[[mutation]]
name = "module-hint"
tests = ["$m"]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [998, 331, 721]'''

[[mutation]]
name = "class-prefix"
tests = ["$m::TestWalk"]
file = "mod.py"
old = '''    return "hello " + name'''
new = '''    return "hello"'''

[[mutation]]
name = "dir-hint"
tests = ["tests"]
file = "mod.py"
old = '''    return "hello " + name'''
new = '''    return "hi " + name'''

[[mutation]]
name = "dir-prefix"
tests = ["tests"]
file = "mod.py"
old = '''    return {"a": 1}[key]'''
new = '''    return {"a": 2}[key]'''

[[mutation]]
name = "baseline-red"
tests = ["$r::test_known_broken"]
file = "mod.py"
old = '''    return "hello " + name'''
new = '''    return "hey " + name'''

[[mutation]]
name = "baseline-red-case"
tests = ["$r::test_half"]
file = "mod.py"
old = '''    return "hello " + name'''
new = '''    return "yo " + name'''

[[mutation]]
name = "dir-with-red"
tests = ["tests_red"]
file = "mod.py"
old = '''    return {"a": 1}[key]'''
new = '''    return {"a": 3}[key]'''

[[mutation]]
name = "iso-red"
tests = ["$m::TestWalk", "$m::test_b_needs_the_primed_state"]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [997, 331, 721]'''
EOF
    mutate "$repo" --cmd "python3 -m pytest -q" "$d/mutations.toml"
    assert_status "every mutation was killed by an assertion (exit 0)" 0
    assert_missing "a class hint is met by a failing method of that class" "class-hint: expected"
    assert_missing "a module hint is met by a failing test in that module" "module-hint: expected"
    assert_missing "a directory hint is met by a failing test under it" "dir-hint: expected"
    assert_contains "'TestWalk' does not claim 'TestWalkbar::...'" \
        "class-prefix: expected '$m::TestWalk' to fail; it passed."
    assert_contains "'tests' does not claim 'tests_more/...'" \
        "dir-prefix: expected 'tests' to fail; it passed."
    assert_contains "a hint red before any mutation is reported as not checkable, not as passed" \
        "baseline-red: '$r::test_known_broken' could not be checked -- it already failed before any mutation."
    assert_contains "a parametrized hint with a baseline-red case names that case" \
        "baseline-red-case: '$r::test_half' could not be checked -- [1] already failed before any mutation; nothing else it names failed."
    assert_contains "a hint red on the clean tree as the fast tier runs it is not checkable" \
        "iso-red: '$m::test_b_needs_the_primed_state' could not be checked -- it already failed on the unmutated tree, run as the fast tier's subset."
    assert_contains "the fast tier really did settle the iso-red mutation" \
        "iso-red ... reddened"
    assert_contains "a group hint with red members says what the rest of it did" \
        "dir-with-red: 'tests_red' could not be checked -- test_red.py::test_half[1], test_red.py::test_known_broken already failed before any mutation; nothing else it names failed."
    assert_missing "an unchecked hint is not listed as unmet" "baseline-red: expected"
    assert_contains "unchecked hints get their own section" "== EXPECTATIONS NOT CHECKED"
    assert_contains "and their own count, apart from the unmet ones" \
        "2 expectation(s) not met, 4 not checkable."
}


# --- test 25: a Surefire hint owns the parametrized cases JUnit 5 reports --------------------
#
# JUnit 5 under Surefire reports a parametrized method as 'testAdd(int)[1]'. A hint naming
# 'Mod::testAdd' owns those; 'Mod::testAd' does not.
make_surefire_param_fixture() {
    local repo="$1"
    init_repo "$repo"
    cat > "$repo/mod.py" <<'EOF'
def add(a, b):
    return a + b
EOF
    cat > "$repo/runner.sh" <<'EOF'
#!/bin/bash
d="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$d/target/surefire-reports"
out="$d/target/surefire-reports/TEST-com.example.Mod.xml"
if (cd "$d" && python3 -B -c "import mod; assert mod.add(2, 3) == 5"); then
    printf '<testsuite name="com.example.Mod" tests="2" failures="0" errors="0" skipped="0"><testcase name="testAdd(int)[1]"/><testcase name="testAdd(int)[2]"/></testsuite>\n' > "$out"
    exit 0
fi
printf '<testsuite name="com.example.Mod" tests="2" failures="1" errors="0" skipped="0"><testcase name="testAdd(int)[1]"><failure type="org.opentest4j.AssertionFailedError" message="expected 5"/></testcase><testcase name="testAdd(int)[2]"/></testsuite>\n' > "$out"
exit 1
EOF
    chmod +x "$repo/runner.sh"
    cat > "$repo/mutations.toml" <<'EOF'
[[mutation]]
name = "junit5-case"
tests = ["Mod::testAdd"]
file = "mod.py"
old = '''    return a + b'''
new = '''    return a - b'''

[[mutation]]
name = "junit5-prefix"
tests = ["Mod::testAd"]
file = "mod.py"
old = '''    return a + b'''
new = '''    return a * b'''
EOF
    commit_all "$repo" "surefire param fixture"
}

test25() {
    echo "test 25: a Surefire hint owns the 'name(args)[n]' cases JUnit 5 reports"
    local d="$WORK/t25" repo="$WORK/t25/repo"
    mkdir -p "$d"
    make_surefire_param_fixture "$repo"
    mutate "$repo" --env mvn --cmd "$repo/runner.sh" "$repo/mutations.toml"
    assert_status "both mutations were killed by an assertion (exit 0)" 0
    assert_missing "'Mod::testAdd' is met by 'Mod::testAdd(int)[1]'" "junit5-case: expected"
    assert_contains "'Mod::testAd' does not claim 'Mod::testAdd(int)[1]'" \
        "junit5-prefix: expected 'Mod::testAd' to fail; it passed."
}


# --- test 21: a size-preserving mutation is measured against ITS OWN code ------------------
#
# CPython validates a cached .pyc against the source's (mtime, size). 'A = 1' -> 'A = 2'
# preserves the size, and a sweep is fast enough -- especially with the fast tier -- that the
# write lands inside the same mtime second as the existing .pyc. The test run then imports the
# PREVIOUS bytecode, so the sweep measures code that is not in the tree. When the stale
# bytecode happens to be the unmutated original, the mutation reddens nothing and reports a
# false finding: the one output this tool must never produce.
#
# Pinned by observation rather than by mechanism: four single-digit constant edits, each of
# which must produce its own distinct assertion message. Stale bytecode makes the messages
# repeat, because the value reported belongs to whichever mutation was compiled last.
make_bytecode_fixture() {
    local repo="$1"
    init_repo "$repo"
    mkdir -p "$repo/tests"
    : > "$repo/conftest.py"
    cat > "$repo/mod.py" <<'EOF'
A = 1
B = 2
C = 3
D = 4


def score(n):
    base = n * A
    bump = base + B
    trim = bump - C
    return trim + D
EOF
    cat > "$repo/tests/test_mod.py" <<'EOF'
from mod import score


def test_score_is_exact():
    assert score(10) == 13
EOF
    commit_all "$repo" "bytecode fixture"
    # Warm __pycache__ so a cached .pyc for the unmutated module really is on disk before the
    # sweep starts. Without this the first mutation would compile from source anyway and the
    # race the test exists to pin would not be reachable.
    (cd "$repo" && python3 -m pytest -q >/dev/null 2>&1)
}

write_bytecode_mutations() {
    cat > "$1" <<'EOF'
[[mutation]]
name = "bump-a"
[[mutation.edit]]
file = "mod.py"
old = '''A = 1'''
new = '''A = 2'''

[[mutation]]
name = "bump-b"
[[mutation.edit]]
file = "mod.py"
old = '''B = 2'''
new = '''B = 9'''

[[mutation]]
name = "bump-c"
[[mutation.edit]]
file = "mod.py"
old = '''C = 3'''
new = '''C = 8'''

[[mutation]]
name = "bump-d"
[[mutation.edit]]
file = "mod.py"
old = '''D = 4'''
new = '''D = 7'''
EOF
}

test21() {
    echo "test 21: a size-preserving mutation is measured against its own code, not a stale .pyc"
    need_pytest || return 0
    local d="$WORK/t21" repo="$WORK/t21/repo"
    mkdir -p "$d"
    make_bytecode_fixture "$repo"
    write_bytecode_mutations "$d/mutations.toml"

    mutate "$repo" --cmd "python3 -m pytest -q" "$d/mutations.toml"
    assert_status "every size-preserving mutation is killed by the assertion it should be" 0
    # score(10) = 10*A + B - C + D, so each edit has one correct answer and no other.
    assert_contains "bump-a is measured as A=2, not as a cached A=1"  "assert 23 == 13"
    assert_contains "bump-b is measured as B=9"                       "assert 20 == 13"
    assert_contains "bump-c is measured as C=8"                       "assert 8 == 13"
    assert_contains "bump-d is measured as D=7"                       "assert 16 == 13"

    # The same four, with the fast tier off: the window is wider but the guarantee is the same.
    mutate "$repo" --no-fast --cmd "python3 -m pytest -q" "$d/mutations.toml"
    assert_contains "and again with --no-fast: A=2"  "assert 23 == 13"
    assert_contains "and again with --no-fast: B=9"  "assert 20 == 13"
    assert_contains "and again with --no-fast: C=8"  "assert 8 == 13"
    assert_contains "and again with --no-fast: D=7"  "assert 16 == 13"
}


# --- test 22: the flat spelling of a single-edit mutation --------------------------------
#
# Nearly every mutation is one edit, and making those carry a [[mutation.edit]] table is
# ceremony that buys nothing. 'file'/'old'/'new' may sit directly in the [[mutation]]. The
# table form stays for what it was invented for: several edits applied as one mutation.
# The two are the same thing, so the test that matters is that they produce the same output
# byte for byte -- not that the flat one merely parses.

write_flat_pair() {
    local flat="$1" table="$2"
    cat > "$flat" <<'EOF'
[[mutation]]
name = "walk-broken"
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [244, 331, 434]'''

[[mutation]]
name = "unchecked-doubling"
file = "mod.py"
old = '''    return n * 2'''
new = '''    return n * 3'''
EOF
    cat > "$table" <<'EOF'
[[mutation]]
name = "walk-broken"
[[mutation.edit]]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [244, 331, 434]'''

[[mutation]]
name = "unchecked-doubling"
[[mutation.edit]]
file = "mod.py"
old = '''    return n * 2'''
new = '''    return n * 3'''
EOF
}

test22() {
    echo "test 22: a single-edit mutation may drop [[mutation.edit]], and means the same thing"
    need_pytest || return 0
    local d="$WORK/t22" repo="$WORK/t22/repo" flat_out="" table_out=""
    mkdir -p "$d"
    make_fixture "$repo"
    write_flat_pair "$d/flat.toml" "$d/table.toml"

    # Fed on stdin so the header says "from -" for both, and the transcripts are comparable.
    mutate_stdin "$repo" "$d/flat.toml" --cmd pytest -
    flat_out="$OUT"
    assert_status "the flat spelling sweeps and reports a finding, like any other file" 2
    assert_contains "the flat spelling kills what it should" \
        "walk-broken: reddened 1 -- 1 by assertion, 0 by error."
    assert_contains "and surfaces the survivor it should" "unchecked-doubling: reddened nothing."

    mutate_stdin "$repo" "$d/table.toml" --cmd pytest -
    table_out="$OUT"
    assert_status "the table spelling reaches the same exit status" 2
    assert_eq "the two spellings produce byte-identical output" "$table_out" "$flat_out"

    # 'tests' still works where it always did.
    cat > "$d/hinted.toml" <<'EOF'
[[mutation]]
name = "flat-with-hint"
tests = ["tests/test_mod.py::test_walk_returns_the_steps"]
file = "mod.py"
old = '''    steps = [244, 331, 721]'''
new = '''    steps = [244, 331, 434]'''
EOF
    mutate "$repo" --check "$d/hinted.toml"
    assert_status "a flat mutation may still carry 'tests'" 0
    assert_contains "and --check reads the hint from it" "[expects 1 test(s) to fail]"

    # A mutation that uses both spellings has no sensible reading; guessing would drop an edit.
    cat > "$d/mixed.toml" <<'EOF'
[[mutation]]
name = "mixed"
file = "mod.py"
old = '''    return n * 2'''
new = '''    return n * 3'''
[[mutation.edit]]
file = "mod.py"
old = '''    return "plain"'''
new = '''    return "other"'''
EOF
    mutate "$repo" --check "$d/mixed.toml"
    assert_status "mixing the two spellings is a usage error, not a silent choice" 1
    assert_contains "and it names both halves of the contradiction" \
        "gives both [[mutation.edit]] and a top-level 'file', 'old', 'new'"

    # Neither spelling present at all.
    printf '%s\n' '[[mutation]]' 'name = "empty"' > "$d/empty.toml"
    mutate "$repo" --check "$d/empty.toml"
    assert_status "a mutation with no edit at all is refused" 1
    assert_contains "and the refusal teaches both spellings" \
        "give it 'file', 'old' and 'new' directly, or one or more [[mutation.edit]] tables"

    # A half-written flat mutation reports itself without inventing an edit number.
    printf '%s\n' '[[mutation]]' 'name = "partial"' 'file = "mod.py"' "old = '''x'''" \
        > "$d/partial.toml"
    mutate "$repo" --check "$d/partial.toml"
    assert_status "a flat mutation missing a key is refused" 1
    assert_contains "and says so without pointing at a table that is not there" \
        "mutation 'partial' is missing a string 'new'"
    assert_missing "so no phantom edit number appears" "mutation 'partial' edit 1"
}


# --- test 26: a script can measure failures without pretending to be a test runner ---------

test26() {
    echo "test 26: shell checks classify their own failure lines"
    local d="$WORK/t26" repo="$WORK/t26/repo" pattern
    mkdir -p "$d"
    init_repo "$repo"
    cat > "$repo/state.sh" <<'EOF'
state=good
unchecked=one
EOF
    cat > "$repo/check.sh" <<'EOF'
#!/bin/sh
. ./state.sh
case "$state" in
    good) echo 'no tests ran'; exit 0 ;;
    bad) echo 'FAIL: deploy: release rejected'; exit 1 ;;
    overlap) echo 'FAIL: deploy: crash cannot find symbol'; exit 1 ;;
    crash) echo 'CRASH: deploy: SyntaxError: broken'; exit 1 ;;
    silent) echo 'unrelated diagnostic'; exit 1 ;;
    twice) printf '\033[31mFAIL: deploy: release rejected\033[0m\nFAIL: deploy: release rejected\n'; exit 1 ;;
esac
EOF
    cat > "$d/mutations.toml" <<'EOF'
[[mutation]]
name = "bad"
file = "state.sh"
old = 'state=good'
new = 'state=bad'
tests = ["deploy"]
[[mutation]]
name = "survivor"
file = "state.sh"
old = 'unchecked=one'
new = 'unchecked=two'
[[mutation]]
name = "overlap"
file = "state.sh"
old = 'state=good'
new = 'state=overlap'
[[mutation]]
name = "crash"
file = "state.sh"
old = 'state=good'
new = 'state=crash'
[[mutation]]
name = "silent"
file = "state.sh"
old = 'state=good'
new = 'state=silent'
[[mutation]]
name = "twice"
file = "state.sh"
old = 'state=good'
new = 'state=twice'
EOF
    commit_all "$repo" fixture

    mutate "$repo" --env lines --fail-pattern '^FAIL: ' --cmd 'sh check.sh' "$d/mutations.toml" bad survivor
    assert_status "a lines sweep reports a surviving mutation as a finding" 2
    assert_contains "a shell failure kills by assertion" "bad: reddened 1 -- 1 by assertion, 0 by error."
    assert_contains "the whole failure line supplies both id and message" \
        "assertion FAIL: deploy: release rejected -- FAIL: deploy: release rejected"
    assert_contains "an unchecked mutation survives" "survivor: reddened nothing."
    assert_contains "lines disables the fast tier loudly" "fast tier: off (--env lines"
    assert_missing "a shell script's output is not counted as pytest tests" "executed 0 tests"

    mutate "$repo" --env lines --fail-pattern '^FAIL: ' --cmd 'sh check.sh' "$d/mutations.toml" bad
    assert_status "an assertion-only lines sweep exits cleanly" 0

    mutate "$repo" --env lines --fail-pattern '^FAIL: ' --error-pattern 'crash|^CRASH:' \
        --cmd 'sh check.sh' "$d/mutations.toml" overlap crash
    assert_status "errors alone are findings" 2
    assert_contains "an error match overrides the default assertion classification" "overlap: reddened 1, ALL BY ERROR"
    assert_contains "an error pattern also recognizes a standalone crash line" "crash: reddened 1, ALL BY ERROR"
    assert_contains "the crash message is preserved" "CRASH: deploy: SyntaxError: broken -- CRASH: deploy: SyntaxError: broken"
    assert_missing "runner compiler heuristics do not override explicit line patterns" "NOT MEASURED"

    mutate "$repo" --env lines --fail-pattern '^FAIL: ' --error-pattern crash \
        --assertion-pattern '^FAIL: deploy:' --cmd 'sh check.sh' "$d/mutations.toml" overlap
    assert_status "the assertion pattern still overrides errors by matching the message" 0
    assert_contains "the override is an assertion kill" "overlap: reddened 1 -- 1 by assertion, 0 by error."

    mutate "$repo" --env lines --fail-pattern '^FAIL: ' --cmd 'sh check.sh' "$d/mutations.toml" silent
    assert_status "a nonzero exit with no matching line is not measured" 3
    assert_contains "an unexplained script failure is reported explicitly" "test command exited 1 but matched nothing -- not measured"
    assert_contains "the remedy names the line patterns" "matched neither --fail-pattern nor --error-pattern"
    assert_missing "lines diagnostics do not ask for pytest output" "pytest-shaped"

    pattern='^FAIL: (?P<id>[^:]+): (?P<msg>.*)$'
    mutate "$repo" --env=lines --fail-pattern "$pattern" --cmd 'sh check.sh' \
        --fast-cmd 'exit 99 # {}' "$d/mutations.toml" bad
    assert_status "a custom fast command cannot narrow generic checks" 0
    assert_contains "named groups supply id and message separately" "assertion deploy -- release rejected"
    assert_missing "a named id satisfies the matching expectation" "== EXPECTATIONS NOT MET"
    assert_contains "explicit fast commands still disable loudly" "fast tier: off (--env lines"

    mutate "$repo" --env lines --fail-pattern "$pattern" --error-pattern '^FAIL:' \
        --assertion-pattern '^release rejected$' --cmd 'sh check.sh' "$d/mutations.toml" bad
    assert_status "assertion pattern searches the captured message" 0

    mutate "$repo" --env lines --fail-pattern '^FAIL: ' \
        --error-pattern '^CRASH: (?P<id>[^:]+): (?P<msg>.*)$' \
        --cmd 'sh check.sh' "$d/mutations.toml" crash
    assert_contains "an error-only match also supplies named groups" "error     deploy -- SyntaxError: broken"

    mutate "$repo" --env lines --fail-pattern '^FAIL: (?P<id>[^:]+): ' \
        --cmd 'sh check.sh' "$d/mutations.toml" bad
    assert_contains "missing msg falls back independently" "assertion deploy -- FAIL: deploy: release rejected"
    mutate "$repo" --env lines --fail-pattern '^FAIL: deploy: (?P<msg>.*)$' \
        --cmd 'sh check.sh' "$d/mutations.toml" bad
    assert_contains "missing id falls back independently" "assertion FAIL: deploy: release rejected -- release rejected"
    mutate "$repo" --env lines --fail-pattern '^(?P<id>unused)?(?P<msg>unused)?FAIL: ' \
        --cmd 'sh check.sh' "$d/mutations.toml" bad
    assert_contains "unmatched optional groups fall back to the line" \
        "assertion FAIL: deploy: release rejected -- FAIL: deploy: release rejected"

    mutate "$repo" --env lines --fail-pattern "$pattern" --cmd 'sh check.sh' "$d/mutations.toml" twice
    assert_status "colored lines are recognized" 0
    assert_contains "every matching line counts, even with a repeated id" "twice: reddened 2 -- 2 by assertion, 0 by error."
    assert_contains "ANSI codes are stripped before capture" "assertion deploy -- release rejected"

    mutate "$repo" --env lines --fail-pattern "$pattern" \
        --cmd '. ./state.sh; echo "FAIL: deploy: state is $state"; exit 1' "$d/mutations.toml" bad
    assert_status "a stable baseline id cannot be credited as a new kill" 2
    assert_contains "baseline failures are excluded even when messages change" "bad: reddened nothing."

    mutate "$repo" --env lines --fail-pattern '^FAIL: ' --cmd 'exit 1' "$d/mutations.toml" bad
    assert_status "an unreadable baseline refuses the sweep" 1
    assert_contains "baseline refusal explains the patterns" "matched neither --fail-pattern nor --error-pattern"
    assert_missing "baseline refusal is specific to lines" "pytest-shaped"

    mutate "$repo" --env lines --cmd 'sh check.sh' "$d/mutations.toml" bad
    assert_status "lines requires a failure pattern" 1
    assert_contains "the missing-pattern error names the flag" "--env lines requires --fail-pattern"
    mutate "$repo" --env lines --fail-pattern '[' --cmd 'sh check.sh' "$d/mutations.toml" bad
    assert_status "malformed failure regex is a usage error" 1
    assert_contains "malformed failure regex names its flag" "invalid --fail-pattern regex"
    mutate "$repo" --env lines --fail-pattern '^FAIL:' --error-pattern '[' --cmd 'sh check.sh' "$d/mutations.toml" bad
    assert_status "malformed error regex is a usage error" 1
    assert_contains "malformed error regex names its flag" "invalid --error-pattern regex"
    mutate "$repo" --env pytest --fail-pattern '^FAIL:' --cmd 'sh check.sh' "$d/mutations.toml" bad
    assert_status "line patterns are refused in a runner ecosystem" 1
    assert_contains "the mode mismatch is explained" "--fail-pattern requires --env lines"

    cat > "$repo/.git/info/git-mutate" <<'EOF'
env = lines
cmd = sh check.sh
fail_pattern = ^FAIL:
error_pattern = release rejected
EOF
    mutate "$repo" "$d/mutations.toml" bad
    assert_status "project defaults supply both patterns" 2
    assert_contains "configured error pattern classifies the failure" "bad: reddened 1, ALL BY ERROR"
    mutate "$repo" --error-pattern '^CRASH:' "$d/mutations.toml" bad
    assert_status "explicit error pattern overrides project config" 0
    mutate "$repo" --fail-pattern '^NEVER:' --error-pattern '^CRASH:' "$d/mutations.toml" bad
    assert_status "explicit failure pattern overrides project config" 3

    assert_clean_tree "$repo" "lines sweeps restore all mutations"
    assert_no_sweep_state "$repo" "lines sweeps and usage errors leave no state"
}

# Optional test names keep foreground verification sweeps focused on one behaviour.
if [ "$#" -eq 0 ]; then
    set -- test1 test2 test3 test4 test5 test6 test7 test8 test9 test10 test11 test12 test13 \
        test14 test15 test16 test17 test18 test19 test20 test21 test22 test23 test24 test25 test26
fi
for selected_test in "$@"; do
    case "$selected_test" in
        test[0-9]|test[0-9][0-9])
            declare -F "$selected_test" >/dev/null || { echo "Unknown test: $selected_test" >&2; exit 1; }
            "$selected_test" ;;
        *) echo "Unknown test: $selected_test" >&2; exit 1 ;;
    esac
done

echo
echo "== behaviour -> test mapping =="
echo "26. shell checks use line patterns, with explicit error classification ... test26"
echo "1.  four failure shapes classified; error-only proves nothing ..... test1"
echo "2.  classification survives colorized output ...................... test2"
echo "3.  every edit's anchor guarded; no-op and prose anchors refused ... test3"
echo "4.  a mutation reddening nothing is surfaced first, with no score .. test4"
echo "5.  multi-file mutation applies and restores every touched file .... test5"
echo "6.  the marker makes the transient dirtiness visible ............... test6"
echo "7.  restored on failure, timeout and ^C; cmp-verified ............. test7"
echo "8.  snapshot taken at mutation time; stale one needs --recover .... test8"
echo "9.  a second concurrent sweep refuses ............................. test9"
echo "10. --check guards without mutating or running tests .............. test10"
echo "11. the test command is the gate's own pytest hook, minus coverage . test11"
echo "12. an already-red test is excluded; an erroring suite refuses .... test12"
echo "13. exit status separates clean, finding and broken measurement ... test13"
echo "14. a failing, unparseable run is 'not measured', never a survivor . test14"
echo "15. an unreadable failing baseline refuses to sweep, naming --cmd .. test15"
echo "16. -h teaches the file format, and its example passes the guards . test16"
echo "17. the fast tier narrows the sweep but never invents a kill ...... test17"
echo "18. a caller's 'tests' hint steers the tier, never a verdict ...... test18"
echo "19. an expectation that did not come true is reported .......... test19"
echo "22. a single-edit mutation may drop [[mutation.edit]] ....... test22"
echo "21. a size-preserving mutation is measured, not a stale .pyc ... test21"
echo "23. a bare hint for a parametrized test owns its cases ... test23"
echo "24. class/module/dir hints own their tests; red hints unchecked  test24"
echo "25. a Surefire hint owns JUnit 5's name(args)[n] cases ........ test25"
echo "20. a green baseline that ran nothing refuses; stale reports uncounted  test20"
echo
echo "$TESTS_RUN assertions, $TESTS_FAILED failed, $TESTS_SKIPPED test(s) skipped"
[ "$TESTS_FAILED" -eq 0 ]
