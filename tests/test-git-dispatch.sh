#!/bin/bash
#
# Copyright (c) 2026 Karl-Johan Alm
# Distributed under the MIT software license, see the accompanying
# file LICENSE or http://www.opensource.org/licenses/mit-license.php.
#
# Test suite for git-dispatch. Builds throwaway project roots under a temp dir -- a super-project
# holding a repo's main checkout, and sibling worktrees -- and puts fake 'claude', 'codex',
# 'omp' and 'agent' (cursor's program) first on a PATH that holds no real one. Each fake records
# its cwd and argv to a file and exits. No test starts a real agent, and nothing outside the temp
# dir is touched. Each test names
# the behaviour it pins -- see the final summary for the full mapping.
#
# A failing test also prints a pytest-shaped line at the end ('FAILED <id> - AssertionError: ...',
# or 'ERROR <id> - ...' when git-dispatch itself died of a bash error), so that 'git mutate' can
# tell an assertion kill from a mutation that merely broke the script.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../git-dispatch"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
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

begin() {
    CURRENT=$1
    ORDER+=("$1")
    echo "$1: $2"
}

# --- fixtures -------------------------------------------------------------------------------

FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
for agent in claude codex omp agent; do
    cat > "$FAKEBIN/$agent" <<'EOF'
#!/bin/bash
{
    echo "cwd=$(pwd -P)"
    echo "argv0=$(basename "$0")"
    for a in "$@"; do echo "arg=$a"; done
} > "$AGENT_LOG"
EOF
    chmod +x "$FAKEBIN/$agent"
done
SAFE_PATH="$FAKEBIN:/usr/bin:/bin"

init_repo() {
    git init -q -b master "$1"
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name test
}

commit_all() {
    (cd "$1" && git add -A && git commit -q -m "$2")
}

# A project root (itself a git repo, ignoring '/*@*/') holding the main checkout of 'terea' on
# master, with context/ ignored. Sets D, ROOT, MAIN, LOG.
new_project() {
    D="$WORK/$1"
    ROOT="$D/proj"
    MAIN="$ROOT/terea"
    LOG="$D/agent.log"
    SNAP_EXTRA=()
    mkdir -p "$ROOT"
    init_repo "$ROOT"
    printf '/*@*/\n' > "$ROOT/.gitignore"
    commit_all "$ROOT" super
    init_repo "$MAIN"
    printf 'context/\n' > "$MAIN/.gitignore"
    echo one > "$MAIN/f.txt"
    commit_all "$MAIN" init
    mkdir -p "$MAIN/context"
}

# write_task <file> <status> <implementer> <session id> <checkout, or '-'> [<harness, or '-'>]
# '-' leaves the line out; the Harness line, when given, follows Implementer (line 6). The body
# quotes a decoy header, as a real task file describing the format does.
write_task() {
    local file="$1" status="$2" impl="$3" sid="$4" co="$5" harness="${6--}"
    {
        echo "# TASK: something"
        echo
        echo "**Status: $status**"
        echo "**Author: CO**"
        echo "**Implementer: $impl**"
        [ "$harness" = "-" ] || echo "**Harness: $harness**"
        echo "**Implementer Session ID: $sid**"
        echo "**Implementation commit: unassigned**"
        [ "$co" = "-" ] || echo "**Checkout: $co**"
        echo
        echo "---"
        echo
        echo '```'
        echo "**Status: Pending**"
        echo "**Checkout: decoy@not-this-one**"
        echo '```'
    } > "$file"
}

# run_dispatch [args...]: runs from $D (outside every checkout); sets OUT, ERR, STATUS.
run_dispatch() {
    (cd "$D" && PATH="$SAFE_PATH" AGENT_LOG="$LOG" "$SCRIPT" "$@") > "$D/out" 2> "$D/err"
    STATUS=$?
    OUT=$(cat "$D/out")
    ERR=$(cat "$D/err")
    local crash
    crash=$(grep -m1 -E 'git-dispatch: line [0-9]+:' "$D/err")
    if [ -n "$crash" ] && [ -z "${T_ERR[$CURRENT]+set}" ]; then
        T_ERR[$CURRENT]=$crash
    fi
}

agent_cwd() {
    [ -f "$LOG" ] && sed -n 's/^cwd=//p' "$LOG"
}

# The agent's argv joined with '|', or '(not run)'.
agent_argv() {
    [ -f "$LOG" ] || { echo "(not run)"; return; }
    local out="" l
    while IFS= read -r l; do
        case "$l" in argv0=*|arg=*) out+="${out:+|}${l#*=}" ;; esac
    done < "$LOG"
    echo "$out"
}

