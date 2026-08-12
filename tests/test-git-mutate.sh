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
SCRIPT="$HERE/../git-mutate"
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
    assert_contains "the help documents the uniqueness guard" "exactly once"
    assert_contains "the help documents the prose-anchor refusal" "docstring"
    assert_contains "the help says the file is scratch, not committed" ".gitignore"

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
while end < len(lines) and lines[end].strip():
    end += 1
block = "\n".join(l[2:] if l.startswith("  ") else l for l in lines[start:end]) + "\n"
with open(out, "w", encoding="utf-8") as fh:
    fh.write(block)

doc = tomllib.loads(block)                       # the example must be valid TOML at all
mut = doc["mutation"][0]
assert isinstance(mut.get("name"), str) and mut["name"], "the example has no name"

files = {}
for edit in mut["edit"]:                         # ...carrying every key the parser requires
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

test1
test2
test3
test4
test5
test6
test7
test8
test9
test10
test11
test12
test13
test14
test15
test16

echo
echo "== behaviour -> test mapping =="
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
echo
echo "$TESTS_RUN assertions, $TESTS_FAILED failed, $TESTS_SKIPPED test(s) skipped"
[ "$TESTS_FAILED" -eq 0 ]
