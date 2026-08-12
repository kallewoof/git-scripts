#!/bin/bash
#
# Copyright (c) 2026 Karl-Johan Alm
# Distributed under the MIT software license, see the accompanying
# file LICENSE or http://www.opensource.org/licenses/mit-license.php.
#
# Test suite for git-report. Builds throwaway repos under a temp dir with a trivial
# fake gate; touches nothing outside that temp dir. Each test names the behaviour it
# pins -- see the final summary for the full mapping.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../git-report"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TESTS_RUN=0
TESTS_FAILED=0

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

# Fake gate: always records that it ran (independent of pass/fail), then fails iff a
# marker file is present. Counter growth is proof the gate actually executed.
make_fake_gate_config() {
    local repo="$1" counter="$2" marker="$3"
    cat > "$repo/.pre-commit-config.yaml" <<EOF
repos:
  - repo: local
    hooks:
      - id: fake-gate
        name: fake gate
        entry: bash -c 'echo RAN >> "$counter"; [ -f "$marker" ] && exit 1; exit 0'
        language: system
        always_run: true
        pass_filenames: false
EOF
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

counter_value() {
    local f="$1"
    if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else echo 0; fi
}

run_report() {
    local repo="$1"; shift
    (cd "$repo" && "$SCRIPT" "$@")
}

# A cache hit's report is everything after its first line, which is the cached-notice.
body_after_notice() {
    printf '%s\n' "$1" | tail -n +2
}

# --- test 1: clean run caches; second run is a hit and executes no gate -----------

test1() {
    echo "test 1: clean run caches, second run is a cache hit (no gate re-run)"
    local d="$WORK/t1" repo counter marker
    repo="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$repo"
    make_fake_gate_config "$repo" "$counter" "$marker"
    echo x > "$repo/f.txt"
    commit_all "$repo" init

    local out1 status1 out2 status2
    out1=$(run_report "$repo"); status1=$?
    assert_eq "first run exits 0" "0" "$status1"
    assert_eq "first run invoked the gate once" "1" "$(counter_value "$counter")"

    out2=$(run_report "$repo"); status2=$?
    assert_eq "second run exits 0" "0" "$status2"
    assert_eq "second run is a hit (counter unchanged)" "1" "$(counter_value "$counter")"
    assert_eq "hit replays the report the miss cached, below its notice" \
        "$out1" "$(body_after_notice "$out2")"
}

# --- test 2: a commit in self busts the key ----------------------------------------

test2() {
    echo "test 2: a commit in self busts the key"
    local d="$WORK/t2" repo counter marker
    repo="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$repo"
    make_fake_gate_config "$repo" "$counter" "$marker"
    echo x > "$repo/f.txt"
    commit_all "$repo" init
    run_report "$repo" > /dev/null
    assert_eq "baseline run invoked the gate once" "1" "$(counter_value "$counter")"

    echo y >> "$repo/f.txt"
    commit_all "$repo" second

    run_report "$repo" > /dev/null
    assert_eq "commit in self busts the key (gate re-run)" "2" "$(counter_value "$counter")"
}

# --- test 3: a commit in a dependency busts the key, self untouched ----------------

test3() {
    echo "test 3: a commit in a dependency busts the key (self HEAD unchanged)"
    local d="$WORK/t3" dep self counter marker
    dep="$d/dep"; self="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$dep"
    echo x > "$dep/d.txt"
    commit_all "$dep" "dep init"

    init_repo "$self"
    make_fake_gate_config "$self" "$counter" "$marker"
    printf '../dep\n' > "$self/.git-report-deps"
    echo x > "$self/f.txt"
    commit_all "$self" "self init"

    run_report "$self" > /dev/null
    assert_eq "baseline run invoked the gate once" "1" "$(counter_value "$counter")"

    local self_head_before self_head_after
    self_head_before=$(git -C "$self" rev-parse HEAD)

    echo y >> "$dep/d.txt"
    commit_all "$dep" "dep second"

    self_head_after=$(git -C "$self" rev-parse HEAD)
    assert_eq "self HEAD did not move" "$self_head_before" "$self_head_after"

    run_report "$self" > /dev/null
    assert_eq "dependency commit busts the key (gate re-run)" "2" "$(counter_value "$counter")"
}

# --- test 4: dirty dependency -> different key; two WIP states don't collide ------

test4() {
    echo "test 4: dirty dependency yields a different key; distinct WIP states don't collide"
    local d="$WORK/t4" dep self counter marker
    dep="$d/dep"; self="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$dep"
    echo "orig" > "$dep/d.txt"
    commit_all "$dep" "dep init"

    init_repo "$self"
    make_fake_gate_config "$self" "$counter" "$marker"
    printf '../dep\n' > "$self/.git-report-deps"
    echo x > "$self/f.txt"
    commit_all "$self" "self init"

    run_report "$self" > /dev/null
    assert_eq "baseline (dep clean) run invoked the gate once" "1" "$(counter_value "$counter")"

    echo "state-A" > "$dep/d.txt"
    run_report "$self" > /dev/null
    assert_eq "dirty dependency (state A) busts the key" "2" "$(counter_value "$counter")"

    run_report "$self" > /dev/null
    assert_eq "same dirty state (A) again is a cache hit" "2" "$(counter_value "$counter")"

    echo "state-B" > "$dep/d.txt"
    run_report "$self" > /dev/null
    assert_eq "different dirty state (B) does not collide with state A" "3" "$(counter_value "$counter")"
}

# --- test 5: dirty own tree is refused, in both modes ------------------------------

test5() {
    echo "test 5: a dirty own tree is refused, in both modes"
    local d="$WORK/t5" repo counter marker
    repo="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$repo"
    make_fake_gate_config "$repo" "$counter" "$marker"
    echo x > "$repo/f.txt"
    commit_all "$repo" init

    echo dirty >> "$repo/f.txt"

    local status_report status_record
    run_report "$repo" > /dev/null 2>&1; status_report=$?
    run_report "$repo" --record > /dev/null 2>&1; status_record=$?

    if [ "$status_report" -ne 0 ]; then ok "default mode refuses on dirty own tree"; else fail "default mode refuses on dirty own tree (exit was 0)"; fi
    if [ "$status_record" -ne 0 ]; then ok "--record refuses on dirty own tree"; else fail "--record refuses on dirty own tree (exit was 0)"; fi
    assert_eq "gate was never invoked" "0" "$(counter_value "$counter")"
}

# --- test 6: --record writes an entry, runs nothing; a following report hits it ---

test6() {
    echo "test 6: --record writes an entry and runs nothing; a following git report hits it"
    local d="$WORK/t6" repo counter marker
    repo="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$repo"
    make_fake_gate_config "$repo" "$counter" "$marker"
    echo x > "$repo/f.txt"
    commit_all "$repo" init

    local status_record
    run_report "$repo" --record > /dev/null; status_record=$?
    assert_eq "--record exits 0" "0" "$status_record"
    assert_eq "--record ran no gate" "0" "$(counter_value "$counter")"

    local out status_report
    out=$(run_report "$repo"); status_report=$?
    assert_eq "following git report exits 0" "0" "$status_report"
    assert_eq "following git report is a hit (still no gate run)" "0" "$(counter_value "$counter")"
    case "$out" in
        *"recorded at commit time"*) ok "hit prints the synthesized --record attestation" ;;
        *) fail "hit prints the synthesized --record attestation (got: $out)" ;;
    esac
}