# Everything a dispatch could change: refs, worktrees, every checkout's HEAD and status, the files
# under the project root, the task files' bytes, and whether an agent ran.
snapshot() {
    git -C "$MAIN" for-each-ref --format='%(refname) %(objectname)'
    git -C "$MAIN" worktree list --porcelain
    local wt
    for wt in "$MAIN" "$ROOT"/*@*; do
        [ -d "$wt" ] || continue
        echo "== $wt"
        git -C "$wt" rev-parse HEAD 2>&1
        git -C "$wt" symbolic-ref -q HEAD 2>&1
        git -C "$wt" status --porcelain --ignored --untracked-files=all 2>&1
    done
    git -C "$ROOT" status --porcelain --ignored --untracked-files=all
    (cd "$ROOT" && find . -name .git -prune -o -print | LC_ALL=C sort)
    (cd "$ROOT" && find . -name 'TASK_*' -type f -exec sha1sum {} + | LC_ALL=C sort)
    # Directories outside the project root a test also watches (a dispatch.root, the main
    # checkout's context/): each entry's type and link target, and every task file's bytes.
    local x
    for x in ${SNAP_EXTRA[@]+"${SNAP_EXTRA[@]}"}; do
        echo "== extra $x"
        (cd "$x" && find . -name .git -prune -o -printf '%y %p -> %l\n' | LC_ALL=C sort)
        (cd "$x" && find . -name .git -prune -o -name 'TASK_*' -type f -exec sha1sum {} + | LC_ALL=C sort)
    done
    [ -e "$LOG" ] && echo "AN AGENT RAN: $(agent_argv)"
    true
}

# refused <desc> <expected text in stderr> [args...]: the run exits non-zero, names its cause, and
# leaves the snapshot exactly as it was.
refused() {
    local desc="$1" needle="$2"; shift 2
    local before after
    before=$(snapshot)
    run_dispatch "$@"
    if [ "$STATUS" -ne 0 ]; then ok "$desc: exits non-zero"; else fail "$desc: exits non-zero (got 0)"; fi
    assert_contains "$desc: names its cause" "$needle" "$ERR"
    after=$(snapshot)
    if [ "$before" = "$after" ]; then
        ok "$desc: nothing changed"
    else
        fail "$desc: nothing changed ($(diff <(echo "$before") <(echo "$after") | head -5 | tr '\n' ' '))"
    fi
    rm -f "$LOG"
}

ID1="82ea4726-1c2b-4d5e-9f00-0123456789ab"
ID2="0b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3"

# --- test 1: a new task ---------------------------------------------------------------------

test1() {
    begin test1 "a new task: worktree on task/<slug> from the default branch, claude started in the project root"
    new_project t1
    local task="$MAIN/context/TASK_new_thing.md" sum main_before
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@new-thing"
    sum=$(sha1sum < "$task")
    main_before=$(git -C "$MAIN" rev-parse HEAD; git -C "$MAIN" symbolic-ref HEAD; git -C "$MAIN" status --porcelain --ignored)

    run_dispatch "$task"
    assert_eq "exits with the agent's status" "0" "$STATUS"
    assert_eq "the worktree is on task/new-thing" "refs/heads/task/new-thing" \
        "$(git -C "$ROOT/terea@new-thing" symbolic-ref HEAD 2>&1)"
    assert_eq "the worktree starts at master" "$(git -C "$MAIN" rev-parse master)" \
        "$(git -C "$ROOT/terea@new-thing" rev-parse HEAD 2>&1)"
    assert_eq "claude starts in the project root" "$ROOT" "$(agent_cwd)"
    assert_eq "claude gets 'Task: <repo>/context/TASK_<name>.md'" \
        "claude|--effort|high|Task: terea/context/TASK_new_thing.md" "$(agent_argv)"
    assert_eq "the task file is untouched" "$sum" "$(sha1sum < "$task")"
    assert_eq "the main checkout is untouched" "$main_before" \
        "$(git -C "$MAIN" rev-parse HEAD; git -C "$MAIN" symbolic-ref HEAD; git -C "$MAIN" status --porcelain --ignored)"
}

# --- test 2: a returned task ----------------------------------------------------------------

test2() {
    begin test2 "a Returned task with a Claude implementer: worktree reused untouched, claude --resume in the root"
    new_project t2
    local task="$MAIN/context/TASK_back.md" wt="$ROOT/terea@back" head sum
    git -C "$MAIN" worktree add -q "$wt" -b task/back master
    echo work > "$wt/g.txt"
    commit_all "$wt" "worker's commit"
    echo dirty >> "$wt/f.txt"
    echo scratch > "$wt/untracked.txt"
    head=$(git -C "$wt" rev-parse HEAD)
    local state_before
    state_before=$(git -C "$wt" status --porcelain --untracked-files=all; cat "$wt/f.txt")
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@back" claude-code
    sum=$(sha1sum < "$task")

    run_dispatch "$task"
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "the worktree's HEAD is where the worker left it" "$head" "$(git -C "$wt" rev-parse HEAD)"
    assert_eq "its uncommitted work is untouched" "$state_before" \
        "$(git -C "$wt" status --porcelain --untracked-files=all; cat "$wt/f.txt")"
    assert_eq "one worktree besides main, still" "2" "$(git -C "$MAIN" worktree list | wc -l | tr -d ' ')"
    assert_eq "claude resumes in the project root" "$ROOT" "$(agent_cwd)"
    assert_eq "claude --resume <id> with the follow-up message" \
        "claude|--effort|high|--resume|$ID1|Follow-up task: terea/context/TASK_back.md" "$(agent_argv)"
    assert_eq "the task file is untouched" "$sum" "$(sha1sum < "$task")"
}

# --- test 3: a routed follow-up -------------------------------------------------------------

test3() {
    begin test3 "a Pending task routed to an existing worker, new slug: new worktree, resume in the root"
    new_project t3
    local old="$ROOT/terea@first" task="$MAIN/context/TASK_second.md" old_head
    git -C "$MAIN" worktree add -q "$old" -b task/first master
    echo first > "$old/h.txt"
    commit_all "$old" "first task"
    old_head=$(git -C "$old" rev-parse HEAD)
    echo more > "$MAIN/f.txt"
    commit_all "$MAIN" "master moved on"
    write_task "$task" "Pending" "Claude Opus 5.5" "$ID1" "terea@second" claude-code

    run_dispatch "$task"
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "a new worktree on task/second" "refs/heads/task/second" \
        "$(git -C "$ROOT/terea@second" symbolic-ref HEAD 2>&1)"
    assert_eq "... from master as it is now" "$(git -C "$MAIN" rev-parse master)" \
        "$(git -C "$ROOT/terea@second" rev-parse HEAD 2>&1)"
    assert_eq "the old worktree is untouched" "$old_head refs/heads/task/first" \
        "$(git -C "$old" rev-parse HEAD) $(git -C "$old" symbolic-ref HEAD)"
    assert_eq "the resume is still in the project root" "$ROOT" "$(agent_cwd)"
    assert_eq "claude --resume <id>, follow-up message" \
        "claude|--effort|high|--resume|$ID1|Follow-up task: terea/context/TASK_second.md" "$(agent_argv)"
}

# --- test 4: codex --------------------------------------------------------------------------

test4() {
    begin test4 "Harness: codex resumes through 'codex resume <id>'; --agent codex or a Harness starts a new one"
    new_project t4
    local task="$MAIN/context/TASK_cx.md"
    write_task "$task" "Returned" "gpt-6-astra" "$ID2" "terea@cx" codex
    run_dispatch "$task"
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "codex resume -C <root> <id> with the follow-up message" \
        "codex|resume|-c|model_reasoning_effort=\"high\"|-C|$ROOT|$ID2|Follow-up task: terea/context/TASK_cx.md" "$(agent_argv)"
    assert_eq "codex resumes in the project root" "$ROOT" "$(agent_cwd)"
    rm -f "$LOG"

    task="$MAIN/context/TASK_cx_new.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@cx-new"
    run_dispatch --agent codex "$task"
    assert_eq "--agent codex, no session: codex 'Task: ...'" \
        "codex|-c|model_reasoning_effort=\"high\"|Task: terea/context/TASK_cx_new.md" "$(agent_argv)"
    assert_eq "... in the project root" "$ROOT" "$(agent_cwd)"
    rm -f "$LOG"

    task="$MAIN/context/TASK_cx_harness.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@cx-harness" codex
    run_dispatch "$task"
    assert_eq "Harness: codex, no session: codex 'Task: ...'" \
        "codex|-c|model_reasoning_effort=\"high\"|Task: terea/context/TASK_cx_harness.md" "$(agent_argv)"
    rm -f "$LOG"

    task="$MAIN/context/TASK_cx_named.md"
    write_task "$task" "Pending" "gpt-6-astra (Codex)" "unassigned" "terea@cx-named"
    run_dispatch "$task"
    assert_eq "a new session with no Harness is claude, whatever the Implementer says" \
        "claude|--effort|high|Task: terea/context/TASK_cx_named.md" "$(agent_argv)"
    rm -f "$LOG"
}

# --- test 5: the Harness line decides the program -------------------------------------------

test5() {
    begin test5 "a session resumes with the program its Harness names; the model name is never read"
    new_project t5
    local task="$MAIN/context/TASK_who.md"
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@who" codex
    run_dispatch "$task"
    assert_eq "Implementer 'Claude Opus 5.5' + Harness codex: codex" \
        "codex|resume|-c|model_reasoning_effort=\"high\"|-C|$ROOT|$ID1|Follow-up task: terea/context/TASK_who.md" \
        "$(agent_argv)"
    rm -f "$LOG"
    write_task "$task" "Returned" "gpt-6-astra (Codex)" "$ID1" "terea@who" claude-code
    run_dispatch "$task"
    assert_eq "Implementer naming Codex + Harness claude-code: claude" \
        "claude|--effort|high|--resume|$ID1|Follow-up task: terea/context/TASK_who.md" "$(agent_argv)"
    rm -f "$LOG"

    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@who"
    refused "a session with no Harness line" "add '**Harness: claude-code**', '**Harness: codex**' or '**Harness: cursor**'" "$task"
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@who" unassigned
    refused "a session with Harness unassigned" "no program to resume it with" "$task"
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@who" agy
    refused "Harness agy" "line 6: Harness 'agy' cannot be resumed from the command line; resume it in agy" "$task"
    refused "Harness agy, even with --agent" "Harness 'agy' cannot be resumed" --agent claude "$task"
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@who" claude
    refused "an alias is not a Harness" "Harness 'claude' cannot be resumed" "$task"
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@who" ""
    refused "an empty Harness" "line 6: empty Harness" "$task"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@who" agy
    refused "a new session whose Harness is agy" "Harness 'agy' is not a program git dispatch starts" "$task"

    write_task "$task" "Returned" "Gemini 4 Ultra" "$ID1" "terea@who"
    run_dispatch --agent claude "$task"
    assert_eq "no Harness: --agent claude resumes it" \
        "claude|--effort|high|--resume|$ID1|Follow-up task: terea/context/TASK_who.md" "$(agent_argv)"
    rm -f "$LOG"
    write_task "$task" "Returned" "Gemini 4 Ultra" "$ID1" "terea@who" unassigned
    run_dispatch --agent codex "$task"
    assert_eq "Harness unassigned: --agent codex resumes it" \
        "codex|resume|-c|model_reasoning_effort=\"high\"|-C|$ROOT|$ID1|Follow-up task: terea/context/TASK_who.md" \
        "$(agent_argv)"
    rm -f "$LOG"

    local t2="$MAIN/context/TASK_mismatch.md"
    write_task "$t2" "Returned" "Claude Opus 5.5" "$ID1" "terea@mismatch" claude-code
    refused "--agent contradicting the Harness" "Harness is 'claude-code'; --agent codex contradicts it" --agent codex "$t2"
    write_task "$t2" "Pending" "unassigned" "unassigned" "terea@mismatch" codex
    refused "... on a new session too" "Harness is 'codex'; --agent claude contradicts it" --agent claude "$t2"
    write_task "$t2" "Returned" "Claude Opus 5.5" "$ID1" "terea@mismatch" cursor
    refused "... and cursor against another agent" "Harness is 'cursor'; --agent claude contradicts it" --agent claude "$t2"
}

# --- test 6: --cwd --------------------------------------------------------------------------

test6() {
    begin test6 "--cwd moves the agent's working directory, and nothing else"
    new_project t6
    local task="$MAIN/context/TASK_old.md"
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@old" claude-code
    run_dispatch --cwd "$MAIN" "$task"
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "the agent runs in DIR" "$MAIN" "$(agent_cwd)"
    assert_eq "the worktree is still <root>/<repo>@<slug>" "refs/heads/task/old" \
        "$(git -C "$ROOT/terea@old" symbolic-ref HEAD 2>&1)"
    assert_eq "the message names the task file from DIR" \
        "claude|--effort|high|--resume|$ID1|Follow-up task: context/TASK_old.md" "$(agent_argv)"
    rm -f "$LOG"

    mkdir -p "$D/elsewhere"
    run_dispatch --cwd "$D/elsewhere" "$task"
    assert_eq "outside the task file's tree: runs there" "$D/elsewhere" "$(agent_cwd)"
    assert_eq "... and names the task file absolutely" \
        "claude|--effort|high|--resume|$ID1|Follow-up task: $MAIN/context/TASK_old.md" "$(agent_argv)"
    rm -f "$LOG"

    refused "--cwd naming no directory" "no such directory" --cwd "$D/nope" "$task"
}

# --- test 7: statuses -----------------------------------------------------------------------

test7() {
    begin test7 "only Pending and Returned are dispatched; every other status is refused"
    new_project t7
    local task="$MAIN/context/TASK_st.md" s
    for s in "Proposal" "In Progress" "Finished" "Author Verified" "Blocked" "Closed"; do
        write_task "$task" "$s" "unassigned" "unassigned" "terea@st"
        refused "status '$s'" "line 3: status is '$s'" "$task"
    done
    write_task "$task" "Pendingg" "unassigned" "unassigned" "terea@st"
    refused "an unknown status" "unknown status 'Pendingg'" "$task"

    { echo "# TASK: x"; echo; echo "**Author: CO**"; echo "**Status: Pending**";
      echo "**Implementer: unassigned**"; echo "**Implementer Session ID: unassigned**";
      echo "**Checkout: terea@st**"; } > "$task"
    refused "a status that is not on line 3" "line 3 is not the status" "$task"
}

# --- test 8: the Checkout line --------------------------------------------------------------

test8() {
    begin test8 "a missing or malformed Checkout line is refused"
    new_project t8
    local task="$MAIN/context/TASK_co.md" co
    write_task "$task" "Pending" "unassigned" "unassigned" "-"
    refused "no Checkout line (the body's decoy does not count)" "no '**Checkout: ...**' line" "$task"
    for co in "terea" "terea@" "@slug" "terea@a/b" "terea@a..b" "ter/ea@x" "terea@x@y" "terea@-x"; do
        write_task "$task" "Pending" "unassigned" "unassigned" "$co"
        refused "Checkout '$co'" "malformed Checkout '$co'" "$task"
    done
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@one"
    sed -i '8a **Checkout: terea@two**' "$task"
    refused "two Checkout lines" "line 9: a second 'Checkout:' line" "$task"
}

# --- test 9: repo mismatch ------------------------------------------------------------------

test9() {
    begin test9 "a Checkout naming another repo than the one the task file sits in is refused"
    new_project t9
    init_repo "$ROOT/autorp"
    echo a > "$ROOT/autorp/a.txt"
    commit_all "$ROOT/autorp" init
    local task="$MAIN/context/TASK_mm.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "autorp@mm"
    refused "Checkout autorp@ in terea's task" "Checkout names repo 'autorp'" "$task"
    assert_eq "no autorp worktree either" "1" "$(git -C "$ROOT/autorp" worktree list | wc -l | tr -d ' ')"
}

# --- test 10: the checkout's state ----------------------------------------------------------

test10() {
    begin test10 "a branch without its worktree, or a worktree that is not the task's, is refused"
    new_project t10
    local task="$MAIN/context/TASK_br.md"
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@br" claude-code
    git -C "$MAIN" branch task/br master
    refused "task/br exists, terea@br does not" "branch task/br exists but its worktree $ROOT/terea@br does not" "$task"

    git -C "$MAIN" worktree add -q "$ROOT/elsewhere" task/br
    refused "task/br checked out somewhere else" "checked out at $ROOT/elsewhere" "$task"

    write_task "$task" "Pending" "unassigned" "unassigned" "terea@plain"
    mkdir -p "$ROOT/terea@plain"
    refused "a directory at the worktree path that is no worktree" "not a worktree of" "$task"

    write_task "$task" "Pending" "unassigned" "unassigned" "terea@wrong"
    git -C "$MAIN" worktree add -q "$ROOT/terea@wrong" -b other master
    refused "the worktree on another branch" "is on other, not task/wrong" "$task"
    git -C "$ROOT/terea@wrong" checkout -q --detach
    refused "the worktree on a detached HEAD" "is on a detached HEAD" "$task"

    write_task "$task" "Pending" "unassigned" "unassigned" "terea@gone"
    git -C "$MAIN" worktree add -q "$ROOT/terea@gone" -b task/gone master
    rm -rf "$ROOT/terea@gone"
    refused "a registered worktree missing on disk" "missing on disk" "$task"
}

# --- test 11: --dry-run ---------------------------------------------------------------------

test11() {
    begin test11 "--dry-run changes nothing and prints the argv and cwd a real run execs"
    new_project t11
    local task="$MAIN/context/TASK_dry.md" before dry_out
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@dry"
    before=$(snapshot)
    run_dispatch --dry-run "$task"
    dry_out=$OUT
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "nothing changed, no agent ran" "$before" "$(snapshot)"
    assert_contains "prints the worktree command" \
        "worktree: git -C $MAIN worktree add $ROOT/terea@dry -b task/dry master" "$dry_out"
    assert_contains "says it changed nothing" "dry run -- nothing changed" "$dry_out"

    run_dispatch "$task"
    local exec_line cwd_line
    exec_line=$(printf '%s\n' "$dry_out" | sed -n 's/^git-dispatch: exec: //p')
    cwd_line=$(printf '%s\n' "$dry_out" | sed -n 's/^git-dispatch: cwd: //p')
    local -a real=()
    mapfile -t real < <(sed -n 's/^argv0=//p; s/^arg=//p' "$LOG")
    assert_eq "the printed argv is the one the real run execs" "$(printf '%q ' "${real[@]}")" "$exec_line "
    assert_eq "the printed cwd is the one it runs in" "$(agent_cwd)" "$cwd_line"
    rm -f "$LOG"

    local t2="$MAIN/context/TASK_dry2.md"
    write_task "$t2" "Returned" "gpt-6-astra" "$ID2" "terea@dry" codex
    before=$(snapshot)
    run_dispatch --dry-run --cwd "$MAIN" "$t2"
    assert_eq "a dry resume changes nothing" "$before" "$(snapshot)"
    assert_contains "... prints the reuse" "worktree: reuse $ROOT/terea@dry (task/dry) as it is" "$OUT"
    assert_contains "... and the exact argv" \
        "exec: $(printf '%q ' codex resume -c 'model_reasoning_effort="high"' -C "$MAIN" "$ID2" "Follow-up task: context/TASK_dry2.md" | sed 's/ $//')" "$OUT"
    assert_contains "... and the cwd" "cwd: $MAIN" "$OUT"
}

# --- test 12: the default branch ------------------------------------------------------------

test12() {
    begin test12 "a new worktree starts from the default branch as it stands locally"
    new_project t12
    local task="$MAIN/context/TASK_db.md"

    git -C "$MAIN" checkout -q -b side
    echo side > "$MAIN/side.txt"
    commit_all "$MAIN" "side work"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@db"
    run_dispatch "$task"
    assert_eq "not from the main checkout's current branch" "$(git -C "$MAIN" rev-parse master)" \
        "$(git -C "$ROOT/terea@db" rev-parse HEAD 2>&1)"
    rm -f "$LOG"

    # origin/HEAD names 'trunk'; the local trunk is ahead of origin's.
    local up="$D/upstream"
    init_repo "$up"
    printf 'context/\n' > "$up/.gitignore"
    echo u > "$up/u.txt"
    commit_all "$up" up
    git -C "$up" branch -q -m master trunk
    git -C "$MAIN" remote add origin "$up"
    git -C "$MAIN" fetch -q origin
    git -C "$MAIN" remote set-head origin trunk
    git -C "$MAIN" branch -q trunk origin/trunk
    git -C "$MAIN" checkout -q trunk
    echo local > "$MAIN/local.txt"
    commit_all "$MAIN" "local trunk ahead"
    git -C "$MAIN" checkout -q side
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@db2"
    run_dispatch "$task"
    assert_eq "origin/HEAD names the branch; the local one is used" "$(git -C "$MAIN" rev-parse trunk)" \
        "$(git -C "$ROOT/terea@db2" rev-parse HEAD 2>&1)"
    rm -f "$LOG"

    git -C "$MAIN" branch -q dev master
    git -C "$MAIN" config dispatch.defaultBranch dev
    echo dev > "$MAIN/side.txt"
    commit_all "$MAIN" "more side work"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@db3"
    run_dispatch "$task"
    assert_eq "dispatch.defaultBranch wins" "$(git -C "$MAIN" rev-parse dev)" \
        "$(git -C "$ROOT/terea@db3" rev-parse HEAD 2>&1)"
    rm -f "$LOG"

    git -C "$MAIN" config dispatch.defaultBranch nosuch
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@db4"
    refused "a configured default branch that does not exist" "'nosuch'" "$task"

    new_project t12b
    task="$MAIN/context/TASK_db.md"
    git -C "$MAIN" branch -q main master
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@db"
    refused "both main and master, no origin/HEAD" "cannot tell terea's default branch" "$task"
    git -C "$MAIN" branch -q -m master mainline
    git -C "$MAIN" checkout -q mainline
    git -C "$MAIN" branch -q -D main
    refused "neither main nor master" "neither main nor master exists" "$task"
}

# --- test 13: where the task file is --------------------------------------------------------

test13() {
    begin test13 "the task file resolves to the main checkout's context/, through any checkout"
    new_project t13
    local old="$ROOT/terea@old" task
    git -C "$MAIN" worktree add -q "$old" -b task/old master
    ln -s ../terea/context "$old/context"
    task="$MAIN/context/TASK_via.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@via"
    run_dispatch "$old/context/TASK_via.md"
    assert_eq "given through a worktree: dispatched" "0" "$STATUS"
    assert_eq "... the message names it in the main checkout" \
        "claude|--effort|high|Task: terea/context/TASK_via.md" "$(agent_argv)"
    assert_eq "... and the worktree is the task's own" "refs/heads/task/via" \
        "$(git -C "$ROOT/terea@via" symbolic-ref HEAD 2>&1)"
    rm -f "$LOG"

    (cd "$D" && PATH="$SAFE_PATH" AGENT_LOG="$LOG" "$SCRIPT" proj/terea/context/TASK_via.md > /dev/null 2>&1)
    assert_eq "a relative path works (the worktree now exists, so it is reused)" \
        "claude|--effort|high|Task: terea/context/TASK_via.md" "$(agent_argv)"
    rm -f "$LOG"

    local other="$ROOT/terea@copy"
    git -C "$MAIN" worktree add -q "$other" -b task/copy master
    mkdir -p "$other/context"
    write_task "$other/context/TASK_copy.md" "Pending" "unassigned" "unassigned" "terea@copy2"
    refused "a copy in a worktree's own context/" "not the task file in the main checkout" \
        "$other/context/TASK_copy.md"

    write_task "$MAIN/context/notes.md" "Pending" "unassigned" "unassigned" "terea@notes"
    refused "a file not named TASK_<name>.md" "TASK_<name>.md" "$MAIN/context/notes.md"

    mkdir -p "$D/loose"
    write_task "$D/loose/TASK_loose.md" "Pending" "unassigned" "unassigned" "terea@loose"
    refused "a task file in no repository" "not inside a git repository" "$D/loose/TASK_loose.md"
    refused "no such file" "no such task file" "$MAIN/context/TASK_absent.md"
}

# --- test 14: a submodule -------------------------------------------------------------------

test14() {
    begin test14 "a repo that is a submodule of the project root resolves to its own checkout"
    D="$WORK/t14"
    ROOT="$D/proj"; LOG="$D/agent.log"
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
    git -C "$MAIN" checkout -q master
    mkdir -p "$MAIN/context"
    local task="$MAIN/context/TASK_sub.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@sub"
    run_dispatch "$task"
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "the worktree is <root>/terea@sub" "refs/heads/task/sub" \
        "$(git -C "$ROOT/terea@sub" symbolic-ref HEAD 2>&1)"
    assert_eq "claude starts in the project root" "$ROOT" "$(agent_cwd)"
    assert_eq "with the message naming terea/context" "claude|--effort|high|Task: terea/context/TASK_sub.md" "$(agent_argv)"
}

# --- test 15: bad input ---------------------------------------------------------------------

test15() {
    begin test15 "a malformed session id, bad options and a set GIT_DIR are refused"
    new_project t15
    local task="$MAIN/context/TASK_in.md"
    write_task "$task" "Returned" "Claude Opus 5.5" "--dangerously-skip-permissions" "terea@in"
    refused "a session id that is an option" "is not a session UUID" "$task"
    write_task "$task" "Returned" "Claude Opus 5.5" "some search words" "terea@in"
    refused "a session id that is a search term" "is not a session UUID" "$task"

    write_task "$task" "Pending" "unassigned" "unassigned" "terea@in"
    refused "--agent bogus" "--agent must be 'claude', 'codex', 'omp' or 'cursor'" --agent bogus "$task"
    refused "--agent twice" "--agent given twice" --agent claude --agent codex "$task"
    refused "--cwd twice" "--cwd given twice" --cwd "$ROOT" --cwd "$MAIN" "$task"
    refused "two task files" "one task file" "$task" "$task"
    refused "an unknown option" "unknown option '--resume'" --resume "$task"
    refused "no task file" "no task file given"

    local before
    before=$(snapshot)
    (cd "$D" && GIT_DIR="$ROOT/.git" PATH="$SAFE_PATH" AGENT_LOG="$LOG" "$SCRIPT" "$task") > /dev/null 2> "$D/err"
    local status=$?
    if [ "$status" -ne 0 ]; then ok "GIT_DIR set: exits non-zero"; else fail "GIT_DIR set: exits non-zero"; fi
    assert_contains "GIT_DIR set: names it" "GIT_DIR is set" "$(cat "$D/err")"
    assert_eq "GIT_DIR set: nothing changed" "$before" "$(snapshot)"
}

# --- test 16: the agent is checked before the worktree is made ------------------------------

test16() {
    begin test16 "an agent missing from PATH is refused before any worktree is made"
    new_project t16
    local task="$MAIN/context/TASK_nobin.md" before
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@nobin"
    mkdir -p "$D/onlycodex"
    cp "$FAKEBIN/codex" "$D/onlycodex/codex"
    if PATH="$D/onlycodex:/usr/bin:/bin" command -v claude > /dev/null 2>&1; then
        fail "no claude may be on the test PATH"
        return
    fi
    before=$(snapshot)
    (cd "$D" && PATH="$D/onlycodex:/usr/bin:/bin" AGENT_LOG="$LOG" "$SCRIPT" "$task") > /dev/null 2> "$D/err"
    local status=$?
    if [ "$status" -ne 0 ]; then ok "exits non-zero"; else fail "exits non-zero"; fi
    assert_contains "names the missing agent" "'claude' is not on PATH" "$(cat "$D/err")"
    assert_eq "no worktree was made" "$before" "$(snapshot)"
}

# --- test 17: --effort ---------------------------------------------------------------------

test17() {
    begin test17 "--effort reaches either agent in its own spelling; a level the agent lacks is refused"
    new_project t17
    local task="$MAIN/context/TASK_eff.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@eff"
    run_dispatch --effort xhigh "$task"
    assert_eq "claude, new session: --effort xhigh" \
        "claude|--effort|xhigh|Task: terea/context/TASK_eff.md" "$(agent_argv)"
    rm -f "$LOG"
    run_dispatch --effort max "$task"
    assert_eq "max only when asked for" \
        "claude|--effort|max|Task: terea/context/TASK_eff.md" "$(agent_argv)"
    rm -f "$LOG"

    local back="$MAIN/context/TASK_eff_back.md"
    write_task "$back" "Returned" "Claude Opus 5.5" "$ID1" "terea@eff" claude-code
    run_dispatch --effort medium "$back"
    assert_eq "claude, resume: --effort medium" \
        "claude|--effort|medium|--resume|$ID1|Follow-up task: terea/context/TASK_eff_back.md" "$(agent_argv)"
    rm -f "$LOG"

    local cx="$MAIN/context/TASK_eff_cx.md"
    write_task "$cx" "Returned" "gpt-6-astra" "$ID2" "terea@eff" codex
    run_dispatch --effort ultra "$cx"
    assert_eq "codex, resume: -c model_reasoning_effort=\"ultra\"" \
        "codex|resume|-c|model_reasoning_effort=\"ultra\"|-C|$ROOT|$ID2|Follow-up task: terea/context/TASK_eff_cx.md" \
        "$(agent_argv)"
    rm -f "$LOG"
    run_dispatch --agent codex --effort low "$task"
    assert_eq "codex, new session: -c model_reasoning_effort=\"low\"" \
        "codex|-c|model_reasoning_effort=\"low\"|Task: terea/context/TASK_eff.md" "$(agent_argv)"
    rm -f "$LOG"

    write_task "$task" "Pending" "unassigned" "unassigned" "terea@eff-new"
    refused "ultra for claude" "--effort 'ultra' is not a level claude takes" --effort ultra "$task"
    refused "a typo" "--effort 'hihg' is not a level claude takes" --effort hihg "$task"
    refused "the wrong case" "--effort 'High' is not a level claude takes" --effort High "$task"
    refused "a TOML-breaking level for codex" "is not a level codex takes" --agent codex --effort 'high" x' "$task"
    refused "an empty level" "--effort '' is not a level" --effort "" "$task"
    refused "--effort twice" "--effort given twice" --effort high --effort max "$task"
    refused "--effort without a value" "--effort needs a value" "$task" --effort
}

# --- test 18: a continued task -------------------------------------------------------------

# The exec line a dry run prints, and the one expected for <argv...>. dry_exec runs in a command
# substitution, so its run's OUT/ERR stay there; the run's files under $D do not.
dry_exec() {
    run_dispatch --dry-run "$@"
    printf '%s\n' "$OUT" | sed -n 's/^git-dispatch: exec: //p'
}
quoted() {
    local q
    q=$(printf '%q ' "$@")
    echo "${q% }"
}

test18() {
    begin test18 "a session plus a worker's '## Report' says 'Continue task'; a heading in a fence does not"
    new_project t18
    local task="$MAIN/context/TASK_c.md" ref="terea/context/TASK_c.md"
    local cont="Continue task: $ref - read it from the end." follow="Follow-up task: $ref"
    local claude_resume=(claude --effort high --resume "$ID1")
    local codex_resume=(codex resume -c 'model_reasoning_effort="high"' -C "$ROOT" "$ID2")

    body() {  # body <harness> <session> <lines...>: a task, then the given lines after its body
        local harness="$1" sid="$2"; shift 2
        write_task "$task" "Pending" "Claude Opus 5.5" "$sid" "terea@c" "$harness"
        printf '%s\n' "$@" >> "$task"
    }

    body claude-code "$ID1" "" "## Report" "" "Done, but blocked on X." "" "## Answer (CO)" "Do Y."
    assert_eq "claude: '## Report' continues" "$(quoted "${claude_resume[@]}" "$cont")" "$(dry_exec "$task")"
    assert_contains "... and the dry run says why" "continuing: a report at line" "$(cat "$D/out")"
    body codex "$ID2" "" "## Report" "" "## Report 2" "" "more"
    assert_eq "codex: '## Report' and '## Report 2' continue" "$(quoted "${codex_resume[@]}" "$cont")" "$(dry_exec "$task")"
    body claude-code "$ID1" "" "## Report 2" "text"
    assert_eq "'## Report 2' alone continues" "$(quoted "${claude_resume[@]}" "$cont")" "$(dry_exec "$task")"
    body claude-code "$ID1" "" "## Report   " "text"
    assert_eq "trailing blanks on the heading still count" "$(quoted "${claude_resume[@]}" "$cont")" "$(dry_exec "$task")"

    body claude-code "$ID1" "" "## Why" "nothing reported yet"
    assert_eq "claude: no report is a follow-up" "$(quoted "${claude_resume[@]}" "$follow")" "$(dry_exec "$task")"
    assert_contains "... and the dry run says so" "a follow-up: no report" "$(cat "$D/out")"
    body codex "$ID2" "" "## Why"
    assert_eq "codex: no report is a follow-up" "$(quoted "${codex_resume[@]}" "$follow")" "$(dry_exec "$task")"
    body unassigned unassigned "" "## Report" "an old report"
    assert_eq "no session: 'Task:', report or not" "$(quoted claude --effort high "Task: $ref")" "$(dry_exec "$task")"

    body claude-code "$ID1" "" "## Tests" '```' "## Report" '```'
    assert_eq "'## Report' in a \`\`\` fence is quoted, not a report" \
        "$(quoted "${claude_resume[@]}" "$follow")" "$(dry_exec "$task")"
    body claude-code "$ID1" "" '~~~markdown' "## Report 2" '~~~'
    assert_eq "... nor in a ~~~ fence with an info string" \
        "$(quoted "${claude_resume[@]}" "$follow")" "$(dry_exec "$task")"
    body claude-code "$ID1" "" '````' '```' "## Report" '```' '````'
    assert_eq "... nor after a shorter run that does not close the fence" \
        "$(quoted "${claude_resume[@]}" "$follow")" "$(dry_exec "$task")"
    body claude-code "$ID1" "" '~~~' '```' "## Report" '~~~'
    assert_eq "... nor after a run of the other character" \
        "$(quoted "${claude_resume[@]}" "$follow")" "$(dry_exec "$task")"
    body claude-code "$ID1" "" '  ```' "## Report" '   ```' "" "## Report"
    assert_eq "an indented fence closes, and a report after it counts" \
        "$(quoted "${claude_resume[@]}" "$cont")" "$(dry_exec "$task")"

    body claude-code "$ID1" "" "## Reporting" "## Report format" "### Report" " ## Report" "## Report 2b" "**## Report**"
    assert_eq "headings that only look like one are not a report" \
        "$(quoted "${claude_resume[@]}" "$follow")" "$(dry_exec "$task")"

    body claude-code "$ID1" "" '```' "## Report"
    assert_eq "an unclosed fence runs to the end" "$(quoted "${claude_resume[@]}" "$follow")" "$(dry_exec "$task")"
    assert_contains "... and says so" "never closed; nothing after it was read as a report" "$(cat "$D/err")"

    body claude-code "$ID1" "" "## Report" "done"
    local before
    before=$(sha1sum < "$task")
    run_dispatch "$task"
    assert_eq "a real run execs the continuation" \
        "claude|--effort|high|--resume|$ID1|$cont" "$(agent_argv)"
    assert_eq "... and leaves the task file as it was" "$before" "$(sha1sum < "$task")"
    rm -f "$LOG"
}

# --- test 19: omp ---------------------------------------------------------------------------

test19() {
    begin test19 "omp: 'omp <message>' starts a session; it cannot resume and takes no --effort"
    new_project t19
    local task="$MAIN/context/TASK_pi.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@pi"
    run_dispatch --agent omp "$task"
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "--agent omp, no session: omp 'Task: ...'" \
        "omp|Task: terea/context/TASK_pi.md" "$(agent_argv)"
    assert_eq "omp starts in the project root" "$ROOT" "$(agent_cwd)"
    assert_eq "the worktree is <root>/terea@pi" "refs/heads/task/pi" \
        "$(git -C "$ROOT/terea@pi" symbolic-ref HEAD 2>&1)"
    rm -f "$LOG"

    write_task "$task" "Pending" "unassigned" "unassigned" "terea@pi-harness" omp
    run_dispatch "$task"
    assert_eq "Harness: omp, no session: omp 'Task: ...'" \
        "omp|Task: terea/context/TASK_pi.md" "$(agent_argv)"
    rm -f "$LOG"

    write_task "$task" "Returned" "GLM 5.3" "$ID1" "terea@pi-resume" omp
    refused "Harness omp with a session id" "git dispatch cannot resume an omp session" "$task"
    refused "... even with --agent omp" "git dispatch cannot resume an omp session" --agent omp "$task"

    write_task "$task" "Returned" "GLM 5.3" "$ID2" "terea@pi-noharness"
    refused "--agent omp on a Harness-less session" "git dispatch cannot resume an omp session" --agent omp "$task"

    write_task "$task" "Pending" "unassigned" "unassigned" "terea@pi-effort"
    refused "--effort with omp" "--effort 'high' is not a level omp takes" --agent omp --effort high "$task"
    refused "... any level" "--effort 'low' is not a level omp takes" --agent omp --effort low "$task"
}

# --- test 20: cursor ------------------------------------------------------------------------

test20() {
    begin test20 "cursor: 'agent <message>' starts a session; 'agent --resume <id>' continues one; no effort"
    new_project t20
    local task="$MAIN/context/TASK_cu.md"
    write_task "$task" "Pending" "Claude Opus 5.5" "unassigned" "terea@cu"
    run_dispatch --agent cursor "$task"
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "--agent cursor, no session: agent 'Task: ...'" \
        "agent|Task: terea/context/TASK_cu.md" "$(agent_argv)"
    assert_eq "agent starts in the project root" "$ROOT" "$(agent_cwd)"
    assert_eq "the worktree is <root>/terea@cu" "refs/heads/task/cu" \
        "$(git -C "$ROOT/terea@cu" symbolic-ref HEAD 2>&1)"
    rm -f "$LOG"

    write_task "$task" "Pending" "unassigned" "unassigned" "terea@cu-harness" cursor
    run_dispatch "$task"
    assert_eq "Harness: cursor, no session: agent 'Task: ...'" \
        "agent|Task: terea/context/TASK_cu.md" "$(agent_argv)"
    rm -f "$LOG"

    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@cu-resume" cursor
    run_dispatch "$task"
    assert_eq "Harness: cursor resumes through agent --resume <id>" \
        "agent|--resume|$ID1|Follow-up task: terea/context/TASK_cu.md" "$(agent_argv)"
    assert_eq "the resume is in the project root" "$ROOT" "$(agent_cwd)"
    rm -f "$LOG"

    write_task "$task" "Returned" "Composer" "$ID2" "terea@cu-noharness"
    run_dispatch --agent cursor "$task"
    assert_eq "--agent cursor, no Harness: agent --resume <id>" \
        "agent|--resume|$ID2|Follow-up task: terea/context/TASK_cu.md" "$(agent_argv)"
    rm -f "$LOG"

    write_task "$task" "Pending" "Claude Opus 5.5" "$ID1" "terea@cu-cont" cursor
    printf '\n## Report\n\nDone.\n' >> "$task"
    run_dispatch "$task"
    assert_eq "a report continues" \
        "agent|--resume|$ID1|Continue task: terea/context/TASK_cu.md - read it from the end." "$(agent_argv)"
    rm -f "$LOG"

    write_task "$task" "Pending" "unassigned" "unassigned" "terea@cu-effort"
    refused "--effort with cursor" "--effort 'high' is not a level cursor takes" --agent cursor --effort high "$task"
    refused "... any level" "--effort 'low' is not a level cursor takes" --agent cursor --effort low "$task"

    local before
    before=$(snapshot)
    mkdir -p "$D/noagent"
    cp "$FAKEBIN/claude" "$D/noagent/claude"
    if PATH="$D/noagent:/usr/bin:/bin" command -v agent > /dev/null 2>&1; then
        fail "no agent may be on the test PATH"
        return
    fi
    (cd "$D" && PATH="$D/noagent:/usr/bin:/bin" AGENT_LOG="$LOG" "$SCRIPT" --agent cursor "$task") \
        > /dev/null 2> "$D/err"
    local status=$?
    if [ "$status" -ne 0 ]; then ok "missing agent: exits non-zero"; else fail "missing agent: exits non-zero"; fi
    assert_contains "missing agent: names the program" "'agent' is not on PATH" "$(cat "$D/err")"
    assert_eq "missing agent: no worktree was made" "$before" "$(snapshot)"
}

# --- test 21: dispatch.root, unset and set --------------------------------------------------

test21() {
    begin test21 "dispatch.root unset: the root is dirname(main); set: worktree, cwd, absolute task path"
    new_project t21
    local task="$MAIN/context/TASK_plain.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@plain"
    run_dispatch --dry-run "$task"
    assert_eq "unset: dry-run exits 0" "0" "$STATUS"
    assert_contains "unset: dry-run says the root is dirname(main), from the default" \
        "root: $(dirname -- "$MAIN")    (default: the main checkout's parent)" "$OUT"
    run_dispatch "$task"
    assert_eq "unset: the worktree is dirname(main)/<repo>@<slug>" "refs/heads/task/plain" \
        "$(git -C "$(dirname -- "$MAIN")/terea@plain" symbolic-ref HEAD 2>&1)"
    assert_eq "unset: the agent starts in dirname(main)" "$(dirname -- "$MAIN")" "$(agent_cwd)"
    rm -f "$LOG"

    local phys="$D/phys"
    mkdir -p "$phys"
    ln -s "$phys" "$D/via-link"
    git -C "$MAIN" config dispatch.root "$D/via-link"
    # Comments and blank lines are not relative paths, so the key may still be set.
    printf '# none\n\n' > "$MAIN/.git-report-deps"
    task="$MAIN/context/TASK_set.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@set"
    local before
    before=$(snapshot)
    run_dispatch --dry-run "$task"
    assert_eq "set: dry-run exits 0" "0" "$STATUS"
    assert_eq "set: dry-run changes nothing" "$before" "$(snapshot)"
    assert_contains "set: dry-run names the physical root and dispatch.root" \
        "root: $phys    (git config dispatch.root)" "$OUT"
    assert_contains "set: dry-run's worktree command uses that root" \
        "worktree add $phys/terea@set" "$OUT"
    assert_contains "set: dry-run cwd is the root" "cwd: $phys" "$OUT"
    run_dispatch "$task"
    assert_eq "set: exits 0" "0" "$STATUS"
    assert_contains "set: the worktree is registered at the physical root" \
        "worktree $phys/terea@set" "$(git -C "$MAIN" worktree list --porcelain)"
    assert_eq "set: the agent cwd is the root" "$phys" "$(agent_cwd)"
    assert_eq "set: the task path is absolute" \
        "claude|--effort|high|Task: $MAIN/context/TASK_set.md" "$(agent_argv)"
}

# --- test 22: dispatch.root refusals --------------------------------------------------------

test22() {
    begin test22 "a missing, nested, or dependency-breaking dispatch.root is refused before any change"
    new_project t22
    local task="$MAIN/context/TASK_no.md" missing="$D/no-such-root"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@no"
    git -C "$MAIN" config dispatch.root "$missing"
    refused "a dispatch.root that does not exist" "dispatch.root '$missing' does not exist" "$task"
    assert_contains "missing root: says to create it or unset it" \
        "create that directory, or unset it with 'git -C $MAIN config --unset dispatch.root'" "$ERR"
    if [ ! -e "$missing" ]; then
        ok "missing root: the directory was not created"
    else
        fail "missing root: the directory was not created"
    fi

    git -C "$MAIN" config dispatch.root "$MAIN/context"
    refused "a dispatch.root inside the main checkout" "is inside the main checkout" "$task"
    assert_contains "inside root: says to set one outside the checkout" "outside the checkout" "$ERR"

    git -C "$MAIN" config dispatch.root "$MAIN"
    refused "a dispatch.root that is the main checkout" "is the main checkout" "$task"
    assert_contains "the checkout itself: says to set one outside the checkout" \
        "outside the checkout" "$ERR"

    # The config value is not a string prefix of the checkout; only the physical path is inside it.
    ln -s "$MAIN/context" "$D/looks-outside"
    git -C "$MAIN" config dispatch.root "$D/looks-outside"
    refused "a dispatch.root whose physical path is inside the main checkout" \
        "is inside the main checkout" "$task"

    local ext="$D/ext"
    mkdir -p "$ext"
    git -C "$MAIN" config dispatch.root "$ext"
    printf '# note\n\n../dep\n' > "$MAIN/.git-report-deps"
    refused "a relative .git-report-deps while dispatch.root is set" "relative path ('../dep')" "$task"
    assert_contains "relative dep: says to remove it or unset dispatch.root" \
        "unset dispatch.root with 'git -C $MAIN config --unset dispatch.root'" "$ERR"
    if [ ! -e "$ext/terea@no" ]; then
        ok "relative dep: no worktree was created"
    else
        fail "relative dep: no worktree was created"
    fi
}

# --- test 23: Returned, under dispatch.root -------------------------------------------------

test23() {
    begin test23 "a Returned task reuses its worktree under dispatch.root and resumes there"
    new_project t23
    local phys="$D/phys"
    local wt="$phys/terea@back" task="$MAIN/context/TASK_back.md" head state_before
    mkdir -p "$phys"
    git -C "$MAIN" worktree add -q "$wt" -b task/back master
    echo work > "$wt/g.txt"
    commit_all "$wt" "worker's commit"
    echo dirty >> "$wt/f.txt"
    head=$(git -C "$wt" rev-parse HEAD)
    state_before=$(git -C "$wt" status --porcelain --untracked-files=all; cat "$wt/f.txt")
    git -C "$MAIN" config dispatch.root "$phys"
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@back" claude-code

    run_dispatch "$task"
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "the worktree's HEAD is where the worker left it" "$head" "$(git -C "$wt" rev-parse HEAD)"
    assert_eq "its uncommitted work is untouched" "$state_before" \
        "$(git -C "$wt" status --porcelain --untracked-files=all; cat "$wt/f.txt")"
    assert_eq "still one worktree besides main" "2" "$(git -C "$MAIN" worktree list | wc -l | tr -d ' ')"
    if [ ! -e "$ROOT/terea@back" ]; then
        ok "nothing was created beside the main checkout"
    else
        fail "nothing was created beside the main checkout"
    fi
    assert_eq "the resume cwd is the configured root" "$phys" "$(agent_cwd)"
    assert_eq "claude --resume names the task absolutely" \
        "claude|--effort|high|--resume|$ID1|Follow-up task: $MAIN/context/TASK_back.md" "$(agent_argv)"
}

# --- test 24: --cwd still wins --------------------------------------------------------------

test24() {
    begin test24 "--cwd overrides dispatch.root as the agent's cwd; the worktree stays under the root"
    new_project t24
    local phys="$D/phys" alt="$D/alt" task="$MAIN/context/TASK_cwd.md"
    mkdir -p "$phys" "$alt"
    git -C "$MAIN" config dispatch.root "$phys"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@cwd"
    run_dispatch --cwd "$alt" "$task"
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "the agent cwd is --cwd" "$(cd -- "$alt" && pwd -P)" "$(agent_cwd)"
    assert_eq "the worktree is under dispatch.root" "refs/heads/task/cwd" \
        "$(git -C "$phys/terea@cwd" symbolic-ref HEAD 2>&1)"
    assert_eq "the task path is absolute from --cwd" \
        "claude|--effort|high|Task: $MAIN/context/TASK_cwd.md" "$(agent_argv)"
}

# --- dispatch.moveTask ----------------------------------------------------------------------

# A project whose dispatch.root is $D/phys (PHYS), with dispatch.moveTask true. Snapshots also
# watch PHYS and the main checkout's context/, where the task file and its link live.
move_project() {
    new_project "$1"
    PHYS="$D/phys"
    mkdir -p "$PHYS"
    git -C "$MAIN" config dispatch.root "$PHYS"
    git -C "$MAIN" config dispatch.moveTask true
    SNAP_EXTRA=("$PHYS" "$MAIN/context")
}

# What a path holds: 'link <target>', 'file <sha1>', 'other' or 'absent'.
file_state() {
    if [ -L "$1" ]; then
        echo "link $(readlink -- "$1")"
    elif [ -f "$1" ]; then
        echo "file $(sha1sum < "$1")"
    elif [ -e "$1" ]; then
        echo "other"
    else
        echo "absent"
    fi
}

# --- test 25: dispatch.moveTask unset -------------------------------------------------------

test25() {
    begin test25 "dispatch.moveTask unset, false, or without dispatch.root: the task file stays, the message is today's"
    new_project t25
    local phys="$D/phys" task="$MAIN/context/TASK_stay.md" sum
    mkdir -p "$phys"
    git -C "$MAIN" config dispatch.root "$phys"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@stay"
    sum=$(sha1sum < "$task")
    run_dispatch "$task"
    assert_eq "unset: exits 0" "0" "$STATUS"
    assert_eq "unset: the task file stays, a regular file, untouched" "file $sum" "$(file_state "$task")"
    assert_eq "unset: nothing in the checkout's context/" "absent" \
        "$(file_state "$phys/terea@stay/context/TASK_stay.md")"
    assert_eq "unset: the message names the main checkout's file" \
        "claude|--effort|high|Task: $MAIN/context/TASK_stay.md" "$(agent_argv)"
    assert_eq "unset: no move, link or task file line" "" \
        "$(grep -E '^git-dispatch: (move|link|task file):' <<< "$OUT")"
    rm -f "$LOG"

    git -C "$MAIN" config dispatch.moveTask false
    task="$MAIN/context/TASK_off.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@off"
    sum=$(sha1sum < "$task")
    run_dispatch "$task"
    assert_eq "false: the task file stays" "file $sum" "$(file_state "$task")"
    assert_eq "false: the message names the main checkout's file" \
        "claude|--effort|high|Task: $MAIN/context/TASK_off.md" "$(agent_argv)"
    rm -f "$LOG"

    git -C "$MAIN" config --unset dispatch.root
    git -C "$MAIN" config dispatch.moveTask true
    task="$MAIN/context/TASK_noroot.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@noroot"
    sum=$(sha1sum < "$task")
    run_dispatch "$task"
    assert_eq "true, no dispatch.root: the task file stays" "file $sum" "$(file_state "$task")"
    assert_eq "true, no dispatch.root: nothing in the checkout's context/" "absent" \
        "$(file_state "$ROOT/terea@noroot/context/TASK_noroot.md")"
    assert_eq "true, no dispatch.root: today's message" \
        "claude|--effort|high|Task: terea/context/TASK_noroot.md" "$(agent_argv)"
}

# --- test 26: the first dispatch moves and links --------------------------------------------

test26() {
    begin test26 "dispatch.moveTask: the first dispatch moves the task into its checkout and links it back"
    move_project t26
    local task="$MAIN/context/TASK_mv.md" wt="$PHYS/terea@mv"
    local dest="$PHYS/terea@mv/context/TASK_mv.md" rel="../../../phys/terea@mv/context/TASK_mv.md"
    local sum before
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@mv"
    sum=$(sha1sum < "$task")

    before=$(snapshot)
    run_dispatch --dry-run "$task"
    assert_eq "dry run: exits 0" "0" "$STATUS"
    assert_eq "dry run: nothing moved" "$before" "$(snapshot)"
    assert_contains "dry run: prints the move" "move: $task -> $dest" "$OUT"
    assert_contains "dry run: prints the link" "link: $task -> $rel" "$OUT"
    assert_eq "dry run: the exec names the moved file" \
        "$(quoted claude --effort high "Task: terea@mv/context/TASK_mv.md")" "$(dry_exec "$task")"

    run_dispatch "$task"
    assert_eq "exits 0" "0" "$STATUS"
    assert_eq "the checkout holds the task file, byte-identical" "file $sum" "$(file_state "$dest")"
    assert_eq "the main checkout's path is a relative link to it" "link $rel" "$(file_state "$task")"
    if [ "$task" -ef "$dest" ]; then
        ok "the link resolves to the checkout's file"
    else
        fail "the link resolves to the checkout's file"
    fi
    assert_eq "the worker starts in the root" "$PHYS" "$(agent_cwd)"
    assert_eq "the message names the moved file from the root" \
        "claude|--effort|high|Task: terea@mv/context/TASK_mv.md" "$(agent_argv)"
    assert_eq "the moved file is ignored in the worktree" "" \
        "$(git -C "$wt" status --porcelain --untracked-files=all)"
    assert_eq "no temporary link is left" "TASK_mv.md" "$(ls -A "$MAIN/context")"
    rm -f "$LOG"

    # A task routed to the same checkout, which already exists: reused, and the file moves into it.
    local task2="$MAIN/context/TASK_two.md"
    write_task "$task2" "Pending" "unassigned" "unassigned" "terea@mv"
    sum=$(sha1sum < "$task2")
    run_dispatch "$task2"
    assert_eq "an existing checkout: exits 0" "0" "$STATUS"
    assert_eq "an existing checkout: the file moved into it" "file $sum" \
        "$(file_state "$wt/context/TASK_two.md")"
    assert_eq "an existing checkout: linked back" "link ../../../phys/terea@mv/context/TASK_two.md" \
        "$(file_state "$task2")"
    assert_eq "an existing checkout: the message names the moved file" \
        "claude|--effort|high|Task: terea@mv/context/TASK_two.md" "$(agent_argv)"
}

# --- test 27: re-dispatching through the link -----------------------------------------------

test27() {
    begin test27 "dispatch.moveTask: a Returned task is read through its link; nothing moves"
    move_project t27
    local task="$MAIN/context/TASK_ret.md" wt="$PHYS/terea@ret"
    local dest="$PHYS/terea@ret/context/TASK_ret.md" link_before dest_before
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@ret"
    run_dispatch "$task"
    rm -f "$LOG"
    # The worker reported and CO returned the task, both writing the one file, in the checkout.
    write_task "$dest" "Returned" "Claude Opus 5.5" "$ID1" "terea@ret" claude-code
    printf '\n## Report\n\nDone.\n' >> "$dest"
    link_before=$(file_state "$task")
    dest_before=$(file_state "$dest")

    run_dispatch "$task"
    assert_eq "accepted: exits 0" "0" "$STATUS"
    assert_eq "the link is unchanged" "$link_before" "$(file_state "$task")"
    assert_eq "the checkout's file is unchanged" "$dest_before" "$(file_state "$dest")"
    assert_eq "nothing else in either context/" "TASK_ret.md|TASK_ret.md" \
        "$(ls -A "$MAIN/context")|$(ls -A "$wt/context")"
    assert_contains "says it reads through the link" "task file: $MAIN/context/TASK_ret.md links to $dest" "$OUT"
    assert_eq "resumes in the root" "$PHYS" "$(agent_cwd)"
    assert_eq "the message continues the moved file" \
        "claude|--effort|high|--resume|$ID1|Continue task: terea@ret/context/TASK_ret.md - read it from the end." \
        "$(agent_argv)"
    rm -f "$LOG"

    assert_eq "--cwd in the checkout: the file is named from there" \
        "$(quoted claude --effort high --resume "$ID1" "Continue task: context/TASK_ret.md - read it from the end.")" \
        "$(dry_exec --cwd "$wt" "$task")"
    assert_eq "--cwd outside the root: the file is named absolutely" \
        "$(quoted claude --effort high --resume "$ID1" "Continue task: $dest - read it from the end.")" \
        "$(dry_exec --cwd "$MAIN" "$task")"
}

# --- test 28: dispatch.moveTask refusals ----------------------------------------------------

test28() {
    begin test28 "dispatch.moveTask: a taken destination, a split file, a bad link, the checkout's copy are refused"
    move_project t28
    local task wt dest

    task="$MAIN/context/TASK_d.md" wt="$PHYS/terea@d"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@d"
    git -C "$MAIN" worktree add -q "$wt" -b task/d master
    mkdir -p "$wt/context/TASK_d.md"
    refused "a destination that already exists" "$wt/context/TASK_d.md: that path already exists" "$task"

    task="$MAIN/context/TASK_l.md" wt="$PHYS/terea@l"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@l"
    git -C "$MAIN" worktree add -q "$wt" -b task/l master
    ln -s ../../proj/terea/context "$wt/context"
    refused "a checkout whose context/ is a link" "$wt/context: not a directory of the checkout's own" "$task"

    task="$MAIN/context/TASK_split.md" dest="$PHYS/terea@split/context/TASK_split.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@split"
    run_dispatch "$task"
    rm -f "$LOG"
    # What sed -i does to a link: a new regular file in its place.
    rm "$task"
    cp "$dest" "$task"
    echo "CO's note" >> "$task"
    refused "a regular file in both places" "the checkout holds one too ($dest)" "$task"
    assert_contains "both places: names the main checkout's path" "git-dispatch: $task: a regular file" "$ERR"

    task="$MAIN/context/TASK_gone.md" wt="$PHYS/terea@gone" dest="$PHYS/terea@gone/context/TASK_gone.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@gone"
    run_dispatch "$task"
    rm -f "$LOG"
    git -C "$MAIN" worktree remove "$wt"
    assert_eq "git worktree remove deletes the gitignored task file, without --force" "absent" \
        "$(file_state "$dest")"
    refused "a dangling link" "which does not exist: the task's worktree, and the task file with it, is gone" \
        "$task"

    task="$MAIN/context/TASK_other.md" dest="$PHYS/terea@first/context/TASK_other.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@first"
    run_dispatch "$task"
    rm -f "$LOG"
    sed -i 's/^\*\*Checkout: terea@first\*\*$/**Checkout: terea@second**/' "$dest"
    refused "a link to another checkout than the Checkout line names" \
        "not to the task's file in the checkout that line 8 names ($PHYS/terea@second/context/TASK_other.md)" "$task"

    task="$MAIN/context/TASK_direct.md" dest="$PHYS/terea@direct/context/TASK_direct.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@direct"
    run_dispatch "$task"
    rm -f "$LOG"
    write_task "$dest" "Returned" "Claude Opus 5.5" "$ID1" "terea@direct" claude-code
    refused "the checkout's copy named directly" \
        "this is a checkout's copy of the task; dispatch it by its path in the main checkout ($MAIN/context/TASK_direct.md)" \
        "$dest"

    git -C "$MAIN" config dispatch.moveTask maybe
    task="$MAIN/context/TASK_bool.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@bool"
    refused "a dispatch.moveTask that is not a boolean" "dispatch.moveTask: " "$task"
}

