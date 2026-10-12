#!/bin/bash
#
# Copyright (c) 2026 Karl-Johan Alm
# Distributed under the MIT software license, see the accompanying
# file LICENSE or http://www.opensource.org/licenses/mit-license.php.
#
# Test suite for git-collect. Builds throwaway project roots under a temp dir -- a super-project
# holding a repo's main checkout, and its dispatches as sibling worktrees on task/<slug> -- and
# touches nothing outside it. The operator's merge is 'git merge --no-ff', as the operator does
# it. A fake 'claude' stands in for the agent where a test dispatches with the real git-dispatch.
# Each test names the behaviour it pins -- see the final summary for the full mapping.
#
# Every refusal asserts that nothing changed: refs, the worktree registrations, every checkout's
# HEAD, index and status, every file under the project root, and the task files' bytes.
#
# A failing test also prints a pytest-shaped line at the end ('FAILED <id> - AssertionError: ...',
# or 'ERROR <id> - ...' when git-collect itself died of a bash error), so that 'git mutate' can
# tell an assertion kill from a mutation that merely broke the script.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../git-collect"
DISPATCH="$HERE/../git-dispatch"
WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)

TESTS_RUN=0
TESTS_FAILED=0
SNAP_EXTRA=()
CURRENT=""
declare -A T_FAIL T_ERR
ORDER=()

ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  ok: $1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $1"
    [ -n "${T_FAIL[$CURRENT]+set}" ] || T_FAIL[$CURRENT]=$1
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
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) ok "$desc" ;;
        *) fail "$desc (no '$needle' in '$haystack')" ;;
    esac
}

assert_lacks() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) fail "$desc (unexpected '$needle' in '$haystack')" ;;
        *) ok "$desc" ;;
    esac
}

begin() {
    CURRENT=$1
    ORDER+=("$1")
    echo "$1: $2"
}

# --- fixtures -------------------------------------------------------------------------------

FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'EOF'
#!/bin/bash
echo "cwd=$(pwd -P)" > "$AGENT_LOG"
EOF
chmod +x "$FAKEBIN/claude"
SAFE_PATH="$FAKEBIN:/usr/bin:/bin"

init_repo() {
    git init -q -b "${2:-master}" "$1"
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name test
}

commit_all() {
    (cd "$1" && git add -A && git commit -q -m "$2")
}

# new_project <name> [<initial branch>]: a project root (itself a git repo, ignoring '/*@*/')
# holding the main checkout of 'terea', with context/ and *.log ignored. Sets D, ROOT, MAIN, LOG,
# and RUN_IN (where git-collect runs: the main checkout).
new_project() {
    D="$WORK/$1"
    ROOT="$D/proj"
    MAIN="$ROOT/terea"
    LOG="$D/agent.log"
    RUN_IN=$MAIN
    SNAP_EXTRA=()
    mkdir -p "$ROOT"
    init_repo "$ROOT"
    printf '/*@*/\n' > "$ROOT/.gitignore"
    commit_all "$ROOT" super
    init_repo "$MAIN" "${2:-master}"
    printf 'context/\n*.log\n' > "$MAIN/.gitignore"
    echo one > "$MAIN/f.txt"
    commit_all "$MAIN" init
    mkdir -p "$MAIN/context"
}

# wt_of <slug>: the dispatch's path.
wt_of() { echo "$ROOT/terea@$1"; }

# dispatch_wt <slug> [<start>]: a dispatch's worktree, as git dispatch makes it.
dispatch_wt() {
    git -C "$MAIN" worktree add -q "$(wt_of "$1")" -b "task/$1" "${2:-master}"
}

# work <slug>: the worker's commit on task/<slug>.
work() {
    local wt
    wt=$(wt_of "$1")
    echo "work on $1" > "$wt/$1.txt"
    commit_all "$wt" "work on $1"
}

# merge <slug> [<into>]: the operator's merge, --no-ff, into the main checkout's branch or <into>
# (switching there and back).
merge() {
    local here
    here=$(git -C "$MAIN" symbolic-ref --short HEAD)
    [ -z "${2:-}" ] || git -C "$MAIN" switch -q "$2"
    git -C "$MAIN" merge -q --no-ff -m "merge task/$1" "task/$1"
    [ -z "${2:-}" ] || git -C "$MAIN" switch -q "$here"
}

# A merged, clean, archived dispatch: worked, merged, nothing left in it.
ready() {
    dispatch_wt "$1" "${2:-master}"
    work "$1"
    merge "$1" "${3:-}"
}

# write_task <file> <status> <checkout> [<body line>]: a task header like git dispatch's, and a
# body that quotes a header naming a decoy checkout (or <body line>).
write_task() {
    {
        echo "# TASK: something"
        echo
        echo "**Status: $2**"
        echo "**Author: CO**"
        echo "**Implementer: unassigned**"
        echo "**Implementer Session ID: unassigned**"
        echo "**Checkout: $3**"
        echo
        echo "---"
        echo
        echo '```'
        echo "${4:-**Checkout: decoy@not-this-one**}"
        echo '```'
    } > "$1"
}

# run_collect [args...]: runs in $RUN_IN; sets OUT, ERR, STATUS.
run_collect() {
    (cd "$RUN_IN" && PATH="$SAFE_PATH" "$SCRIPT" "$@") > "$D/out" 2> "$D/err"
    STATUS=$?
    OUT=$(cat "$D/out")
    ERR=$(cat "$D/err")
    local crash
    crash=$(grep -m1 -E 'git-collect: line [0-9]+:' "$D/err")
    if [ -n "$crash" ] && [ -z "${T_ERR[$CURRENT]+set}" ]; then
        T_ERR[$CURRENT]=$crash
    fi
}

