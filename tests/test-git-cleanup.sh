#!/bin/bash
#
# Copyright (c) 2026 Karl-Johan Alm
# Distributed under the MIT software license, see the accompanying
# file LICENSE or http://www.opensource.org/licenses/mit-license.php.
#
# Test suite for git-cleanup. Builds throwaway repos under a temp dir -- a local repo
# standing in for the remote -- and touches nothing outside it; no network needed. Each
# test names the behaviour it pins; see the final summary for the full mapping.
#
# The contract under test is one sentence: a branch is removed only if every commit on it
# is already contained in origin's default branch. Every test below is either an instance
# of that, or a branch that must therefore survive.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../git-cleanup"
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

assert_missing() {
    local desc="$1" needle="$2"
    case "$OUT" in
        *"$needle"*) fail "$desc (output unexpectedly has '$needle'; output was: $OUT)" ;;
        *) ok "$desc" ;;
    esac
}

assert_has_branch() {
    local repo="$1" branch="$2" desc="$3"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        ok "$desc"
    else
        fail "$desc (branch '$branch' was deleted)"
    fi
}

assert_no_branch() {
    local repo="$1" branch="$2" desc="$3"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        fail "$desc (branch '$branch' still exists)"
    else
        ok "$desc"
    fi
}

run_cleanup() {
    local repo="$1"
    OUT=$( (cd "$repo" && "$SCRIPT") 2>&1 )
    ST=$?
}

commit_in() {
    local repo="$1" file="$2" msg="$3"
    echo "$msg" > "$repo/$file"
    git -C "$repo" add -A
    git -C "$repo" commit -qm "$msg"
}

# A remote whose default branch already contains a merged topic, and a clone of it. The
# merge is --no-ff so that origin/main^2 names a commit that is genuinely upstream but is
# not the tip -- the shape a real merged-and-pushed topic branch has.
fresh() {
    local d="$1" remote="$1/remote" local="$1/local"
    rm -rf "$d"
    mkdir -p "$d"

    git init -q -b main "$remote"
    git -C "$remote" config user.email test@example.com
    git -C "$remote" config user.name test
    commit_in "$remote" f.txt base

    git -C "$remote" checkout -q -b upstreamed
    commit_in "$remote" u.txt "work that reached upstream"
    git -C "$remote" checkout -q main
    git -C "$remote" merge -q --no-ff -m "merge upstreamed" upstreamed
    git -C "$remote" branch -qD upstreamed

    git clone -q "$remote" "$local"
    git -C "$local" config user.email test@example.com
    git -C "$local" config user.name test
}

# Four local branches covering the whole contract:
#   upstreamed  -- tip is contained in origin/main            -> must go
#   remain-fix  -- same, but its name contains "main"         -> must go
#   unpushed    -- merged into LOCAL main only                -> must stay
#   unmerged    -- contained nowhere else                     -> must stay
setup_branches() {
    local repo="$1"
    git -C "$repo" branch upstreamed "origin/main^2"
    git -C "$repo" branch remain-fix "origin/main^2"

    git -C "$repo" checkout -q -b unpushed
    commit_in "$repo" p.txt "merged locally, never pushed"
    git -C "$repo" checkout -q main
    git -C "$repo" merge -q --no-ff -m "merge unpushed" unpushed

    git -C "$repo" checkout -q -b unmerged
    commit_in "$repo" n.txt "not merged anywhere"
    git -C "$repo" checkout -q main
}

# --- test 1: the contract, from the default branch ---------------------------------

test1() {
    echo "test 1: branches contained in origin's default branch go; everything else stays"
    local d="$WORK/t1" repo="$WORK/t1/local"
    fresh "$d"
    setup_branches "$repo"

    run_cleanup "$repo"
    assert_eq "exits 0" "0" "$ST"
    assert_no_branch "$repo" upstreamed "a branch whose commits are upstream is removed"
    assert_has_branch "$repo" unmerged "a branch merged nowhere survives"
    assert_has_branch "$repo" main "the default branch survives"
}

# --- test 2: only *upstream* counts, not a local merge -----------------------------

test2() {
    echo "test 2: a branch merged into local main but never pushed is not touched"
    local d="$WORK/t2" repo="$WORK/t2/local"
    fresh "$d"
    setup_branches "$repo"

    run_cleanup "$repo"
    assert_has_branch "$repo" unpushed "an unpushed local merge is not 'merged upstream'"
    if git -C "$repo" merge-base --is-ancestor unpushed main; then
        ok "and it really is merged into local main (so only the base choice spared it)"
    else
        fail "and it really is merged into local main (so only the base choice spared it)"
    fi
}

# --- test 3: the same result from a feature branch ---------------------------------