# --- test 29: no move when an earlier step refuses ------------------------------------------

test29() {
    begin test29 "dispatch.moveTask: nothing moves when an earlier step refuses"
    move_project t29
    local task="$MAIN/context/TASK_early.md" sum
    write_task "$task" "Bogus" "unassigned" "unassigned" "terea@early"
    sum=$(sha1sum < "$task")
    refused "an unknown status" "unknown status 'Bogus'" "$task"
    assert_eq "an unknown status: the task file is where it was" "file $sum" "$(file_state "$task")"

    write_task "$task" "Pending" "unassigned" "unassigned" "terea@early"
    git -C "$MAIN" branch -q task/early master
    sum=$(sha1sum < "$task")
    refused "a task branch without its worktree" "exists but its worktree" "$task"
    assert_eq "a refused checkout: the task file is where it was" "file $sum" "$(file_state "$task")"

    # 'git worktree add' itself fails, after every check: the file must not move without its checkout.
    git -C "$MAIN" branch -q -D task/early
    chmod a-w "$PHYS"
    run_dispatch "$task"
    chmod u+w "$PHYS"
    if [ "$STATUS" -ne 0 ]; then ok "worktree add fails: exits non-zero"; else fail "worktree add fails: exits non-zero"; fi
    assert_contains "worktree add fails: says so" "git worktree add failed" "$ERR"
    assert_eq "worktree add fails: the task file is where it was" "file $sum" "$(file_state "$task")"
    assert_eq "worktree add fails: no agent ran" "(not run)" "$(agent_argv)"

    # The link cannot be made (context/ is read-only): it is made before the move, so nothing moves.
    # (The failed 'git worktree add' above left its branch behind.)
    git -C "$MAIN" branch -q -D task/early
    chmod a-w "$MAIN/context"
    run_dispatch "$task"
    chmod u+w "$MAIN/context"
    if [ "$STATUS" -ne 0 ]; then ok "no link: exits non-zero"; else fail "no link: exits non-zero"; fi
    assert_contains "no link: says the file did not move" "the task file did not move" "$ERR"
    assert_eq "no link: the task file is where it was" "file $sum" "$(file_state "$task")"
    assert_eq "no link: nothing in the checkout's context/" "absent" \
        "$(file_state "$PHYS/terea@early/context/TASK_early.md")"
    assert_eq "no link: no temporary link is left" "TASK_early.md" "$(ls -A "$MAIN/context")"
    assert_eq "no link: no agent ran" "(not run)" "$(agent_argv)"
}