# Everything a collect could change: refs, worktree registrations, every checkout's HEAD, index
# and status, every file (and link) under the project root, and the task files' bytes.
snapshot() {
    git -C "$MAIN" for-each-ref --format='%(refname) %(objectname)'
    git -C "$MAIN" worktree list --porcelain
    ls -A "$(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir)/worktrees" 2>/dev/null
    local wt
    for wt in "$MAIN" "$ROOT"/*@* ${SNAP_EXTRA[@]+"${SNAP_EXTRA[@]}"}; do
        [ -d "$wt" ] || continue
        echo "== $wt"
        git -C "$wt" rev-parse HEAD 2>&1
        git -C "$wt" symbolic-ref -q HEAD 2>&1
        git -C "$wt" ls-files --stage 2>&1 | sha1sum
        git -C "$wt" status --porcelain --ignored --untracked-files=all 2>&1
    done
    local x
    for x in "$ROOT" ${SNAP_EXTRA[@]+"${SNAP_EXTRA[@]}"}; do
        [ -d "$x" ] || continue
        echo "== tree $x"
        (cd "$x" && find . -name .git -prune -o -printf '%y %p -> %l\n' | LC_ALL=C sort)
        (cd "$x" && find . -name .git -prune -o -name 'TASK_*' -type f -exec sha1sum {} + | LC_ALL=C sort)
    done
}

# refused <desc> <expected text in stderr> [args...]: the run exits 1, names its cause, and leaves
# the snapshot exactly as it was.
refused() {
    local desc="$1" needle="$2"; shift 2
    local before after
    before=$(snapshot)
    run_collect "$@"
    assert_eq "$desc: exits 1" "1" "$STATUS"
    assert_contains "$desc: names its cause" "$needle" "$ERR"
    after=$(snapshot)
    if [ "$before" = "$after" ]; then
        ok "$desc: nothing changed"
    else
        fail "$desc: nothing changed ($(diff <(echo "$before") <(echo "$after") | head -5 | tr '\n' ' '))"
    fi
}

# skipped <desc> <slug> <expected text>: with no arguments the dispatch is skipped with its reason,
# the run exits 0, and (it being the only dispatch) nothing changes.
skipped() {
    local desc="$1" slug="$2" needle="$3"
    local before after
    before=$(snapshot)
    run_collect
    assert_eq "$desc: exits 0" "0" "$STATUS"
    assert_contains "$desc: a skip line for $slug" "git-collect: skip $slug: " "$OUT"
    assert_contains "$desc: says why" "$needle" "$OUT"
    after=$(snapshot)
    if [ "$before" = "$after" ]; then
        ok "$desc: nothing changed"
    else
        fail "$desc: nothing changed ($(diff <(echo "$before") <(echo "$after") | head -5 | tr '\n' ' '))"
    fi
}

# guarded <desc> <slug> <expected text>: refused by name, and skipped with no arguments.
guarded() {
    refused "$1 (named)" "$3" "$2"
    assert_contains "$1 (named): names the slug" "refused $2: " "$ERR"
    skipped "$1 (no arguments)" "$2" "$3"
}

# collected <desc> <slug>: the worktree, its registration and the branch are all gone.
collected() {
    local desc="$1" slug="$2" wt
    wt=$(wt_of "$slug")
    if [ -e "$wt" ]; then fail "$desc: $wt is gone (it is still there)"; else ok "$desc: $wt is gone"; fi
    assert_lacks "$desc: its registration is gone" "worktree $wt" "$(git -C "$MAIN" worktree list --porcelain)"
    if git -C "$MAIN" show-ref --verify --quiet "refs/heads/task/$slug"; then
        fail "$desc: task/$slug is deleted (it still exists)"
    else
        ok "$desc: task/$slug is deleted"
    fi
}

# kept <desc> <slug>: the worktree (if it had one) and the branch are still there.
kept() {
    local desc="$1" slug="$2"
    if git -C "$MAIN" show-ref --verify --quiet "refs/heads/task/$slug"; then
        ok "$desc: task/$slug is kept"
    else
        fail "$desc: task/$slug is kept (it was deleted)"
    fi
}

# The main checkout's HEAD, branch, index and working tree.
main_state() {
    git -C "$MAIN" rev-parse HEAD
    git -C "$MAIN" symbolic-ref HEAD
    git -C "$MAIN" ls-files --stage | sha1sum
    git -C "$MAIN" status --porcelain --ignored --untracked-files=all
}

# --- test 1: collected ----------------------------------------------------------------------

test1() {
    begin test1 "a merged, clean, archived dispatch: worktree and branch removed, main untouched"
    new_project t1
    ready done
    local wt main_before
    wt=$(wt_of done)
    mkdir -p "$wt/context" "$wt/build"
    echo out > "$wt/test.log"
    echo notes > "$wt/context/notes.txt"
    main_before=$(main_state)

    run_collect
    assert_eq "exits 0" "0" "$STATUS"
    collected "collected" done
    assert_contains "says the worktree went, with its ignored files counted" \
        "git-collect: done: removed $wt (2 ignored file(s) with it)" "$OUT"
    assert_contains "says the branch went" "git-collect: done: deleted task/done (was " "$OUT"
    assert_eq "the main checkout is untouched" "$main_before" "$(main_state)"
    assert_eq "nothing on stderr" "" "$ERR"

    # The same by name.
    ready named
    run_collect named
    assert_eq "named: exits 0" "0" "$STATUS"
    collected "named" named
}

# --- tests 2-9: each guard on its own -------------------------------------------------------

test2() {
    begin test2 "unmerged: skipped with no arguments; named, merged --no-ff and collected"
    new_project t2
    dispatch_wt open
    work open
    local tip
    tip=$(git -C "$MAIN" rev-parse task/open)
    skipped "unmerged, no arguments" open "task/open is not merged into master"
    run_collect open
    assert_eq "named: exits 0" "0" "$STATUS"
    assert_contains "says it merged" "git-collect: open: merged task/open into master (--no-ff; 1 commit(s))" "$OUT"
    assert_eq "master has a merge commit, though a fast-forward was possible" "3" \
        "$(git -C "$MAIN" rev-list --parents -n 1 master | wc -w | tr -d ' ')"
    assert_eq "whose second parent is the task's tip" "$tip" "$(git -C "$MAIN" rev-parse master^2)"
    assert_eq "the merge message names the branch" "Merge branch 'task/open'" "$(git -C "$MAIN" log -1 --format=%s master)"
    assert_eq "the main checkout is clean and on master" "refs/heads/master|" \
        "$(git -C "$MAIN" symbolic-ref HEAD)|$(git -C "$MAIN" status --porcelain)"
    collected "merged and collected" open

    # Already merged by the operator: no second merge.
    dispatch_wt done
    work done
    merge done
    tip=$(git -C "$MAIN" rev-parse master)
    run_collect done
    assert_eq "already merged: exits 0" "0" "$STATUS"
    assert_eq "already merged: master did not move" "$tip" "$(git -C "$MAIN" rev-parse master)"
    collected "already merged" done
}

test3() {
    begin test3 "a change to a tracked file is refused; reverted, it is collected"
    new_project t3
    ready dirty
    echo changed >> "$(wt_of dirty)/f.txt"
    guarded "a tracked change" dirty "uncommitted changes to tracked files (f.txt)"
    git -C "$(wt_of dirty)" checkout -q -- f.txt
    run_collect dirty
    assert_eq "reverted: exits 0" "0" "$STATUS"
    collected "reverted" dirty

    # Staged only, not in the working tree's diff.
    ready staged
    echo new > "$(wt_of staged)/g.txt"
    git -C "$(wt_of staged)" add g.txt
    guarded "a staged file" staged "uncommitted changes to tracked files (g.txt)"
}

test4() {
    begin test4 "an untracked file is refused; removed, it is collected"
    new_project t4
    ready loose
    mkdir -p "$(wt_of loose)/deep"
    echo x > "$(wt_of loose)/deep/scratch.txt"
    guarded "an untracked file" loose "untracked files (deep/scratch.txt)"
    rm -r "$(wt_of loose)/deep"
    run_collect loose
    assert_eq "removed: exits 0" "0" "$STATUS"
    collected "removed" loose
}

test5() {
    begin test5 "a task file in the worktree is refused and survives; archived, it is collected"
    new_project t5
    ready moved
    local wt task sum
    wt=$(wt_of moved)
    task="$wt/context/TASK_moved.md"
    mkdir -p "$wt/context"
    write_task "$task" "Finished" "terea@moved"
    sum=$(sha1sum < "$task")
    guarded "a task file in the worktree" moved "a task file in the worktree ($task)"
    assert_eq "the task file still exists, byte for byte" "$sum" "$(sha1sum < "$task" 2>&1)"

    # A link there is a task file to lose as well (its target may live anywhere).
    mkdir -p "$D/archive"
    mv "$task" "$D/archive/"
    ln -s "$D/archive/TASK_moved.md" "$task"
    guarded "a task link in the worktree" moved "a task file in the worktree ($task)"
    rm "$task"

    run_collect moved
    assert_eq "archived: exits 0" "0" "$STATUS"
    collected "archived" moved
    assert_eq "the archived file is untouched" "$sum" "$(sha1sum < "$D/archive/TASK_moved.md")"
}

test6() {
    begin test6 "a task link in the main checkout leading into the worktree is refused"
    new_project t6
    ready linked
    local wt link
    wt=$(wt_of linked)
    link="$MAIN/context/TASK_linked.md"
    mkdir -p "$wt/context"
    echo body > "$wt/context/moved.md"
    ln -s ../../terea@linked/context/moved.md "$link"
    guarded "a link into the worktree" linked "$link links into it"

    # A link that dangles into the worktree still leads there.
    rm "$link"
    ln -s ../../terea@linked/context/gone.md "$link"
    guarded "a dangling link into the worktree" linked "$link links into it"

    # An absolute link, through a symlinked directory, still leads there.
    rm "$link"
    ln -s "$ROOT" "$D/alias"
    ln -s "$D/alias/terea@linked/context/moved.md" "$link"
    guarded "an absolute link via another path" linked "$link links into it"

    # A link to anywhere else does not block it.
    rm "$link"
    echo elsewhere > "$D/elsewhere.md"
    ln -s "$D/elsewhere.md" "$MAIN/context/TASK_other.md"
    run_collect linked
    assert_eq "with the link gone: exits 0" "0" "$STATUS"
    collected "with the link gone" linked
    assert_eq "the unrelated link is untouched" "$D/elsewhere.md" "$(readlink "$MAIN/context/TASK_other.md")"
}

test7() {
    begin test7 "a task file in the main checkout naming the checkout is refused; archived, collected"
    new_project t7
    ready named
    local task="$MAIN/context/TASK_named.md" sum
    write_task "$task" "Finished" "terea@named"
    sum=$(sha1sum < "$task")
    guarded "a task file naming the checkout" named "$task names this checkout (Checkout: terea@named)"
    assert_eq "the task file is untouched" "$sum" "$(sha1sum < "$task")"

    # Only the header counts: a body quoting the checkout, or another checkout's task, does not.
    write_task "$MAIN/context/TASK_decoy.md" "Pending" "terea@other" "**Checkout: terea@named**"
    mkdir -p "$MAIN/context/archive"
    mv "$task" "$MAIN/context/archive/"
    run_collect named
    assert_eq "archived: exits 0" "0" "$STATUS"
    collected "archived" named
    assert_eq "the archived task file is untouched" "$sum" "$(sha1sum < "$MAIN/context/archive/TASK_named.md")"
}

test8() {
    begin test8 "a locked worktree is refused; unlocked, it is collected"
    new_project t8
    ready locked
    git -C "$MAIN" worktree lock --reason "on a usb stick" "$(wt_of locked)"
    guarded "locked" locked "the worktree is locked"
    git -C "$MAIN" worktree unlock "$(wt_of locked)"
    run_collect locked
    assert_eq "unlocked: exits 0" "0" "$STATUS"
    collected "unlocked" locked
}

test9() {
    begin test9 "the current directory inside the worktree is refused; from outside, collected"
    new_project t9
    ready here
    mkdir -p "$(wt_of here)/sub"
    RUN_IN=$(wt_of here)/sub
    guarded "cwd in a subdirectory" here "the current directory is inside it"
    RUN_IN=$(wt_of here)
    guarded "cwd at its top" here "the current directory is inside it"
    RUN_IN=$MAIN
    run_collect here
    assert_eq "from the main checkout: exits 0" "0" "$STATUS"
    collected "from the main checkout" here
}

# --- test 10: the just-dispatched case ------------------------------------------------------

test10() {
    begin test10 "a dispatch that has just started is refused, whichever way its task file went"
    new_project t10
    local wts="$D/wts"
    mkdir -p "$wts"
    SNAP_EXTRA=("$wts")
    git -C "$MAIN" config dispatch.root "$wts"
    git -C "$MAIN" config dispatch.moveTask true
    write_task "$MAIN/context/TASK_fresh.md" "Pending" "terea@fresh"
    (cd "$D" && PATH="$SAFE_PATH" AGENT_LOG="$LOG" "$DISPATCH" "$MAIN/context/TASK_fresh.md") > /dev/null 2>&1
    local wt="$wts/terea@fresh"
    assert_eq "(setup) git dispatch moved the task into the checkout" "file" \
        "$( [ -f "$wt/context/TASK_fresh.md" ] && [ ! -L "$wt/context/TASK_fresh.md" ] && echo file)"
    assert_eq "(setup) at the default branch's tip" "$(git -C "$MAIN" rev-parse master)" \
        "$(git -C "$MAIN" rev-parse task/fresh)"
    guarded "moved task" fresh "a task file in the worktree ($wt/context/TASK_fresh.md)"
    assert_contains "and the link into it is named" "$MAIN/context/TASK_fresh.md links into it" "$OUT"
    assert_eq "the task file is still in the checkout" "file" \
        "$( [ -f "$wt/context/TASK_fresh.md" ] && echo file)"

    # Without dispatch.moveTask the task stays in the main checkout and names the checkout.
    new_project t10b
    write_task "$MAIN/context/TASK_fresh.md" "Pending" "terea@fresh"
    (cd "$D" && PATH="$SAFE_PATH" AGENT_LOG="$LOG" "$DISPATCH" "$MAIN/context/TASK_fresh.md") > /dev/null 2>&1
    assert_eq "(setup) git dispatch made the worktree" "refs/heads/task/fresh" \
        "$(git -C "$(wt_of fresh)" symbolic-ref HEAD 2>&1)"
    guarded "unmoved task" fresh "$MAIN/context/TASK_fresh.md names this checkout"
}

# --- tests 11-12: merged into the default branch --------------------------------------------

test11() {
    begin test11 "merged means into the default branch, not HEAD: the main checkout on another branch"
    new_project t11
    git -C "$MAIN" switch -q -c feature
    ready intomaster master master
    dispatch_wt intohead master
    work intohead
    merge intohead
    assert_eq "(setup) the main checkout is on feature" "refs/heads/feature" "$(git -C "$MAIN" symbolic-ref HEAD)"
    refused "merged into HEAD only" "task/intohead is not merged into master" intohead
    local main_before
    main_before=$(main_state)
    run_collect intomaster
    assert_eq "merged into master: exits 0" "0" "$STATUS"
    collected "merged into master, not HEAD" intomaster
    assert_eq "the main checkout is untouched" "$main_before" "$(main_state)"
}

test12() {
    begin test12 "with dispatch.defaultBranch set, merged into main alone is refused"
    new_project t12 main
    git -C "$MAIN" branch develop
    git -C "$MAIN" config dispatch.defaultBranch develop
    dispatch_wt dev develop
    work dev
    merge dev
    guarded "merged into main only" dev "task/dev is not merged into develop"
    merge dev develop
    run_collect dev
    assert_eq "merged into develop: exits 0" "0" "$STATUS"
    collected "merged into develop" dev
}

# --- test 13: branches and missing worktrees ------------------------------------------------

test13() {
    begin test13 "a merged branch without a worktree goes, an unmerged one stays; a missing worktree is unregistered"
    new_project t13
    ready old
    git -C "$MAIN" worktree remove "$(wt_of old)"
    dispatch_wt wip
    work wip
    git -C "$MAIN" worktree remove "$(wt_of wip)"
    ready gone
    rm -rf "$(wt_of gone)"
    git -C "$MAIN" worktree add -q "$ROOT/elsewhere" -b other
    rm -rf "$ROOT/elsewhere"

    run_collect
    assert_eq "exits 0" "0" "$STATUS"
    collected "a merged branch with no worktree" old
    kept "an unmerged branch with no worktree" wip
    assert_contains "the unmerged one is reported" "git-collect: skip wip: task/wip is not merged" "$OUT"
    collected "a registered worktree missing on disk" gone
    assert_contains "says the registration went" \
        "git-collect: gone: removed the registration of $(wt_of gone) (missing on disk)" "$OUT"
    assert_contains "another missing worktree keeps its registration" "worktree $ROOT/elsewhere" \
        "$(git -C "$MAIN" worktree list --porcelain)"
    run_collect wip
    assert_eq "the unmerged branch, named: exits 0" "0" "$STATUS"
    assert_contains "the unmerged branch, named: is merged" "git-collect: wip: merged task/wip into master" "$OUT"
    collected "the unmerged branch, named" wip

    # A locked worktree missing on disk is on media that is not mounted: kept.
    ready usb
    git -C "$MAIN" worktree lock "$(wt_of usb)"
    mv "$(wt_of usb)" "$D/unmounted"
    guarded "a locked worktree missing on disk" usb "the worktree is locked"
    mv "$D/unmounted" "$(wt_of usb)"
}

# --- test 14: never touched -----------------------------------------------------------------

test14() {
    begin test14 "a detached worktree, one on another branch, and one at another path are never touched"
    new_project t14
    git -C "$MAIN" worktree add -q --detach "$(wt_of det)" master
    git -C "$MAIN" worktree add -q "$(wt_of foo)" -b other master
    git -C "$MAIN" worktree add -q "$ROOT/elsewhere" -b task/bar master
    git -C "$MAIN" branch task/foo/deep master
    local before
    before=$(snapshot)
    run_collect
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "nothing changed" "$before" "$(snapshot)"
    assert_eq "nothing listed" "git-collect: no dispatches of terea under $ROOT" "$OUT"
    refused "a detached worktree, named" "no dispatch of terea has that slug" det
    refused "a worktree on another branch, named" "no dispatch of terea has that slug" foo
    refused "a task branch at another path, named" "task/bar is checked out at $ROOT/elsewhere" bar
    refused "a slug with its branch prefix" "name the slug alone" task/det
}

# --- tests 15-18: modes ---------------------------------------------------------------------

test15() {
    begin test15 "named slugs are all or nothing"
    new_project t15
    ready good
    ready bad
    echo x > "$(wt_of bad)/scratch.txt"
    refused "one of two refused" "refused bad: untracked files (scratch.txt)" good bad
    assert_lacks "the good one is not refused" "refused good" "$ERR"
    kept "the good one is not collected" good
    refused "an unknown slug beside a good one" "refused nosuch: no dispatch of terea" good nosuch
    kept "the good one is still not collected" good
    dispatch_wt open
    work open
    refused "an unmerged one beside a refused one is not merged" "refused bad: untracked files" open bad
    kept "the unmerged one" open
    run_collect good
    assert_eq "alone: exits 0" "0" "$STATUS"
    collected "alone" good
}

test16() {
    begin test16 "no arguments: the eligible are collected, the rest reported, exit 0"
    new_project t16
    ready a
    ready b
    dispatch_wt open
    work open
    ready dirty
    echo x > "$(wt_of dirty)/new.txt"
    run_collect
    assert_eq "exits 0" "0" "$STATUS"
    collected "eligible a" a
    collected "eligible b" b
    kept "unmerged" open
    kept "dirty" dirty
    assert_contains "the unmerged one is reported" "git-collect: skip open: task/open is not merged into master" "$OUT"
    assert_contains "the dirty one is reported" "git-collect: skip dirty: untracked files (new.txt)" "$OUT"

    # Every reason a dispatch fails is given.
    echo y >> "$(wt_of open)/f.txt"
    run_collect
    assert_contains "both reasons" \
        "git-collect: skip open: task/open is not merged into master; uncommitted changes to tracked files (f.txt)" "$OUT"
}

test17() {
    begin test17 "a dangling task link in the main checkout is reported and left in place"
    new_project t17
    ln -s ../../terea@lost/context/TASK_lost.md "$MAIN/context/TASK_lost.md"
    local before
    before=$(snapshot)
    run_collect
    assert_eq "exits 0" "0" "$STATUS"
    assert_contains "is reported" "git-collect: dangling: $MAIN/context/TASK_lost.md -> ../../terea@lost/context/TASK_lost.md" "$OUT"
    assert_eq "nothing changed" "$before" "$(snapshot)"
    assert_eq "the link is still there" "../../terea@lost/context/TASK_lost.md" "$(readlink "$MAIN/context/TASK_lost.md")"
}

test18() {
    begin test18 "--dry-run prints every step and changes nothing"
    new_project t18
    ready a
    dispatch_wt open
    work open
    ready old
    git -C "$MAIN" worktree remove "$(wt_of old)"
    ready gone
    rm -rf "$(wt_of gone)"
    ln -s ../../terea@lost/context/TASK_lost.md "$MAIN/context/TASK_lost.md"
    local before
    before=$(snapshot)
    run_collect --dry-run
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "nothing changed" "$before" "$(snapshot)"
    assert_contains "a removal" "git-collect: a: would remove $(wt_of a) (0 ignored file(s) with it)" "$OUT"
    assert_contains "a deletion" "git-collect: a: would delete task/a" "$OUT"
    assert_contains "a branch-only deletion" "git-collect: old: would delete task/old" "$OUT"
    assert_contains "a registration" "git-collect: gone: would remove the registration of $(wt_of gone)" "$OUT"
    assert_contains "a skip" "git-collect: skip open: task/open is not merged" "$OUT"
    assert_contains "a dangling link" "git-collect: dangling: $MAIN/context/TASK_lost.md" "$OUT"
    assert_contains "says so" "git-collect: dry run -- nothing changed" "$OUT"

    ready dirty
    echo x > "$(wt_of dirty)/scratch.txt"
    refused "a refusal, dry" "refused dirty: untracked files" --dry-run a dirty
    before=$(snapshot)
    run_collect --dry-run open
    assert_eq "a merge, dry: exits 0" "0" "$STATUS"
    assert_eq "a merge, dry: nothing changed" "$before" "$(snapshot)"
    assert_contains "a merge, dry: says it would" "git-collect: open: would merge task/open into master (--no-ff; 1 commit(s))" "$OUT"
    assert_contains "a merge, dry: and then remove" "git-collect: open: would remove $(wt_of open)" "$OUT"
    before=$(snapshot)
    run_collect --dry-run a
    assert_eq "named, dry: exits 0" "0" "$STATUS"
    assert_eq "named, dry: nothing changed" "$before" "$(snapshot)"
    assert_contains "named, dry: the removal" "git-collect: a: would remove $(wt_of a)" "$OUT"
}

test19() {
    begin test19 "it runs the same from a worktree of the repo as from the main checkout"
    new_project t19
    ready a
    dispatch_wt open
    work open
    git -C "$MAIN" worktree add -q "$ROOT/side" -b side master
    local from_main
    run_collect --dry-run
    from_main=$OUT
    RUN_IN=$ROOT/side
    run_collect --dry-run
    assert_eq "the same dry run from another worktree" "$from_main" "$OUT"
    RUN_IN=$(wt_of open)
    run_collect --dry-run
    assert_eq "from a dispatch, that one dispatch is skipped for the cwd too" \
        "$(sed 's/^\(git-collect: skip open: .*\)$/\1; the current directory is inside it/' <<< "$from_main")" "$OUT"
    RUN_IN=$ROOT/side
    run_collect
    assert_eq "for real: exits 0" "0" "$STATUS"
    collected "from another worktree" a
    kept "the unmerged one" open
    assert_eq "the side worktree is untouched" "refs/heads/side" "$(git -C "$ROOT/side" symbolic-ref HEAD)"
}

# --- test 20: one resolution with git dispatch ----------------------------------------------

# same_as_dispatch <desc>: collect's root and default branch are dispatch's, for a probe task.
same_as_dispatch() {
    local desc="$1" d_root d_base c_root c_base
    write_task "$MAIN/context/TASK_probe.md" "Pending" "terea@probe"
    d_root=$( (cd "$D" && PATH="$SAFE_PATH" AGENT_LOG="$LOG" "$DISPATCH" --dry-run "$MAIN/context/TASK_probe.md") 2>&1)
    rm -f "$MAIN/context/TASK_probe.md"
    d_base=$(sed -n 's/^git-dispatch: worktree: .* (from \(.*\), via \(.*\))$/\1 (from \2)/p' <<< "$d_root")
    d_root=$(sed -n 's/^git-dispatch: root: //p' <<< "$d_root")
    run_collect --dry-run
    c_root=$(sed -n 's/^git-collect: root: //p' <<< "$OUT")
    c_base=$(sed -n 's/^git-collect: default branch: \(.*\)    (from \(.*\))$/\1 (from \2)/p' <<< "$OUT")
    [ -n "$d_root" ] && [ -n "$d_base" ] || fail "$desc: (setup) dispatch's dry run gave a root and a base"
    assert_eq "$desc: the root is dispatch's" "$d_root" "$c_root"
    assert_eq "$desc: the default branch is dispatch's" "$d_base" "$c_base"
}

test20() {
    begin test20 "the root, main checkout and default branch are git dispatch's answers"
    new_project t20
    same_as_dispatch "defaults"
    git -C "$MAIN" branch trunk
    git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
    same_as_dispatch "origin/HEAD"
    git -C "$MAIN" config dispatch.defaultBranch master
    same_as_dispatch "dispatch.defaultBranch"
    mkdir -p "$D/wts"
    git -C "$MAIN" config dispatch.root ../../wts
    same_as_dispatch "a relative dispatch.root"
    assert_contains "(the root is the configured one)" "git-collect: root: $D/wts" "$OUT"

    # dispatch.root moves the dispatches: one there is collected, one beside the checkout is not one.
    git -C "$MAIN" worktree add -q "$D/wts/terea@there" -b task/there master
    git -C "$MAIN" worktree add -q "$(wt_of beside)" -b task/beside master
    SNAP_EXTRA=("$D/wts")
    refused "beside the main checkout, with a root set" "task/beside is checked out at $(wt_of beside)" beside
    run_collect there
    assert_eq "under dispatch.root: exits 0" "0" "$STATUS"
    assert_eq "under dispatch.root: the worktree is gone" "gone" "$( [ -e "$D/wts/terea@there" ] || echo gone)"

    # A submodule of the project root: its checkout comes from core.worktree.
    D="$WORK/t20sub"
    ROOT="$D/proj"; LOG="$D/agent.log"; SNAP_EXTRA=()
    local src="$D/src"
    init_repo "$src"
    printf 'context/\n' > "$src/.gitignore"
    echo one > "$src/f.txt"
    commit_all "$src" init
    init_repo "$ROOT"
    printf '/*@*/\n' > "$ROOT/.gitignore"
    git -C "$ROOT" -c protocol.file.allow=always submodule --quiet add "$src" terea
    commit_all "$ROOT" "add terea"
    MAIN="$ROOT/terea"
    RUN_IN=$MAIN
    git -C "$MAIN" checkout -q master
    git -C "$MAIN" config user.email test@example.com
    git -C "$MAIN" config user.name test
    mkdir -p "$MAIN/context"
    same_as_dispatch "a submodule"
    ready subtask
    RUN_IN=$MAIN
    run_collect subtask
    assert_eq "in a submodule: exits 0" "0" "$STATUS"
    collected "in a submodule" subtask
}