test3() {
    echo "test 3: the result does not depend on which branch happens to be checked out"
    local d="$WORK/t3" repo="$WORK/t3/local"
    fresh "$d"
    setup_branches "$repo"
    git -C "$repo" checkout -q unmerged

    run_cleanup "$repo"
    assert_eq "exits 0" "0" "$ST"
    assert_no_branch "$repo" upstreamed "an upstream-merged branch is removed from a feature branch too"
    assert_has_branch "$repo" unpushed "the unpushed branch still survives"
    assert_has_branch "$repo" unmerged "the checked-out branch survives"
    assert_eq "HEAD is left where it was" "unmerged" \
        "$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
}

# --- test 4: name filtering is exact ----------------------------------------------

test4() {
    echo "test 4: a branch whose name merely contains the default branch's name is not spared"
    local d="$WORK/t4" repo="$WORK/t4/local"
    fresh "$d"
    setup_branches "$repo"

    run_cleanup "$repo"
    assert_no_branch "$repo" remain-fix "'remain-fix' is cleaned up like any other merged branch"
}

# --- test 5: no "*" reaching git branch ------------------------------------------

test5() {
    echo "test 5: the current-branch marker never reaches git branch as an argument"
    local d="$WORK/t5" repo="$WORK/t5/local"
    fresh "$d"
    setup_branches "$repo"
    # Standing on a branch whose name does not contain the default branch's name is what
    # let the "* branch" line through the old substring filter.
    git -C "$repo" checkout -q unmerged

    run_cleanup "$repo"
    assert_missing "no complaint about a branch named '*'" "branch '*' not found"
    assert_missing "no stray '*' argument reported at all" "'*'"
}

# --- test 6: the checked-out branch is never deleted ------------------------------

test6() {
    echo "test 6: the checked-out branch is never deleted, even when it is merged upstream"
    local d="$WORK/t6" repo="$WORK/t6/local"
    fresh "$d"
    setup_branches "$repo"
    git -C "$repo" checkout -q upstreamed

    run_cleanup "$repo"
    assert_has_branch "$repo" upstreamed "the branch we are standing on stays"
    assert_eq "HEAD is still on it" "upstreamed" "$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
    assert_no_branch "$repo" remain-fix "the other merged branch is still cleaned"
    assert_missing "no error about deleting the current branch" "Cannot delete branch"
}

# --- test 7: detached HEAD, and branches that merely look detached ----------------

test7() {
    echo "test 7: a detached HEAD refuses; a branch named 'detached-...' does not trip it"
    local d="$WORK/t7" repo="$WORK/t7/local"
    fresh "$d"
    setup_branches "$repo"

    git -C "$repo" checkout -q --detach
    run_cleanup "$repo"
    if [ "$ST" -ne 0 ]; then ok "a detached HEAD is refused"; else fail "a detached HEAD is refused (exit was 0)"; fi
    assert_has_branch "$repo" upstreamed "nothing is deleted while detached"

    git -C "$repo" checkout -q main
    git -C "$repo" branch detached-experiment unmerged
    run_cleanup "$repo"
    assert_eq "a branch named 'detached-experiment' does not block the run" "0" "$ST"
    assert_no_branch "$repo" upstreamed "the merged branch is cleaned despite that name existing"
    assert_has_branch "$repo" detached-experiment "and the oddly-named branch itself survives"
}

# --- test 8: no upstream ref means no guessing -----------------------------------

test8() {
    echo "test 8: without origin's default branch locally, it refuses instead of guessing"
    local d="$WORK/t8" repo="$WORK/t8/local"
    fresh "$d"
    setup_branches "$repo"
    git -C "$repo" update-ref -d refs/remotes/origin/main

    run_cleanup "$repo"
    if [ "$ST" -ne 0 ]; then ok "refuses without a remote-tracking ref"; else fail "refuses without a remote-tracking ref (exit was 0)"; fi
    assert_has_branch "$repo" upstreamed "nothing is deleted when upstream is unknown"
    assert_has_branch "$repo" unmerged "nothing at all is deleted"
}

test1
test2
test3
test4
test5
test6
test7
test8

echo
echo "== behaviour -> test mapping =="
echo "1. contained upstream goes, everything else stays ............ test1"
echo "2. an unpushed local merge is not 'merged upstream' ......... test2"
echo "3. the result is independent of the checked-out branch ...... test3"
echo "4. name filtering is exact, not substring .................. test4"
echo "5. the '*' marker never becomes an argument ................ test5"
echo "6. the checked-out branch is never deleted ................. test6"
echo "7. detached HEAD refuses; 'detached-*' names do not ........ test7"
echo "8. no upstream ref -> refuse, delete nothing ............... test8"
echo
echo "$TESTS_RUN assertions, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ]