# --- test 7: a failing gate caches nothing; the next run re-runs it ---------------

test7() {
    echo "test 7: a failing gate caches nothing, the next run re-runs it"
    local d="$WORK/t7" repo counter marker
    repo="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$repo"
    make_fake_gate_config "$repo" "$counter" "$marker"
    touch "$marker"
    echo x > "$repo/f.txt"
    commit_all "$repo" init

    local status1 status2
    run_report "$repo" > /dev/null 2>&1; status1=$?
    if [ "$status1" -ne 0 ]; then ok "failing gate reports failure"; else fail "failing gate reports failure (exit was 0)"; fi
    assert_eq "failing gate still ran once" "1" "$(counter_value "$counter")"

    run_report "$repo" > /dev/null 2>&1; status2=$?
    if [ "$status2" -ne 0 ]; then ok "still failing on the next run"; else fail "still failing on the next run (exit was 0)"; fi
    assert_eq "failure was not cached (gate re-ran)" "2" "$(counter_value "$counter")"
}

# --- test 8: changing git-report itself busts the key -----------------------------

test8() {
    echo "test 8: changing git-report itself busts the key"
    local d="$WORK/t8" repo counter marker modified
    repo="$d/self"; counter="$d/counter"; marker="$d/marker"; modified="$d/git-report-modified"
    init_repo "$repo"
    make_fake_gate_config "$repo" "$counter" "$marker"
    echo x > "$repo/f.txt"
    commit_all "$repo" init

    (cd "$repo" && "$SCRIPT") > /dev/null
    assert_eq "baseline run invoked the gate once" "1" "$(counter_value "$counter")"

    cp "$SCRIPT" "$modified"
    printf '\n# harmless comment to change the script content\n' >> "$modified"
    chmod +x "$modified"

    (cd "$repo" && "$modified") > /dev/null
    assert_eq "modified script busts the key (gate re-run)" "2" "$(counter_value "$counter")"
}