# --- test 21: bad input ---------------------------------------------------------------------

test21() {
    begin test21 "a set GIT_DIR is refused; usage errors exit 2"
    new_project t21
    ready a
    local before
    before=$(snapshot)
    (cd "$MAIN" && GIT_DIR="$ROOT/.git" PATH="$SAFE_PATH" "$SCRIPT") > /dev/null 2> "$D/err"
    assert_eq "GIT_DIR: exits 1" "1" "$?"
    assert_contains "GIT_DIR: says so" "GIT_DIR is set" "$(cat "$D/err")"
    (cd "$MAIN" && GIT_INDEX_FILE="$D/index" PATH="$SAFE_PATH" "$SCRIPT" a) > /dev/null 2> "$D/err"
    assert_eq "GIT_INDEX_FILE: exits 1" "1" "$?"
    assert_eq "nothing changed" "$before" "$(snapshot)"
    run_collect --force a
    assert_eq "an unknown option: exits 2" "2" "$STATUS"
    assert_contains "an unknown option: says so" "unknown option '--force'" "$ERR"
    run_collect a a
    assert_eq "a slug twice: exits 2" "2" "$STATUS"
    assert_eq "nothing changed by usage errors" "$before" "$(snapshot)"
    RUN_IN=$D
    run_collect
    assert_eq "outside a repository: exits 1" "1" "$STATUS"
    assert_contains "outside a repository: says so" "not inside a git repository" "$ERR"
}

