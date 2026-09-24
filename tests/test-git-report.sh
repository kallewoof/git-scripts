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
    # The attestation's own job: naming the HEAD it attests to.
    case "$out" in
        *"gate passed at $(git -C "$repo" rev-parse HEAD)"*) ok "the attestation names its HEAD" ;;
        *) fail "the attestation names its HEAD (got: $out)" ;;
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

# --- test 11: --capture is a transparent wrapper that leaves a stamped copy -------

test11() {
    echo "test 11: --capture passes the command through, keeps its status, stamps the copy"
    local d="$WORK/t11" repo pending out status
    repo="$d/self"
    init_repo "$repo"
    echo x > "$repo/f.txt"
    commit_all "$repo" init
    pending="$repo/.git/info/git-report/pending"

    out=$(run_report "$repo" --capture -- bash -c 'echo "3196 passed"; echo noise >&2; exit 7' 2>/dev/null)
    status=$?
    assert_eq "--capture exits with the command's status, not its own" "7" "$status"
    assert_eq "--capture passes the command's stdout through" "3196 passed" "$out"

    if [ -f "$pending" ]; then ok "--capture left a copy for --record"; else fail "--capture left a copy for --record"; fi
    assert_eq "the copy is stamped with the tree the commit would carry" \
        "tree=$(git -C "$repo" write-tree)" "$(head -n 1 "$pending")"
    assert_eq "the copy holds the command's output" "3196 passed" "$(tail -n +2 "$pending")"
    case "$(cat "$pending")" in
        *noise*) fail "stderr is left alone, not merged into the copy" ;;
        *) ok "stderr is left alone, not merged into the copy" ;;
    esac
}

# --- test 12: a recorded entry carries the captured summary ------------------------

test12() {
    echo "test 12: a recorded entry carries the gate's captured output, and still attests"
    local d="$WORK/t12" repo counter marker head out
    repo="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$repo"
    make_fake_gate_config "$repo" "$counter" "$marker"
    echo x > "$repo/f.txt"
    commit_all "$repo" init
    head=$(git -C "$repo" rev-parse HEAD)

    run_report "$repo" --capture -- bash -c 'echo "collected 3208 items / 3196 selected"; echo "3196 passed, 12 skipped in 41.20s"' > /dev/null
    run_report "$repo" --record

    out=$(run_report "$repo")
    assert_eq "the recorded entry still ran no gate" "0" "$(counter_value "$counter")"
    case "$out" in
        *"3196 passed, 12 skipped in 41.20s"*) ok "the hit carries the captured summary line" ;;
        *) fail "the hit carries the captured summary line (got: $out)" ;;
    esac
    case "$out" in
        *"collected 3208 items / 3196 selected"*) ok "the hit carries the captured collection line" ;;
        *) fail "the hit carries the captured collection line (got: $out)" ;;
    esac
    case "$out" in
        *"gate passed at $head, recorded at commit time"*)
            ok "the attestation and its HEAD survive alongside the output" ;;
        *) fail "the attestation and its HEAD survive alongside the output (got: $out)" ;;
    esac
    if [ -f "$repo/.git/info/git-report/pending" ]; then
        fail "--record consumes the copy it read"
    else
        ok "--record consumes the copy it read"
    fi
}

# --- test 13: no matching capture is said plainly, not papered over ----------------

test13() {
    echo "test 13: with no capture for this tree, the recorded entry says so and names the remedy"
    local d="$WORK/t13" never stale out
    never="$d/never"; stale="$d/stale"

    # (i) nothing was ever captured.
    init_repo "$never"
    echo x > "$never/f.txt"
    commit_all "$never" init
    run_report "$never" --record
    out=$(run_report "$never")
    case "$out" in
        *"carries no gate output"*) ok "an uncaptured commit says the entry carries no gate output" ;;
        *) fail "an uncaptured commit says the entry carries no gate output (got: $out)" ;;
    esac
    case "$out" in
        *"&& git report"*) ok "and names the one-line way to get one" ;;
        *) fail "and names the one-line way to get one (got: $out)" ;;
    esac

    # (ii) a capture exists, but for a tree that is no longer the committed one -- exactly
    # what a docs-only commit produces, since the pytest hook selects no files and is skipped.
    init_repo "$stale"
    echo x > "$stale/f.txt"
    commit_all "$stale" init
    run_report "$stale" --capture -- bash -c 'echo "999 passed"' > /dev/null
    echo y >> "$stale/f.txt"
    commit_all "$stale" second
    run_report "$stale" --record
    out=$(run_report "$stale")
    case "$out" in
        *"999 passed"*) fail "a capture from another tree is not passed off as this commit's" ;;
        *) ok "a capture from another tree is not passed off as this commit's" ;;
    esac
    case "$out" in
        *"carries no gate output"*) ok "and the entry says it carries no gate output" ;;
        *) fail "and the entry says it carries no gate output (got: $out)" ;;
    esac
}

