#!/bin/bash
#
# Copyright (c) 2026 Karl-Johan Alm
# Distributed under the MIT software license, see the accompanying
# file LICENSE or http://www.opensource.org/licenses/mit-license.php.
#
# Test suite for git-done. Builds throwaway repos under a temp dir with a local "remote",
# and shims `git refresh` and `git cleanup` onto PATH so the test observes what git-done
# calls without doing any of it. Touches nothing outside the temp dir, and needs no network.
# Each test names the behaviour it pins; see the final summary for the full mapping.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../git-done"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TESTS_RUN=0
TESTS_FAILED=0
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

assert_branch() {
    local repo="$1" desc="$2" expected="$3"
    assert_eq "$desc" "$expected" "$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
}

# Stand-ins for the two commands git-done drives. Each records the branch it was called on,
# which is what proves git-done switched first rather than refreshing whatever was checked
# out. `git <name>` finds these on PATH exactly as it would the real thing.
make_shims() {
    local bin="$1" log="$2" refresh_status="${3:-0}"
    mkdir -p "$bin"
    cat > "$bin/git-refresh" <<EOF
#!/bin/bash
echo "refresh on \$(git rev-parse --abbrev-ref HEAD)" >> "$log"
exit $refresh_status
EOF
    cat > "$bin/git-cleanup" <<EOF
#!/bin/bash
echo "cleanup on \$(git rev-parse --abbrev-ref HEAD)" >> "$log"
exit 0
EOF
    chmod +x "$bin/git-refresh" "$bin/git-cleanup"
}

log_lines() {
    local log="$1"
    if [ -f "$log" ]; then cat "$log"; fi
}

run_done() {
    local repo="$1" bin="$2"
    OUT=$( (cd "$repo" && PATH="$bin:$PATH" "$SCRIPT") 2>&1 )
    ST=$?
}

# A remote whose default branch is whatever the test needs, plus a clone with a feature
# branch to stand on.
fresh() {
    local d="$1" default="$2"
    rm -rf "$d"
    mkdir -p "$d"
    git init -q -b "$default" "$d/remote"
    git -C "$d/remote" config user.email test@example.com
    git -C "$d/remote" config user.name test
    echo base > "$d/remote/f.txt"
    git -C "$d/remote" add -A
    git -C "$d/remote" commit -qm base

    git clone -q "$d/remote" "$d/local"
    git -C "$d/local" config user.email test@example.com
    git -C "$d/local" config user.name test
}

# --- test 1: a repo whose default branch is not master ------------------------------

test1() {
    echo "test 1: git done returns to the default branch when that branch is not master"
    local d="$WORK/t1" log="$WORK/t1/log"
    fresh "$d" main
    make_shims "$d/bin" "$log"

    git -C "$d/local" checkout -q -b feature
    echo work > "$d/local/g.txt"
    git -C "$d/local" add -A
    git -C "$d/local" commit -qm work

    run_done "$d/local" "$d/bin"
    assert_eq "exits 0" "0" "$ST"
    assert_branch "$d/local" "HEAD is left on the default branch" "main"
    assert_eq "refresh and cleanup both ran, on the default branch" \
        "refresh on main
cleanup on main" "$(log_lines "$log")"
}

# --- test 2: already standing on the default branch --------------------------------

test2() {
    echo "test 2: git done needs no checkout when already on the default branch"
    local d="$WORK/t2" log="$WORK/t2/log"
    fresh "$d" main
    make_shims "$d/bin" "$log"

    run_done "$d/local" "$d/bin"
    assert_eq "exits 0" "0" "$ST"
    assert_branch "$d/local" "HEAD stays on the default branch" "main"
    assert_eq "refresh and cleanup still run" \
        "refresh on main
cleanup on main" "$(log_lines "$log")"
}

# --- test 3: a master-default repo behaves as before ------------------------------

test3() {
    echo "test 3: a repo whose default branch is master still works (no regression)"
    local d="$WORK/t3" log="$WORK/t3/log"
    fresh "$d" master
    make_shims "$d/bin" "$log"

    git -C "$d/local" checkout -q -b feature
    run_done "$d/local" "$d/bin"
    assert_eq "exits 0" "0" "$ST"
    assert_branch "$d/local" "HEAD is left on master" "master"
    assert_eq "refresh and cleanup both ran, on master" \
        "refresh on master
cleanup on master" "$(log_lines "$log")"
}

# --- test 4: a failing refresh stops the sequence ---------------------------------

test4() {
    echo "test 4: a failing git refresh aborts git done instead of cleaning up anyway"
    local d="$WORK/t4" log="$WORK/t4/log"
    fresh "$d" main
    make_shims "$d/bin" "$log" 1

    git -C "$d/local" checkout -q -b feature
    run_done "$d/local" "$d/bin"
    if [ "$ST" -ne 0 ]; then ok "git done reports the failure"; else fail "git done reports the failure (exit was 0)"; fi
    assert_eq "cleanup never ran" "refresh on main" "$(log_lines "$log")"
}

test1
test2
test3
test4

echo
echo "== behaviour -> test mapping =="
echo "1. returns to a non-master default branch ................... test1"
echo "2. no checkout needed when already on the default branch .... test2"
echo "3. a master-default repo is unaffected ..................... test3"
echo "4. a failing refresh aborts before cleanup ................. test4"
echo
echo "$TESTS_RUN assertions, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ]