# --- test 22: git refuses a removal ---------------------------------------------------------

test22() {
    begin test22 "a removal git refuses is reported, the branch kept, and the run exits 1"
    new_project t22
    ready stuck
    ready fine
    mkdir -p "$(wt_of stuck)/context/ro"
    echo x > "$(wt_of stuck)/context/ro/file"
    chmod 555 "$(wt_of stuck)/context/ro"
    run_collect
    chmod 755 "$(wt_of stuck)/context/ro"
    assert_eq "exits 1" "1" "$STATUS"
    assert_contains "says git refused" "git-collect: stuck: git refused to remove $(wt_of stuck)" "$ERR"
    assert_contains "and keeps the branch" "git-collect: stuck: task/stuck is kept" "$ERR"
    kept "the branch of the failed removal" stuck
    collected "the other one still" fine
}

# --- tests 23-26: the merge -----------------------------------------------------------------

test23() {
    begin test23 "a merge needs the main checkout on the default branch, clean, with no merge under way"
    new_project t23
    dispatch_wt open
    work open
    git -C "$MAIN" switch -q -c feature
    refused "the main checkout on another branch" \
        "task/open is not merged into master, and merging it needs the main checkout ($MAIN) on master, and it is on feature" open
    git -C "$MAIN" switch -q master
    echo changed >> "$MAIN/f.txt"
    refused "a tracked change in the main checkout" "merging it needs no uncommitted change to the main checkout's tracked files (f.txt)" open
    git -C "$MAIN" add f.txt
    refused "a staged change in the main checkout" "merging it needs no uncommitted change to the main checkout's tracked files (f.txt)" open
    git -C "$MAIN" reset -q --hard
    git -C "$MAIN" switch -q -c side
    echo side > "$MAIN/f.txt"
    commit_all "$MAIN" side
    git -C "$MAIN" switch -q master
    echo master > "$MAIN/f.txt"
    commit_all "$MAIN" master
    git -C "$MAIN" merge -q side > /dev/null 2>&1
    refused "a merge under way in the main checkout" "with no merge under way" open
    git -C "$MAIN" merge --abort
    echo scratch > "$MAIN/scratch.txt"
    run_collect open
    assert_eq "an untracked file in the main checkout does not block it: exits 0" "0" "$STATUS"
    collected "with an untracked file in the main checkout" open
    assert_eq "the untracked file is still there" "scratch" "$(cat "$MAIN/scratch.txt")"
}