# --- test 14: no capture while a mutation sweep is in flight -----------------------

test14() {
    echo "test 14: --capture writes nothing while a git mutate sweep is in flight"
    local d="$WORK/t14" repo out status
    repo="$d/self"
    init_repo "$repo"
    echo x > "$repo/f.txt"
    commit_all "$repo" init

    mkdir -p "$repo/.git/git-mutate.lock"
    printf 'pid=4242\nstarted=2026-08-10T21:00:00+09:00\n' > "$repo/.git/git-mutate.lock/info"

    out=$(run_report "$repo" --capture -- bash -c 'echo mutated-run; exit 3'); status=$?
    assert_eq "the command still runs and keeps its status" "3" "$status"
    assert_eq "its output still passes through" "mutated-run" "$out"
    if [ -f "$repo/.git/info/git-report/pending" ]; then
        fail "a mutated run's output is not left for --record"
    else
        ok "a mutated run's output is not left for --record"
    fi
}

# --- test 15: the real wiring, end to end through pre-commit ----------------------

test15() {
    echo "test 15: wired into a real commit, a following git report carries the numbers"
    local d="$WORK/t15" repo counter shim head out
    repo="$d/self"; counter="$d/counter"; shim="$d/shim.sh"
    mkdir -p "$d"
    cat > "$shim" <<'EOF'
echo RAN >> "$1"
echo "collected 3208 items / 12 deselected / 3196 selected"
echo "3196 passed, 12 skipped in 41.20s"
EOF
    init_repo "$repo"
    # The gate's own test hook, prefixed exactly as README.md tells the four repos to do it,
    # plus the post-commit --record hook. default_stages keeps the gate off the post-commit
    # stage once that stage is installed.
    cat > "$repo/.pre-commit-config.yaml" <<EOF
default_stages: [pre-commit]
repos:
  - repo: local
    hooks:
      - id: fake-pytest
        name: fake pytest
        entry: $SCRIPT --capture -- bash $shim $counter
        language: system
        always_run: true
        pass_filenames: false
        verbose: true
      - id: git-report-record
        name: git report --record
        entry: $SCRIPT --record
        language: system
        stages: [post-commit]
        always_run: true
        pass_filenames: false
EOF
    echo x > "$repo/f.txt"
    commit_all "$repo" init
    (cd "$repo" && pre-commit install --install-hooks > /dev/null 2>&1 &&
        pre-commit install --hook-type post-commit > /dev/null 2>&1) || {
        fail "test 15 could not install the hooks (skipping the rest)"
        return
    }

    # Quietly: this commit really runs the gate, and its hook output is not this suite's.
    echo y >> "$repo/f.txt"
    if (cd "$repo" && git add -A && git commit -q -m second) > "$d/commit.log" 2>&1; then
        ok "the wired commit succeeded"
    else
        fail "the wired commit succeeded ($(tail -n 5 "$d/commit.log" | tr '\n' ' '))"
    fi
    head=$(git -C "$repo" rev-parse HEAD)
    assert_eq "the commit ran the test hook exactly once" "1" "$(counter_value "$counter")"

    out=$(run_report "$repo")
    assert_eq "the following report re-ran nothing" "1" "$(counter_value "$counter")"
    case "$(printf '%s\n' "$out" | head -n 1)" in
        *"this report is cached"*) ok "it is announced as cached" ;;
        *) fail "it is announced as cached (got: $out)" ;;
    esac
    case "$out" in
        *"gate passed at $head, recorded at commit time"*) ok "it attests the commit's HEAD" ;;
        *) fail "it attests the commit's HEAD (got: $out)" ;;
    esac
    case "$out" in
        *"3196 passed, 12 skipped in 41.20s"*) ok "it carries the suite's numbers" ;;
        *) fail "it carries the suite's numbers (got: $out)" ;;
    esac
}

# --- test 16: an untracked dependency file is keyed by its content, not its name ---