# --- test 9: a dirty tree during a git-mutate sweep says so ------------------------

test9() {
    echo "test 9: a dirty tree caused by a git mutate sweep in flight is named as such"
    local d="$WORK/t9" repo counter marker out status
    repo="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$repo"
    make_fake_gate_config "$repo" "$counter" "$marker"
    echo x > "$repo/f.txt"
    commit_all "$repo" init

    echo "mutated" >> "$repo/f.txt"

    out=$(run_report "$repo" 2>&1); status=$?
    if [ "$status" -ne 0 ]; then ok "still refuses on the dirty tree"; else fail "still refuses on the dirty tree (exit was 0)"; fi
    case "$out" in
        *"sweep is in flight"*) fail "no sweep claimed when no sweep is running" ;;
        *) ok "no sweep claimed when no sweep is running" ;;
    esac

    mkdir -p "$repo/.git/git-mutate.lock"
    printf 'pid=4242\nstarted=2026-08-10T21:00:00+09:00\n' > "$repo/.git/git-mutate.lock/info"

    out=$(run_report "$repo" 2>&1); status=$?
    if [ "$status" -ne 0 ]; then ok "refusal is unchanged while a sweep is in flight"; else fail "refusal is unchanged while a sweep is in flight (exit was 0)"; fi
    case "$out" in
        *"sweep is in flight (pid 4242, since 2026-08-10T21:00:00+09:00)"*)
            ok "names the sweep, its pid and its start time" ;;
        *) fail "names the sweep, its pid and its start time (got: $out)" ;;
    esac
    case "$out" in
        *"this dirtiness is transient"*) ok "says the dirtiness is transient" ;;
        *) fail "says the dirtiness is transient" ;;
    esac
    assert_eq "gate was never invoked" "0" "$(counter_value "$counter")"
}

# --- test 10: a hit says it is cached, above the content; a fresh run says nothing ---

test10() {
    echo "test 10: a cache hit says so above the content; a fresh run says nothing"
    local d="$WORK/t10" repo counter marker
    repo="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$repo"
    make_fake_gate_config "$repo" "$counter" "$marker"
    echo x > "$repo/f.txt"
    commit_all "$repo" init

    local head fresh cached first
    head=$(git -C "$repo" rev-parse HEAD)

    # Both halves matter: without the fresh run, a notice that always fires would pass.
    fresh=$(run_report "$repo")
    case "$fresh" in
        *"this report is cached"*) fail "a fresh run prints no cached-notice" ;;
        *) ok "a fresh run prints no cached-notice" ;;
    esac

    cached=$(run_report "$repo")
    first=$(printf '%s\n' "$cached" | head -n 1)
    case "$first" in
        *"this report is cached"*) ok "the notice is the hit's first line, above the content" ;;
        *) fail "the notice is the hit's first line, above the content (line 1 was: $first)" ;;
    esac
    case "$first" in
        *"$head"*) ok "the notice names the HEAD the entry was produced at" ;;
        *) fail "the notice names the HEAD the entry was produced at (got: $first)" ;;
    esac
    case "$first" in
        *"produced at "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*)
            ok "the notice names when the entry was produced" ;;
        *) fail "the notice names when the entry was produced (got: $first)" ;;
    esac
    assert_eq "the content below the notice is the report the miss printed" \
        "$fresh" "$(body_after_notice "$cached")"
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

echo
echo "== behaviour -> test mapping =="
echo "1. cache hit runs no gate ................................ test1"
echo "2. commit in self busts the key ........................... test2"
echo "3. commit in a dependency busts the key ................... test3"
echo "4. dirty dependency: different key, no boolean collision .. test4"
echo "5. dirty own tree refused, both modes ...................... test5"
echo "6. --record writes an entry and runs nothing ............... test6"
echo "7. failing gate caches nothing .............................. test7"
echo "8. changing git-report itself busts the key ................. test8"
echo "9. a dirty tree from a git mutate sweep is named as such .... test9"
echo "10. a hit says it is cached, above the content ............... test10"
echo
echo "$TESTS_RUN assertions, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ]