test24() {
    begin test24 "every guard is checked before the merge: a refused dispatch is never merged"
    new_project t24
    dispatch_wt worked
    work worked
    mkdir -p "$(wt_of worked)/context"
    write_task "$(wt_of worked)/context/TASK_worked.md" "In Progress" "terea@worked"
    refused "a moved task file, unmerged" "a task file in the worktree" worked
    rm "$(wt_of worked)/context/TASK_worked.md"
    write_task "$MAIN/context/TASK_worked.md" "Finished" "terea@worked"
    refused "a task file in the main checkout, unmerged" "names this checkout" worked
    rm "$MAIN/context/TASK_worked.md"
    echo x >> "$(wt_of worked)/f.txt"
    refused "a tracked change, unmerged" "uncommitted changes to tracked files" worked
    git -C "$(wt_of worked)" checkout -q -- f.txt
    git -C "$MAIN" worktree lock "$(wt_of worked)"
    refused "locked, unmerged" "the worktree is locked" worked
    git -C "$MAIN" worktree unlock "$(wt_of worked)"
    RUN_IN=$(wt_of worked)
    refused "the cwd inside, unmerged" "the current directory is inside it" worked
    RUN_IN=$MAIN
    assert_eq "master never moved: it is still the one commit it started with" "1" \
        "$(git -C "$MAIN" rev-list --count master)"
    assert_eq "and the main checkout is clean" "" "$(git -C "$MAIN" status --porcelain)"
}