test16() {
    echo "test 16: editing an untracked file in a dependency busts the key"
    local d="$WORK/t16" dep self counter marker
    dep="$d/dep"; self="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$dep"
    echo x > "$dep/d.txt"
    printf 'ignored.txt\n' > "$dep/.gitignore"
    commit_all "$dep" "dep init"

    init_repo "$self"
    make_fake_gate_config "$self" "$counter" "$marker"
    printf '../dep\n' > "$self/.git-report-deps"
    echo x > "$self/f.txt"
    commit_all "$self" "self init"

    run_report "$self" > /dev/null
    assert_eq "baseline run invoked the gate once" "1" "$(counter_value "$counter")"

    echo "state-A" > "$dep/untracked.py"
    run_report "$self" > /dev/null
    assert_eq "an untracked file appearing busts the key" "2" "$(counter_value "$counter")"

    # The one that used to be missed: status prints the name, never the content, so this edit
    # left the key untouched and replayed a report from before it.
    echo "state-B-entirely-different" > "$dep/untracked.py"
    run_report "$self" > /dev/null
    assert_eq "editing that untracked file busts the key too" "3" "$(counter_value "$counter")"

    run_report "$self" > /dev/null
    assert_eq "the same untracked content again is a cache hit" "3" "$(counter_value "$counter")"

    # And the bound on it: ignored files are not dirtiness, here or in git status.
    echo "noise" > "$dep/ignored.txt"
    run_report "$self" > /dev/null
    assert_eq "an ignored file does not bust the key" "3" "$(counter_value "$counter")"
}

# --- test 17: the cache is pruned every 30 days, keeping the 10 most recent --------

test17() {
    echo "test 17: entries are pruned after 30 days, keeping the 10 most recent"
    local d="$WORK/t17" repo counter marker cache stamp i name out
    repo="$d/self"; counter="$d/counter"; marker="$d/marker"
    init_repo "$repo"
    make_fake_gate_config "$repo" "$counter" "$marker"
    echo x > "$repo/f.txt"
    commit_all "$repo" init
    cache="$repo/.git/info/git-report"
    stamp="$cache/last-cleanup"

    # A brand new cache directory has nothing to clean, so the first run that sees one starts
    # the clock instead of sweeping.
    run_report "$repo" > /dev/null
    out=$(run_report "$repo" 2>&1 >/dev/null)
    assert_eq "a run inside the interval says nothing" "" "$out"
    if [ -f "$stamp" ]; then ok "the stamp is laid down without a sweep"; else fail "the stamp is laid down without a sweep"; fi

    # 25 entries, oldest first, one day apart, plus the three names a sweep must never touch.
    for i in $(seq 1 25); do
        name=$(printf '%064d' "$i" | tr '0-9' 'abcdef0123')
        echo "entry $i" > "$cache/$name"
        touch -d "$((2000 + i))-01-01 00:00" "$cache/$name"
    done
    echo "tree=deadbeef" > "$cache/pending"
    echo "half-written" > "$cache/.new.ABCDEF"
    printf 'epoch=%s at=long-ago\n' "$(( $(date +%s) - 31 * 24 * 60 * 60 ))" > "$stamp"

    # The real entry from the run above is the newest of the lot, so the ten survivors are it
    # plus entries 17..25.
    out=$(run_report "$repo" 2>&1 >/dev/null)
    assert_eq "the sweep announces itself" "report cleanup" "$out"
    assert_eq "ten entries survive" "10" \
        "$(find "$cache" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9a-f]{64}' | wc -l)"
    assert_eq "the oldest entry is gone" "" "$(cat "$cache/$(printf '%064d' 1 | tr '0-9' 'abcdef0123')" 2>/dev/null)"
    assert_eq "the newest of the backdated entries survives" "entry 25" \
        "$(cat "$cache/$(printf '%064d' 25 | tr '0-9' 'abcdef0123')" 2>/dev/null)"

    # A key is 64 hex characters; nothing else in the directory is, and none of it is a report.
    assert_eq "the sweep leaves 'pending' alone" "tree=deadbeef" "$(cat "$cache/pending" 2>/dev/null)"
    assert_eq "the sweep leaves a concurrent write's temp file alone" "half-written" \
        "$(cat "$cache/.new.ABCDEF" 2>/dev/null)"

    # And the cache still works: the surviving entry for this state is still a hit.
    assert_eq "the gate has run once in all of this" "1" "$(counter_value "$counter")"
    run_report "$repo" > /dev/null
    assert_eq "the surviving entry is still a cache hit" "1" "$(counter_value "$counter")"

    # The stamp is reset by the sweep, so the next run is inside the interval again.
    out=$(run_report "$repo" 2>&1 >/dev/null)
    assert_eq "the sweep does not repeat on the next run" "" "$out"
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
echo "11. --capture is transparent and stamps what it captures ..... test11"
echo "12. a recorded entry carries the captured output ............. test12"
echo "13. no capture for this tree is said plainly ................. test13"
echo "14. no capture while a mutation sweep is in flight ........... test14"
echo "15. the real wiring, end to end through pre-commit ........... test15"
echo "16. untracked dependency content is keyed, not just its name . test16"
echo "17. the cache is pruned every 30 days, 10 most recent kept ... test17"
echo
echo "$TESTS_RUN assertions, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ]
