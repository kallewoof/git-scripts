#!/bin/bash
#
# Copyright (c) 2026 Karl-Johan Alm
# Distributed under the MIT software license, see the accompanying
# file LICENSE or http://www.opensource.org/licenses/mit-license.php.
#
# Test suite for git-dispatch. Builds throwaway project roots under a temp dir -- a super-project
# holding a repo's main checkout, and sibling worktrees -- and puts fake 'claude' and 'codex' first
# on a PATH that holds no real one: each fake records its cwd and argv to a file and exits. No test
# starts a real agent, and nothing outside the temp dir is touched. Each test names the behaviour
# it pins -- see the final summary for the full mapping.
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
for agent in claude codex; do
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
    refused "a session with no Harness line" "add '**Harness: claude-code**' or '**Harness: codex**'" "$task"
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@who" unassigned
    refused "a session with Harness unassigned" "no program to resume it with" "$task"
    write_task "$task" "Returned" "Claude Opus 5.5" "$ID1" "terea@who" cursor
    refused "Harness cursor" "line 6: Harness 'cursor' cannot be resumed from the command line; resume it in cursor" "$task"
    refused "Harness cursor, even with --agent" "Harness 'cursor' cannot be resumed" --agent claude "$task"
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
    refused "--agent bogus" "--agent must be 'claude' or 'codex'" --agent bogus "$task"
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

echo
echo "== behaviour -> test mapping =="
echo "1. new task: worktree from the default branch, claude in the root ..... test1"
echo "2. Returned task: worktree reused untouched, claude --resume ......... test2"
echo "3. routed follow-up, new slug: new worktree, resume in the root ...... test3"
echo "4. Harness codex: codex resume <id>; codex for a new session ........ test4"
echo "5. Harness decides the program; the model name is never read ........ test5"
echo "6. --cwd moves only the agent's working directory .................... test6"
echo "7. every non-dispatchable status is refused .......................... test7"
echo "8. missing / malformed / duplicate Checkout is refused ............... test8"
echo "9. a Checkout naming another repo is refused ......................... test9"
echo "10. branch without worktree, or a foreign worktree, is refused ....... test10"
echo "11. --dry-run changes nothing, prints the exact argv and cwd ......... test11"
echo "12. the default branch, as it stands locally ......................... test12"
echo "13. the task file is the main checkout's, reached any way ............ test13"
echo "14. a submodule repo resolves to its own checkout .................... test14"
echo "15. bad session ids, bad options, GIT_DIR are refused ................ test15"
echo "16. the agent is checked before any change ........................... test16"
echo "17. --effort per agent; default high; unknown levels refused ......... test17"
echo "18. a session plus a report continues; fenced headings do not ...... test18"
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