test25() {
    begin test25 "a conflict is aborted, the main checkout restored, and nothing after it attempted"
    new_project t25
    dispatch_wt first
    work first
    dispatch_wt clash
    echo theirs > "$(wt_of clash)/f.txt"
    commit_all "$(wt_of clash)" "clash"
    dispatch_wt last
    work last
    echo ours > "$MAIN/f.txt"
    commit_all "$MAIN" "ours"
    run_collect first clash last
    assert_eq "exits 1" "1" "$STATUS"
    collected "the one before the conflict" first
    kept "the conflicting one" clash
    assert_eq "its worktree is kept" "refs/heads/task/clash" "$(git -C "$(wt_of clash)" symbolic-ref HEAD 2>&1)"
    kept "the one after it" last
    assert_eq "the one after it is not merged" "no" \
        "$(git -C "$MAIN" merge-base --is-ancestor task/last master && echo yes || echo no)"
    assert_eq "no merge under way" "none" "$(git -C "$MAIN" rev-parse -q --verify MERGE_HEAD || echo none)"
    assert_eq "the main checkout is clean, at the first merge" "|Merge branch 'task/first'" \
        "$(git -C "$MAIN" status --porcelain)|$(git -C "$MAIN" log -1 --format=%s)"
    assert_eq "f.txt is master's" "ours" "$(cat "$MAIN/f.txt")"
    assert_contains "says the merge was aborted" "git-collect: clash: the merge was aborted" "$ERR"
    assert_contains "names what was not attempted" "git-collect: not attempted: last" "$ERR"
}

