#!/bin/bash
#
# Copyright (c) 2026 Karl-Johan Alm
# Distributed under the MIT software license, see the accompanying
# file LICENSE or http://www.opensource.org/licenses/mit-license.php.
#
# Test suite for git-pr. Builds throwaway repos under a temp dir -- a local "remote"
# carrying refs/pull/<n>/head refs, so nothing here needs the network or GitHub -- and
# touches nothing outside that temp dir. Each test names the behaviour it pins; see the
# final summary for the full mapping.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../git-pr"
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

assert_contains() {
    local desc="$1" needle="$2"
    case "$OUT" in
        *"$needle"*) ok "$desc" ;;
        *) fail "$desc (output has no '$needle'; output was: $OUT)" ;;
    esac
}

assert_missing() {
    local desc="$1" needle="$2"
    case "$OUT" in
        *"$needle"*) fail "$desc (output unexpectedly has '$needle'; output was: $OUT)" ;;
        *) ok "$desc" ;;
    esac
}

assert_branch() {
    local repo="$1" desc="$2" expected="$3"
    assert_eq "$desc" "$expected" "$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
}

assert_has_branch() {
    local repo="$1" branch="$2" desc="$3"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        ok "$desc"
    else
        fail "$desc (branch '$branch' is missing)"
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

run_pr() {
    local repo="$1"; shift
    OUT=$( (cd "$repo" && "$SCRIPT" "$@") 2>&1 )
    ST=$?
}

git_q() { git -C "$1" "${@:2}"; }

# A local repo standing in for GitHub: a default branch plus refs/pull/5/head, which is
# what `git pr 5` fetches. A file committed on the default branch only (after the pull ref
# was made) gives the tests a way to block a checkout on purpose.
make_remote() {
    local remote="$1" default="$2"
    git init -q -b "$default" "$remote"
    git -C "$remote" config user.email test@example.com
    git -C "$remote" config user.name test
    echo base > "$remote/f.txt"
    git -C "$remote" add -A
    git -C "$remote" commit -qm base

    git -C "$remote" checkout -q -b pr-source
    echo "pr 5, first commit" > "$remote/p.txt"
    git -C "$remote" add -A
    git -C "$remote" commit -qm "pr 5"
    git -C "$remote" update-ref refs/pull/5/head HEAD

    git -C "$remote" checkout -q "$default"
    git -C "$remote" branch -qD pr-source
    echo "only on the default branch" > "$remote/only-default.txt"
    git -C "$remote" add -A
    git -C "$remote" commit -qm "default-only file"
}

# Adds a commit to the PR, the way a contributor pushing another commit would.
advance_pr() {
    local remote="$1"
    git -C "$remote" checkout -q -b pr-advance refs/pull/5/head
    echo "pr 5, second commit" >> "$remote/p.txt"
    git -C "$remote" add -A
    git -C "$remote" commit -qm "pr 5, more"
    git -C "$remote" update-ref refs/pull/5/head HEAD
    git -C "$remote" checkout -q -
    git -C "$remote" branch -qD pr-advance
}

# A fresh remote+clone pair whose default branch is whatever the test needs.
fresh() {
    local d="$1" default="$2"
    rm -rf "$d"
    mkdir -p "$d"
    make_remote "$d/remote" "$default"
    git clone -q "$d/remote" "$d/local"
    git -C "$d/local" config user.email test@example.com
    git -C "$d/local" config user.name test
}

# --- test 1: fetching a PR ----------------------------------------------------------

test1() {
    echo "test 1: git pr <n> fetches the pull ref and checks it out as pr-<n>"
    local d="$WORK/t1"
    fresh "$d" main

    run_pr "$d/local" 5
    assert_eq "exits 0" "0" "$ST"
    assert_has_branch "$d/local" pr-5 "the PR is checked out as pr-5"
    assert_branch "$d/local" "HEAD is on pr-5" "pr-5"
    if [ -f "$d/local/p.txt" ]; then ok "the PR's content is in the tree"; else fail "the PR's content is in the tree"; fi
}

# --- test 2: re-fetching a PR that has moved on ------------------------------------

test2() {
    echo "test 2: re-running git pr <n> updates the branch when the PR has a new commit"
    local d="$WORK/t2" before after remote_head
    fresh "$d" main

    run_pr "$d/local" 5
    before=$(git -C "$d/local" rev-parse pr-5)
    advance_pr "$d/remote"
    remote_head=$(git -C "$d/remote" rev-parse refs/pull/5/head)

    # Standing on pr-5, as anyone re-running this would be. Refreshing the branch means
    # leaving it first: a fetch into a checked-out branch is refused, and the failure is
    # invisible because git-pr's last command still succeeds.
    run_pr "$d/local" 5
    after=$(git -C "$d/local" rev-parse pr-5)
    assert_eq "exits 0" "0" "$ST"
    if [ "$before" != "$after" ]; then ok "pr-5 actually moved"; else fail "pr-5 actually moved (still at $before)"; fi
    assert_eq "pr-5 is at the PR's new head" "$remote_head" "$after"
    assert_branch "$d/local" "HEAD is on the refreshed pr-5" "pr-5"
}

# --- test 3: cleanup ---------------------------------------------------------------

test3() {
    echo "test 3: git pr cleanup removes every pr- branch, including the one checked out"
    local d="$WORK/t3"
    fresh "$d" main

    run_pr "$d/local" 5
    git -C "$d/local" branch pr-99 pr-5
    assert_branch "$d/local" "standing on pr-5 before the cleanup" "pr-5"

    run_pr "$d/local" cleanup
    assert_eq "exits 0" "0" "$ST"
    assert_no_branch "$d/local" pr-5 "the checked-out pr- branch is deleted"
    assert_no_branch "$d/local" pr-99 "the other pr- branch is deleted"
    assert_branch "$d/local" "HEAD is left on the default branch" "main"
    assert_has_branch "$d/local" main "the default branch is untouched"
}

# --- test 4: the listing is branches, never files in the working directory ----------

test4() {
    echo "test 4: the pr- listing comes from branches, not from a glob over the working directory"
    local d="$WORK/t4"
    fresh "$d" main

    run_pr "$d/local" 5
    # A file whose name starts with pr-. `git branch` marks the current branch with '*',
    # and an unquoted expansion of that '*' globs the working directory instead.
    echo "not a branch" > "$d/local/pr-decoy"
    # Block the checkout too, so the listing is exercised while HEAD is still on pr-5 --
    # the state in which the '*' appears at all.
    echo "colliding untracked content" > "$d/local/only-default.txt"

    run_pr "$d/local"
    assert_eq "exits 0" "0" "$ST"
    assert_contains "the real pr- branch is listed" "pr-5"
    assert_missing "a file named pr-decoy is not listed as a branch" "pr-decoy"
    assert_missing "no other working-directory file is listed" "only-default.txt"
}

# --- test 5: cleanup does not try to delete files either ---------------------------

test5() {
    echo "test 5: cleanup deletes pr- branches only, never a file that merely looks like one"
    local d="$WORK/t5"
    fresh "$d" main

    run_pr "$d/local" 5
    echo "not a branch" > "$d/local/pr-decoy"

    run_pr "$d/local" cleanup
    assert_missing "cleanup does not attempt to delete the file" "pr-decoy"
    assert_no_branch "$d/local" pr-5 "the real pr- branch is deleted"
    if [ -f "$d/local/pr-decoy" ]; then ok "the file is left alone"; else fail "the file is left alone"; fi

    # Again with the checkout blocked, so the loop runs while HEAD is still on a pr- branch
    # -- the only state in which `git branch` emits the "*" that used to glob. Git cannot
    # delete the branch it has checked out, so the point here is only that whatever it
    # complains about is the real branch and never the file.
    fresh "$d" main
    run_pr "$d/local" 5
    echo "not a branch" > "$d/local/pr-decoy"
    echo "colliding untracked content" > "$d/local/only-default.txt"

    run_pr "$d/local" cleanup
    assert_missing "a blocked checkout still does not turn the file into a branch" "pr-decoy"
    assert_contains "the only complaint is about the real, checked-out branch" \
        "Cannot delete branch 'pr-5'"
}

# --- test 6: pr-5 and pr-50 are different branches ---------------------------------

test6() {
    echo "test 6: asking for pr-5 does not act on pr-50"
    local d="$WORK/t6" pr50
    fresh "$d" main

    git -C "$d/local" fetch -q origin pull/5/head:pr-50
    pr50=$(git -C "$d/local" rev-parse pr-50)

    run_pr "$d/local" 5
    assert_eq "exits 0" "0" "$ST"
    assert_missing "no error about a branch that was never there" "not found"
    assert_has_branch "$d/local" pr-50 "pr-50 survives untouched"
    assert_eq "pr-50 still points where it did" "$pr50" "$(git -C "$d/local" rev-parse pr-50)"
    assert_has_branch "$d/local" pr-5 "pr-5 is created"
}

# --- test 7: a master-default repo behaves exactly as before ------------------------

test7() {
    echo "test 7: a repo whose default branch is master still works (no regression)"
    local d="$WORK/t7"
    fresh "$d" master

    run_pr "$d/local" 5
    assert_eq "git pr <n> exits 0" "0" "$ST"
    assert_branch "$d/local" "HEAD is on pr-5" "pr-5"

    run_pr "$d/local"
    assert_contains "the listing finds pr-5" "pr-5"

    run_pr "$d/local" cleanup
    assert_no_branch "$d/local" pr-5 "cleanup removes pr-5"
    assert_branch "$d/local" "HEAD is left on master" "master"
}

# --- test 8: the upstream remote is matched by name, not by substring ---------------

test8() {
    echo "test 8: a remote merely containing 'upstream' in its name is not mistaken for it"
    local d="$WORK/t8"
    fresh "$d" main
    # A remote whose name contains "upstream" but is not it. Fetching from a remote named
    # "upstream" here would fail outright: no such remote exists.
    git -C "$d/local" remote add upstream-fork "$d/remote"

    run_pr "$d/local" 5
    assert_eq "exits 0" "0" "$ST"
    assert_missing "no attempt to fetch from a remote named 'upstream'" \
        "'upstream' does not appear to be a git repository"
    assert_has_branch "$d/local" pr-5 "the PR is fetched from origin"
    assert_branch "$d/local" "HEAD is on pr-5" "pr-5"
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
echo "1. git pr <n> fetches the pull ref as pr-<n> ................. test1"
echo "2. re-running git pr <n> refreshes a moved PR ................ test2"
echo "3. cleanup removes every pr- branch, checked out or not ...... test3"
echo "4. the listing reads branches, not a glob of the cwd ......... test4"
echo "5. cleanup deletes branches only, never look-alike files ..... test5"
echo "6. pr-5 and pr-50 are not confused .......................... test6"
echo "7. a master-default repo is unaffected ...................... test7"
echo "8. 'upstream' is matched by name, not by substring ........... test8"
echo
echo "$TESTS_RUN assertions, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ]