# --- tests 30-37: arguments after the task's -- ---------------------------------------------

test30() {
    begin test30 "new sessions: agent arguments follow generated flags and precede the prompt"
    new_project t30
    local task="$MAIN/context/TASK_args.md" agent
    local -a expected
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@args"
    for agent in claude codex cursor omp; do
        case "$agent" in
            claude) expected=(claude --effort high) ;;
            codex) expected=(codex -c 'model_reasoning_effort="high"') ;;
            cursor) expected=(agent) ;;
            omp) expected=(omp) ;;
        esac
        expected+=(--model chosen "Task: terea/context/TASK_args.md")
        run_dispatch --dry-run --agent "$agent" "$task" -- --model chosen
        assert_eq "$agent: exits 0" "0" "$STATUS"
        assert_eq "$agent: exact dry-run argv" "$(printf '%q ' "${expected[@]}")" \
            "$(printf '%s\n' "$OUT" | sed -n 's/^git-dispatch: exec: //p') "
    done
}

test31() {
    begin test31 "resumes: preserve resume option values; Codex args follow -C and precede the session"
    new_project t31
    local task="$MAIN/context/TASK_args.md" harness
    local -a expected extra
    for harness in claude-code codex cursor; do
        extra=(--model chosen)
        case "$harness" in
            claude-code) expected=(claude --effort high --resume "$ID1" "${extra[@]}") ;;
            codex)
                extra=(--sandbox danger-full-access)
                expected=(codex resume -c 'model_reasoning_effort="high"' -C "$MAIN" "${extra[@]}" "$ID1")
                ;;
            cursor) expected=(agent --resume "$ID1" "${extra[@]}") ;;
        esac
        expected+=("Follow-up task: context/TASK_args.md")
        write_task "$task" "Returned" "unassigned" "$ID1" "terea@args" "$harness"
        run_dispatch --dry-run --cwd "$MAIN" "$task" -- "${extra[@]}"
        assert_eq "$harness: exits 0" "0" "$STATUS"
        assert_eq "$harness: exact dry-run argv" "$(printf '%q ' "${expected[@]}")" \
            "$(printf '%s\n' "$OUT" | sed -n 's/^git-dispatch: exec: //p') "
    done
}