test26() {
    begin test26 "no arguments: an unmerged dispatch whose task says it is done is listed for review"
    new_project t26
    local wts="$D/wts"
    mkdir -p "$wts"
    SNAP_EXTRA=("$wts")
    git -C "$MAIN" config dispatch.root "$wts"
    git -C "$MAIN" config dispatch.moveTask true
    local s
    for s in fin prog; do
        write_task "$MAIN/context/TASK_$s.md" "Pending" "terea@$s"
        (cd "$D" && PATH="$SAFE_PATH" AGENT_LOG="$LOG" "$DISPATCH" "$MAIN/context/TASK_$s.md") > /dev/null 2>&1
        echo "work" > "$wts/terea@$s/$s.txt"
        commit_all "$wts/terea@$s" "work on $s"
    done
    sed -i '3s/.*/**Status: Finished**/' "$wts/terea@fin/context/TASK_fin.md"
    sed -i '3s/.*/**Status: In Progress**/' "$wts/terea@prog/context/TASK_prog.md"
    git -C "$MAIN" worktree add -q "$wts/terea@ver" -b task/ver master
    echo v > "$wts/terea@ver/v.txt"
    commit_all "$wts/terea@ver" "work on ver"
    write_task "$MAIN/context/TASK_ver.md" "Author Verified" "terea@ver"
    git -C "$MAIN" worktree add -q "$wts/terea@bare" -b task/bare master
    echo b > "$wts/terea@bare/b.txt"
    commit_all "$wts/terea@bare" "work on bare"
    local before
    before=$(snapshot)
    run_collect
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "nothing changed" "$before" "$(snapshot)"
    assert_contains "a Finished task file in the worktree" \
        "git-collect: finished fin: $wts/terea@fin/context/TASK_fin.md says Finished, and task/fin has 1 commit(s) not in master. Review it, then 'git collect fin' merges it" "$OUT"
    assert_contains "says what must hold first" "a task file in the worktree ($wts/terea@fin/context/TASK_fin.md)" "$OUT"
    assert_contains "an Author Verified task file in the main checkout" \
        "git-collect: finished ver: $MAIN/context/TASK_ver.md says Author Verified" "$OUT"
    assert_contains "In Progress is skipped" "git-collect: skip prog: task/prog is not merged into master; a task file" "$OUT"
    assert_lacks "In Progress is not listed as finished" "finished prog" "$OUT"
    assert_contains "no task file is skipped" "git-collect: skip bare: task/bare is not merged into master" "$OUT"
    assert_lacks "no task file is not listed as finished" "finished bare" "$OUT"

    # The operator reviews, archives the task file, and collects it by name.
    mkdir -p "$D/archive"
    mv "$wts/terea@fin/context/TASK_fin.md" "$D/archive/"
    rm "$MAIN/context/TASK_fin.md"
    run_collect fin
    assert_eq "by name: exits 0" "0" "$STATUS"
    assert_contains "by name: merged" "git-collect: fin: merged task/fin into master (--no-ff; 1 commit(s))" "$OUT"
    assert_eq "by name: the worktree is gone" "gone" "$( [ -e "$wts/terea@fin" ] || echo gone)"
}