test32() {
    begin test32 "real exec preserves spaces, quotes, empty args, duplicates and literal --"
    new_project t32
    local task="$MAIN/context/TASK_args.md" harness sid message expected_log dry_exec
    local -a expected prefix extra=(--model 'two words' --model 'a"quote' "a'quote" '' '*' -- --dry-run)
    for harness in claude-code codex cursor omp; do
        for sid in unassigned "$ID1"; do
            [ "$harness" != omp ] || [ "$sid" = unassigned ] || continue
            write_task "$task" "Pending" "unassigned" "$sid" "terea@args" "$harness"
            case "$harness" in
                claude-code) prefix=(claude --effort high) ;;
                codex) prefix=(codex -c 'model_reasoning_effort="high"') ;;
                cursor) prefix=(agent) ;;
                omp) prefix=(omp) ;;
            esac
            message="Task: terea/context/TASK_args.md"
            if [ "$sid" != unassigned ]; then
                message="Follow-up task: terea/context/TASK_args.md"
                if [ "$harness" = codex ]; then
                    prefix=(codex resume -c 'model_reasoning_effort="high"' -C "$ROOT")
                else
                    prefix+=(--resume "$sid")
                fi
            fi
            expected=("${prefix[@]}" "${extra[@]}")
            if [ "$harness" = codex ] && [ "$sid" != unassigned ]; then expected+=("$sid"); fi
            expected+=("$message")
            expected_log=$(printf 'cwd=%s\nargv0=%s\n' "$ROOT" "${expected[0]}"; printf 'arg=%s\n' "${expected[@]:1}")
            run_dispatch --dry-run "$task" -- "${extra[@]}"
            assert_eq "$harness/$sid: dry run exits 0" "0" "$STATUS"
            dry_exec=$(printf '%s\n' "$OUT" | sed -n 's/^git-dispatch: exec: //p')
            assert_eq "$harness/$sid: quoted arguments" "$(printf '%q ' "${expected[@]}")" "$dry_exec "
            rm -f "$LOG"
            run_dispatch "$task" -- "${extra[@]}"
            assert_eq "$harness/$sid: real run exits 0" "0" "$STATUS"
            assert_eq "$harness/$sid: exact received argument boundaries" "$expected_log" "$(cat "$LOG" 2>/dev/null)"
            assert_eq "$harness/$sid: normal exec line matches dry-run" "$dry_exec" \
                "$(printf '%s\n' "$OUT" | sed -n 's/^git-dispatch: exec: //p')"
        done
    done
}

test33() {
    begin test33 "-- before the task still ends dispatch's options"
    new_project t33
    local task="$MAIN/context/TASK_args.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@args"
    run_dispatch -- "$task"
    assert_eq "leading -- accepted" "0" "$STATUS"
    assert_eq "leading -- adds no arguments" "claude|--effort|high|Task: terea/context/TASK_args.md" "$(agent_argv)"
}

test34() {
    begin test34 "-- before and after the task passes only the trailing args"
    new_project t34
    local task="$MAIN/context/TASK_args.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@args"
    run_dispatch -- "$task" -- --model 'two words'
    assert_eq "two separators accepted" "0" "$STATUS"
    assert_eq "only trailing args passed" \
        "claude|--effort|high|--model|two words|Task: terea/context/TASK_args.md" "$(agent_argv)"
}

test35() {
    begin test35 "an empty trailing -- adds nothing"
    new_project t35
    local task="$MAIN/context/TASK_args.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@args"
    run_dispatch "$task" --
    assert_eq "empty trailing args accepted" "0" "$STATUS"
    assert_eq "no extra argument, including no empty string" \
        "claude|--effort|high|Task: terea/context/TASK_args.md" "$(agent_argv)"
    run_dispatch -- "$task" --
    assert_eq "leading and empty trailing -- accepted" "0" "$STATUS"
    assert_eq "both separators add nothing" \
        "claude|--effort|high|Task: terea/context/TASK_args.md" "$(agent_argv)"
}