test27() {
    begin test27 "no arguments: a finished task whose worktree is gone is listed too"
    new_project t27
    local ctx="$MAIN/context"
    # g1: the worktree removed by hand, the branch unmerged.
    dispatch_wt g1; work g1
    git -C "$MAIN" worktree remove "$(wt_of g1)"
    write_task "$ctx/TASK_g1.md" "Finished" "terea@g1"
    # g2: the worktree removed by hand, the branch merged.
    ready g2
    git -C "$MAIN" worktree remove "$(wt_of g2)"
    write_task "$ctx/TASK_g2.md" "Author Verified" "terea@g2"
    # g3: registered, but missing on disk; unmerged.
    dispatch_wt g3; work g3
    rm -rf "$(wt_of g3)"
    write_task "$ctx/TASK_g3.md" "Finished" "terea@g3"
    # g4: neither worktree nor branch left.
    write_task "$ctx/TASK_g4.md" "Finished" "terea@g4"
    # Not listed: not done, another repo's checkout, a branch checked out elsewhere.
    write_task "$ctx/TASK_g5.md" "In Progress" "terea@g5"
    write_task "$ctx/TASK_g6.md" "Finished" "other@g6"
    git -C "$MAIN" worktree add -q "$ROOT/elsewhere" -b task/g7 master
    write_task "$ctx/TASK_g7.md" "Finished" "terea@g7"

    local before
    before=$(snapshot)
    run_collect
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "nothing changed" "$before" "$(snapshot)"
    assert_contains "gone, unmerged" \
        "git-collect: finished g1: $ctx/TASK_g1.md says Finished, its worktree $(wt_of g1) is gone, and task/g1 has 1 commit(s) not in master. Review it, then 'git collect g1' merges it (--no-ff) and collects it, once this holds: $ctx/TASK_g1.md names this checkout" "$OUT"
    assert_contains "gone, merged" \
        "git-collect: finished g2: $ctx/TASK_g2.md says Author Verified, its worktree $(wt_of g2) is gone, and task/g2 is merged into master. Archive the task file; then 'git collect' deletes the branch" "$OUT"
    assert_contains "missing on disk, unmerged" \
        "git-collect: finished g3: $ctx/TASK_g3.md says Finished, its worktree $(wt_of g3) is gone, and task/g3 has 1 commit(s)" "$OUT"
    assert_contains "no worktree, no branch" \
        "git-collect: finished g4: $ctx/TASK_g4.md says Finished, but its worktree $(wt_of g4) and task/g4 are both gone: nothing is left to collect" "$OUT"
    assert_lacks "In Progress is not listed" "g5" "$OUT"
    assert_lacks "another repo's checkout is not listed" "g6" "$OUT"
    assert_lacks "a branch checked out elsewhere is not listed" "g7" "$OUT"

    # Archived, the merged one's branch goes; the one with nothing left is still only listed.
    mkdir -p "$ctx/archive"
    mv "$ctx/TASK_g2.md" "$ctx/archive/"
    run_collect
    assert_eq "archived: exits 0" "0" "$STATUS"
    collected "archived, gone, merged" g2
    assert_eq "the task file with nothing left is untouched" "Finished" "$(sed -n '3s/\*\*Status: \(.*\)\*\*/\1/p' "$ctx/TASK_g4.md")"
}

test28() {
    begin test28 "never --force: a clean worktree holding a submodule is kept, as git refuses it"
    new_project t28
    init_repo "$D/lib"
    git -C "$D/lib" commit -q --allow-empty -m lib
    git -C "$MAIN" -c protocol.file.allow=always submodule --quiet add "$D/lib" lib
    git -C "$MAIN" commit -q -m "add lib"
    ready sub
    git -C "$(wt_of sub)" -c protocol.file.allow=always submodule --quiet update --init
    assert_eq "(setup) the worktree is clean" "" "$(git -C "$(wt_of sub)" status --porcelain)"
    run_collect sub
    assert_eq "exits 1" "1" "$STATUS"
    assert_contains "gives git's refusal" "git-collect: sub: git refused to remove $(wt_of sub)" "$ERR"
    kept "the branch" sub
    assert_eq "the worktree and its submodule's checkout are still there" "there" \
        "$( [ -e "$(wt_of sub)/lib/.git" ] && echo there)"
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
test17
test18
test19
test20
test21
test22
test23
test24
test25
test26
test27
test28

echo
echo "== behaviour -> test mapping =="
echo "1. merged, clean, archived: worktree and branch gone, main untouched ... test1"
echo "2. unmerged: skipped bare; named, merged --no-ff and collected ......... test2"
echo "3. guard: a tracked (or staged) change ................................. test3"
echo "4. guard: an untracked file ............................................ test4"
echo "5. guard: a task file in the worktree, which survives .................. test5"
echo "6. guard: a main-checkout task link into the worktree .................. test6"
echo "7. guard: a main-checkout task file whose header names the checkout .... test7"
echo "8. guard: a locked worktree ............................................ test8"
echo "9. guard: the current directory inside the worktree .................... test9"
echo "10. just dispatched (moved or not) is refused .......................... test10"
echo "11. merged into the default branch, not HEAD ........................... test11"
echo "12. dispatch.defaultBranch is the base, not main ....................... test12"
echo "13. branch-only merged/unmerged; a missing worktree's registration ..... test13"
echo "14. detached, other-branch, other-path worktrees never touched ......... test14"
echo "15. named slugs: all or nothing, no merge beside a refusal ............. test15"
echo "16. no arguments: collect the eligible, report the rest, exit 0 ........ test16"
echo "17. a dangling task link is reported and left .......................... test17"
echo "18. --dry-run prints everything, changes nothing ....................... test18"
echo "19. the same from any worktree of the repo ............................. test19"
echo "20. root, main checkout, default branch: dispatch's answers ............ test20"
echo "21. GIT_DIR refused; usage errors exit 2 ............................... test21"
echo "22. a removal git refuses: reported, branch kept, exit 1 ............... test22"
echo "23. a merge needs main on the default branch, clean, no merge going .... test23"
echo "24. every guard is checked before the merge ............................ test24"
echo "25. a conflict is aborted; nothing after it is attempted ............... test25"
echo "26. no arguments: unmerged Finished/Author Verified listed for review ... test26"
echo "27. no arguments: a finished task whose worktree is gone is listed ..... test27"
echo "28. never --force: a worktree holding a submodule is kept .............. test28"
echo
TESTS_ERRORED=0
for t in "${ORDER[@]}"; do
    if [ -n "${T_ERR[$t]+set}" ]; then
        TESTS_ERRORED=$((TESTS_ERRORED + 1))
        echo "ERROR tests/test-git-collect.sh::$t - BashError: ${T_ERR[$t]}"
    elif [ -n "${T_FAIL[$t]+set}" ]; then
        echo "FAILED tests/test-git-collect.sh::$t - AssertionError: ${T_FAIL[$t]}"
    fi
done
# One line in pytest's words, which is how 'git mutate' counts what ran: a suite that executed
# nothing must not read as a suite that stayed green.
tests_red=0
for t in "${ORDER[@]}"; do
    [ -n "${T_ERR[$t]+set}" ] || [ -n "${T_FAIL[$t]+set}" ] && tests_red=$((tests_red + 1))
done
echo "$((${#ORDER[@]} - tests_red)) passed, $tests_red failed ($TESTS_RUN assertions checked, $TESTS_FAILED of them unmet)"
[ "$TESTS_FAILED" -eq 0 ] && [ "$TESTS_ERRORED" -eq 0 ]