test36() {
    begin test36 "two task files without a separating -- keep their existing errors"
    new_project t36
    local task="$MAIN/context/TASK_args.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@args"
    run_dispatch "$task" "$task"
    assert_eq "two tasks: usage error" "2" "$STATUS"
    assert_eq "two tasks: original message" \
        "git-dispatch: one task file, not several ('$task', '$task')" "${ERR%%$'\n'*}"
    run_dispatch -- "$task" "$task"
    assert_eq "two tasks after --: usage error" "2" "$STATUS"
    assert_eq "two tasks after --: original message" \
        "git-dispatch: one task file, not several" "${ERR%%$'\n'*}"
}

test37() {
    begin test37 "without a trailing -- the exact command line is unchanged"
    new_project t37
    local task="$MAIN/context/TASK_args.md"
    write_task "$task" "Pending" "unassigned" "unassigned" "terea@args"
    run_dispatch --dry-run --agent codex "$task"
    assert_eq "no trailing --: exits 0" "0" "$STATUS"
    assert_eq "no trailing --: original command line" \
        'codex -c model_reasoning_effort=\"high\" Task:\ terea/context/TASK_args.md' \
        "$(printf '%s\n' "$OUT" | sed -n 's/^git-dispatch: exec: //p')"
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
test29
test30
test31
test32
test33
test34
test35
test36
test37

echo
echo "== behaviour -> test mapping =="
echo "1. new task: worktree from the default branch, claude in the root ..... test1"
echo "2. Returned task: worktree reused untouched, claude --resume .......... test2"
echo "3. routed follow-up, new slug: new worktree, resume in the root ....... test3"
echo "4. Harness codex: codex resume <id>; codex for a new session .......... test4"
echo "5. Harness decides the program; the model name is never read .......... test5"
echo "6. --cwd moves only the agent's working directory ..................... test6"
echo "7. every non-dispatchable status is refused ........................... test7"
echo "8. missing / malformed / duplicate Checkout is refused ................ test8"
echo "9. a Checkout naming another repo is refused .......................... test9"
echo "10. branch without worktree, or a foreign worktree, is refused ........ test10"
echo "11. --dry-run changes nothing, prints the exact argv and cwd .......... test11"
echo "12. the default branch, as it stands locally .......................... test12"
echo "13. the task file is the main checkout's, reached any way ............. test13"
echo "14. a submodule repo resolves to its own checkout ..................... test14"
echo "15. bad session ids, bad options, GIT_DIR are refused ................. test15"
echo "16. the agent is checked before any change ............................ test16"
echo "17. --effort per agent; default high; unknown levels refused .......... test17"
echo "18. a session plus a report continues; fenced headings do not ......... test18"
echo "19. omp: 'omp <message>' starts a session; no resume, no effort ....... test19"
echo "20. cursor: 'agent <message>'; 'agent --resume <id>'; no effort ....... test20"
echo "21. dispatch.root unset is dirname(main); set moves the worktree ..... test21"
echo "22. a missing, nested, or dependency-breaking root is refused ......... test22"
echo "23. a Returned task reuses the worktree under dispatch.root ........... test23"
echo "24. --cwd overrides dispatch.root for the agent's cwd ................. test24"
echo "25. dispatch.moveTask unset, false, or without a root: nothing moves .. test25"
echo "26. dispatch.moveTask: the first dispatch moves the task and links it . test26"
echo "27. dispatch.moveTask: a Returned task is read through its link ....... test27"
echo "28. dispatch.moveTask: taken, split, bad-link, direct copy refused .... test28"
echo "29. dispatch.moveTask: nothing moves when an earlier step refuses ..... test29"
echo "30. trailing args: new-session placement for all four agents .......... test30"
echo "31. trailing args: resume placement for all three agents .............. test31"
echo "32. trailing args: real argv boundaries and quoted exec lines ......... test32"
echo "33. leading -- still ends dispatch's options ......................... test33"
echo "34. leading and trailing -- together pass agent arguments ............. test34"
echo "35. empty trailing -- adds no arguments ............................... test35"
echo "36. two task files keep the existing error messages ................... test36"
echo "37. without trailing --, the exact command stays unchanged ............ test37"
echo
TESTS_ERRORED=0
for t in "${ORDER[@]}"; do
    if [ -n "${T_ERR[$t]+set}" ]; then
        TESTS_ERRORED=$((TESTS_ERRORED + 1))
        echo "ERROR tests/test-git-dispatch.sh::$t - BashError: ${T_ERR[$t]}"
    elif [ -n "${T_FAIL[$t]+set}" ]; then
        echo "FAILED tests/test-git-dispatch.sh::$t - AssertionError: ${T_FAIL[$t]}"
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
