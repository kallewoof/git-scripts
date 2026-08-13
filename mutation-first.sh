#!/bin/bash
#
# Mutation-first verification — self-extracting installer.
#
# Installs three things:
#   1. `git-mutate`, an executable placed on your PATH. Claude runs it; it is never read into
#      context, which is why this file is an installer rather than the skill itself.
#   2. `git-mutate.1`, the redirect Git needs because it intercepts `git mutate --help` before
#      invoking external commands.
#   3. `SKILL.md`, the method. Small on purpose — it is what loads into context when the skill fires.
#
# Usage:
#   ./mutation-first.sh                 install into ./.claude/skills and ~/.local/bin
#   ./mutation-first.sh --project DIR   install the skill into DIR/.claude/skills
#   ./mutation-first.sh --bin DIR       install git-mutate into DIR
#   ./mutation-first.sh --man DIR       install git-mutate.1 into DIR
#   ./mutation-first.sh --user          install the skill into ~/.claude/skills (all projects)
#
# Requires: git, and python3 >= 3.11 (the tool parses TOML with the stdlib `tomllib`).

set -eu

SKILL_NAME="mutation-first-verification"
project="$PWD"
bindir="$HOME/.local/bin"
mandir="${XDG_DATA_HOME:-$HOME/.local/share}/man/man1"
scope="project"

while [ $# -gt 0 ]; do
    case "$1" in
        --project) project="$2"; shift 2 ;;
        --bin)     bindir="$2";  shift 2 ;;
        --man)     mandir="$2";  shift 2 ;;
        --user)    scope="user"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v git >/dev/null 2>&1 || { echo "install: git not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "install: python3 not found on PATH" >&2; exit 1; }
python3 -c 'import tomllib' >/dev/null 2>&1 || {
    echo "install: this python3 has no tomllib, which needs 3.11+ ($(python3 -V 2>&1))" >&2
    exit 1
}

if [ "$scope" = "user" ]; then
    skilldir="$HOME/.claude/skills/$SKILL_NAME"
else
    skilldir="$project/.claude/skills/$SKILL_NAME"
fi

mkdir -p "$bindir" "$mandir" "$skilldir"

cat > "$bindir/git-mutate" <<'MUTATE_PAYLOAD_EOF'
#!/bin/bash
#
# Copyright (c) 2026 Karl-Johan Alm
# Distributed under the MIT software license, see the accompanying
# file LICENSE or http://www.opensource.org/licenses/mit-license.php.

# Usage:
#   git mutate - [name...]
#                         Read TOML from standard input and run every mutation (or only the
#                         named ones), one at a
#                         time: guard it, snapshot the files it touches, apply it, run the
#                         test command, restore the tree, and classify every failing test as
#                         an assertion kill or an error kill.
#   git mutate --check - [name...]
#                         Run every guard and mutate nothing -- a fast "do my anchors still
#                         match?" loop that runs no tests.
#   git mutate <mutations-file> [name...]
#                         A file path is also accepted when another tool already produced one.
#   git mutate --recover  Restore the tree from a stale sweep's snapshot and cmp-verify it.
#                         A sweep killed with -9 cannot restore itself; nothing else can
#                         leave a mutated tree behind. Never automatic: a snapshot of
#                         unknown age restoring silently would be a data-loss bug wearing a
#                         safety mechanism's clothing.
#
#   --cmd <shell command> Test command, instead of the pytest hook found in
#                         .pre-commit-config.yaml.
#   --timeout <seconds>   Per-mutation timeout, default 900. A timeout is reported as
#                         "not measured", never as "reddened nothing".
#
# Run it UNPIPED. A sweep is slow -- one full test run per mutation, plus a baseline -- and
# it prints one line per mutation as that mutation finishes, so an unpiped run is a live
# progress report. Piping it through `grep`/`head` buys nothing (the sweep is not spammy:
# three header lines, one line per mutation, then the report) and costs everything: the
# filter blocks until the whole sweep ends, so a run that is stuck, timing out, or refusing
# every anchor looks identical to one that is working. `head` is worse -- it can SIGPIPE the
# sweep mid-mutation, which is the one way to leave a tree needing --recover.
#
# The tool is stateless. Mutations are passed on stdin for one invocation and forgotten; a
# file path is supported but there is normally no reason to create one. README.md says why a
# persistent mutations file is not offered -- briefly: anchors are coupled to the code's current text
# while tests are coupled to its behaviour, so a stale anchor either matches nothing or,
# worse, matches a comment, reddens nothing, and reports a false finding.
#
# Exit status (precedence when several apply: 4 > 3 > 2):
#     0  every selected mutation was measured and killed by at least one assertion
#     1  usage or environment error -- nothing was measured
#     2  findings: a mutation reddened nothing, or was reddened only by errors
#     3  not measured: a mutation was refused, timed out, failed to compile, produced a
#        line we cannot classify, or failed while matching nothing we can classify at all
#     4  restore verification failed -- THE TREE MAY STILL BE MUTATED
#   130  interrupted; the tree was restored
# A survivor is a finding (2), never a tool failure -- conflating them would make the tool
# useless in a pipeline.

set -u

SELF="git-mutate"
MARKER_NAME="MUTATION-SWEEP-IN-PROGRESS"
LOCK_BASENAME="git-mutate.lock"
DEFAULT_TIMEOUT=900

# Appended to any test command that looks like pytest. All four are load-bearing:
#   -p no:randomly  test order must be identical across mutations or the reddened sets are
#                   not comparable. Harmless when the plugin is absent.
#   --tb=line       makes the classification substrate exist: one summary line per failure,
#                   carrying the test id and the failure text.
#   -rfE            pytest's default report chars already include f and E; saying it out
#                   loud means a repo's own -r setting cannot take the summary away.
#   COLUMNS/NO_COLOR are set in the child environment, see run_test_cmd.

# Two texts, on purpose. usage() is the terse reminder printed beside an error, on stderr.
# help_text() is the whole interface, on stdout, and it carries the mutations-file format:
# a caller that has to go and find a README to learn the TOML schema will instead guess it,
# and the tool's own help is the only copy that cannot be installed without it.
usage() {
    cat >&2 <<'EOF'
Usage:
  git mutate - [name...]                  Read TOML from stdin; run all or named mutations.
  git mutate --check - [name...]          Read TOML from stdin; run guards only, no tests.
  git mutate <mutations-file> [name...]   A file path is also accepted.
  git mutate --recover                    Restore from a stale sweep's snapshot; cmp-verify.

  --cmd <shell command>   Test command, instead of the pytest hook in .pre-commit-config.yaml.
  --env <name>            Test ecosystem: pytest (default), mvn, go, rust, dotnet.
  --assertion-pattern <re> Extra regex that marks a message as an assertion kill.
  --timeout <seconds>     Per-mutation timeout (default 900).

For the mutations-file format, and what each guard refuses: git mutate -h
EOF
}

help_text() {
    cat <<'EOF'
git mutate -- break the code on purpose, and report whether the tests noticed.

For each mutation: guard it, snapshot the files it touches, apply it, run the test command,
restore the tree, and classify every failing test as an assertion kill (a test checks this
behaviour) or an error kill (the mutation merely broke the code, proving nothing).

Usage:
  git mutate - [name...]                  Read TOML from stdin; run all or named mutations.
  git mutate --check - [name...]          Read TOML from stdin; run guards only, no tests.
  git mutate <mutations-file> [name...]   A file path is also accepted.
  git mutate --recover                    Restore from a stale sweep's snapshot; cmp-verify.

  --cmd <shell command>   Test command, instead of the pytest hook in .pre-commit-config.yaml.
  --env <name>            Test ecosystem: pytest (default), mvn, go, rust, dotnet.
  --assertion-pattern <re> Extra regex that marks a message as an assertion kill.
  --timeout <seconds>     Per-mutation timeout (default 900).

MUTATIONS are TOML. Prefer a heredoc into 'git mutate -': it is visibly one-use, leaves no
temporary file to clean up, and cannot become a stale mutation suite by accident:

  git mutate - <<'TOML'
  [[mutation]]
  name = "history-never-sent"
  [[mutation.edit]]
  file = "src/autorp/claims.py"
  old = '''        "history": _history_anchor(played),'''
  new = '''        "history": [],'''
  TOML

'name', 'file', 'old' and 'new' are all required. Arguments after '-' select mutations by
their 'name'. A file path remains supported when another tool already produced the TOML.

'file' is relative to the repo root. Anchors are matched byte-for-byte against the file's
bytes: write them as literal ''' strings, so nothing needs escaping and the leading
indentation is part of the anchor. TOML drops a newline immediately after the opening ''',
which is what lets a multi-line anchor start on its own line:

  old = '''
        if not allowed:
            raise PermissionError(name)'''

A mutation may list several [[mutation.edit]] tables. That is how a two-part change -- add
something here, drain it there -- stays one mutation, applied and reported as one.

THE GUARDS. Each refuses that one mutation loudly, names the offending edit, and lets the
rest of the sweep run. A refusal is "not measured", never a survivor:
  - every edit's 'old' must occur exactly once in its file, with no privileged first edit
  - 'new' must differ from 'old'
  - once every edit is applied, the file must actually differ from the tree
  - an anchor sitting in a '#' comment, or inside a Python docstring, is refused: mutating
    prose reddens nothing, and would report a defended behaviour as undefended

Use 'git mutate --check -' with the same heredoc form to put the input through every guard
in seconds, running no tests and touching nothing.

THE INPUT IS EPHEMERAL. Feed it on stdin for one invocation and forget it. Anchors are
coupled to the code's current text while tests are coupled to its behaviour, so a kept
mutations file rots -- and the dangerous rot is not the anchor that stops matching, it is
the one that comes to match a comment.

RUN IT UNPIPED. A sweep is slow -- one full test run per mutation, plus a baseline -- and it
prints one line per mutation as that mutation finishes, so an unpiped run is a live progress
report. A grep/head filter blocks until the sweep ends, making a run that is stuck, timing
out or refusing every anchor look exactly like one that is working. 'head' is worse: it can
SIGPIPE the sweep mid-mutation, the one way to leave a tree needing --recover.

Exit status (precedence when several apply: 4 > 3 > 2):
    0  every selected mutation was measured and killed by at least one assertion
    1  usage or environment error -- nothing was measured
    2  findings: a mutation reddened nothing, or was reddened only by errors
    3  not measured: a mutation was refused, timed out, failed to compile, or produced
       test output this classifier cannot read
    4  restore verification failed -- THE TREE MAY STILL BE MUTATED
  130  interrupted; the tree was restored
A survivor is a finding (2), never a tool failure.
EOF
}

die() { echo "$SELF: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------------------

mode="sweep"
cmd_override=""
timeout_secs="$DEFAULT_TIMEOUT"
assertion_pattern=""
env_name=""

# Per-project defaults, so a Java or Go repo does not need the same three flags on every run.
# Lives in .git/info/ because that directory is already the home for per-clone, never-committed
# git state -- nothing here should reach a commit, for the same reason a mutations file should
# not: it describes how this checkout is tested, not what the code does.
#   env = mvn
#   cmd = cd phase1 && mvn -B test -Dtest=SerdeTimerTest
#   assertion_pattern = ^MyCustomExpectationError
#   timeout = 600
read_project_config() {
    conf="$(git rev-parse --git-dir 2>/dev/null)/info/git-mutate"
    [ -f "$conf" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        val="${val# }"
        case "$key" in
            env)               [ -z "$env_name" ] && env_name="$val" ;;
            cmd)               [ -z "$cmd_override" ] && cmd_override="$val" ;;
            assertion_pattern) [ -z "$assertion_pattern" ] && assertion_pattern="$val" ;;
            timeout)           [ "$timeout_secs" = "$DEFAULT_TIMEOUT" ] && timeout_secs="$val" ;;
            *) echo "$SELF: $conf: ignoring unknown key '$key'" >&2 ;;
        esac
    done < "$conf"
}
mutations_file=""
selected=""          # newline-separated names; empty means "all"

while [ $# -gt 0 ]; do
    case "$1" in
        --check) mode="check"; shift ;;
        --recover) mode="recover"; shift ;;
        --cmd)
            [ $# -ge 2 ] || { echo "$SELF: --cmd needs an argument" >&2; usage; exit 1; }
            cmd_override="$2"; shift 2 ;;
        --timeout)
            [ $# -ge 2 ] || { echo "$SELF: --timeout needs an argument" >&2; usage; exit 1; }
            timeout_secs="$2"; shift 2 ;;
        --assertion-pattern)
            [ $# -ge 2 ] || { echo "$SELF: --assertion-pattern needs an argument" >&2; usage; exit 1; }
            assertion_pattern="$2"; shift 2 ;;
        --env)
            [ $# -ge 2 ] || { echo "$SELF: --env needs an argument" >&2; usage; exit 1; }
            env_name="$2"; shift 2 ;;
        --env=*) env_name="${1#--env=}"; shift ;;
        -h|--help) help_text; exit 0 ;;
        -)
            if [ -z "$mutations_file" ]; then
                mutations_file="-"
            else
                selected="$selected$1
"
            fi
            shift ;;
        -*) echo "$SELF: unknown option '$1'" >&2; usage; exit 1 ;;
        *)
            if [ -z "$mutations_file" ]; then
                mutations_file="$1"
            else
                selected="$selected$1
"
            fi
            shift ;;
    esac
done

# After the flags, so an explicit flag always beats the file.
read_project_config
[ -n "$env_name" ] || env_name="pytest"

case "$env_name" in
    pytest|mvn|go|rust|dotnet) ;;
    *) die "--env takes one of: pytest, mvn, go, rust, dotnet (got '$env_name')" ;;
esac
export GIT_MUTATE_ENV="$env_name"
export GIT_MUTATE_ASSERTION_PATTERN="$assertion_pattern"

case "$timeout_secs" in
    *[!0-9]*|"") die "--timeout takes a whole number of seconds, got '$timeout_secs'" ;;
esac

if [ "$mode" = "recover" ]; then
    [ -z "$mutations_file" ] || die "--recover takes no mutations file"
else
    [ -n "$mutations_file" ] || { usage; exit 1; }
    [ "$mutations_file" = "-" ] || [ -f "$mutations_file" ] ||
        die "no such mutations file: '$mutations_file'"
fi

# ---------------------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------------------

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || die "cannot locate the git directory"
lock="$git_dir/$LOCK_BASENAME"
marker="$root/$MARKER_NAME"

# python3 does two things bash cannot do without reintroducing the escaping bugs this tool
# exists to remove: parse TOML (so multi-line anchors are literal, not escaped), and count
# and replace a literal multi-line substring. Everything else here is bash.
command -v python3 >/dev/null 2>&1 ||
    die "python3 not found on PATH (needed to parse TOML and to count/replace literal multi-line anchors)"
python3 -c 'import tomllib' >/dev/null 2>&1 ||
    die "this python3 has no tomllib, which needs 3.11+ ($(python3 -V 2>&1))"

run_prefix=""
command -v setsid >/dev/null 2>&1 && run_prefix="setsid"
command -v timeout >/dev/null 2>&1 && run_prefix="$run_prefix timeout -k 5 $timeout_secs" ||
    echo "$SELF: 'timeout' not found; running without a per-mutation timeout." >&2

SELF_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')

# ---------------------------------------------------------------------------------------
# Embedded python helpers
# ---------------------------------------------------------------------------------------

# Parse the mutations file into a directory of literal files:
#   <spec>/NNN/name              the mutation name
#   <spec>/NNN/edits/MM/{file,old,new}
# Bash then only ever reads whole files -- there is no delimiter, quoting or escaping layer
# anywhere between the anchor as written and the anchor as matched.
py_parse() {
    python3 - "$1" "$2" "$3" <<'PY'
import os
import sys
import tomllib

src, out, label = sys.argv[1], sys.argv[2], sys.argv[3]

def bad(msg):
    sys.exit("git-mutate: %s" % msg)

try:
    with open(src, "rb") as fh:
        doc = tomllib.load(fh)
except OSError as exc:
    bad("cannot read %s: %s" % (label, exc))
except tomllib.TOMLDecodeError as exc:
    bad("%s is not valid TOML: %s" % (label, exc))

muts = doc.get("mutation")
if not isinstance(muts, list) or not muts:
    bad("%s declares no [[mutation]] tables" % label)

seen = set()
for i, mut in enumerate(muts, start=1):
    if not isinstance(mut, dict):
        bad("mutation %d is not a table" % i)
    name = mut.get("name")
    if not isinstance(name, str) or not name.strip():
        bad("mutation %d has no 'name'" % i)
    if any(c in name for c in "/\t\n"):
        bad("mutation name %r may not contain '/', a tab or a newline" % name)
    if name in seen:
        bad("duplicate mutation name %r -- names identify mutations in the report" % name)
    seen.add(name)

    edits = mut.get("edit")
    if not isinstance(edits, list) or not edits:
        bad("mutation %r has no [[mutation.edit]] tables" % name)

    mdir = os.path.join(out, "%03d" % i)
    os.makedirs(mdir)
    with open(os.path.join(mdir, "name"), "wb") as fh:
        fh.write(name.encode("utf-8"))

    for j, edit in enumerate(edits, start=1):
        if not isinstance(edit, dict):
            bad("mutation %r edit %d is not a table" % (name, j))
        for key in ("file", "old", "new"):
            if not isinstance(edit.get(key), str):
                bad("mutation %r edit %d is missing a string '%s'" % (name, j, key))
        rel = edit["file"]
        if not rel or os.path.isabs(rel) or any(c in rel for c in "\t\n"):
            bad("mutation %r edit %d: file %r must be a relative path with no tab or newline"
                % (name, j, rel))
        if os.path.normpath(rel).startswith(".."):
            bad("mutation %r edit %d: file %r escapes the repository" % (name, j, rel))
        if not edit["old"]:
            bad("mutation %r edit %d: 'old' is empty; there is no such thing as an anchor "
                "that matches everywhere" % (name, j))
        edir = os.path.join(mdir, "edits", "%02d" % j)
        os.makedirs(edir)
        for key in ("file", "old", "new"):
            with open(os.path.join(edir, key), "wb") as fh:
                fh.write(edit[key].encode("utf-8"))
PY
}

# Guard one mutation and plan it. Touches nothing in the tree: on success it writes the
# post-mutation content of each affected file to <plan>/new/NNN with <plan>/files listing
# the relative paths in first-touch order, and bash writes those buffers only after it has
# taken the snapshot. On refusal it prints one line saying why and exits 10.
#
# Every edit is guarded, with no privileged first one. Edits are applied to an in-memory
# buffer in declaration order, and each edit's uniqueness is checked against the buffer as
# it will actually be patched -- so a second edit whose anchor became ambiguous (or vanished)
# because of the first is caught too.
py_plan() {
    python3 - "$1" "$2" "$3" <<'PY'
import os
import sys

root, spec, plan = sys.argv[1], sys.argv[2], sys.argv[3]

REFUSE = 10

def refuse(msg):
    print(msg)
    sys.exit(REFUSE)

def read_text(path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", "surrogateescape")

def comment_verdict(buf, idx, old, rel=""):
    """Crude, stated heuristic for 'this anchor is prose, not code'.

    Catches: an anchor preceded by a '#' on its own line, an anchor that is itself a '#'
    comment, and -- in '.py' only -- an anchor inside a triple-quoted block (the real case:
    a stale anchor that now matches only a docstring, mutating prose, reddening nothing,
    and reporting a false finding).
    Misses: // and /* */ comments, and '#' inside a string literal on the same line. It
    can also false-positive on a file whose triple quotes are unbalanced by a raw string.

    Triple quotes are not Python's alone -- TOML has them too -- so the test is scoped by
    what the block MEANS, with the file suffix as the crude proxy. In Python a triple-quoted
    block at statement level is usually prose ABOUT the code. In TOML, `key = \"\"\"...\"\"\"`
    is a value: for a prompt preset it IS the artifact under test, and mutating it is exactly
    right. Refusing those left real behaviours unmeasured and reported as such -- a worse
    outcome than the false accept it guards against, which merely reddens nothing and is
    surfaced prominently as a survivor. The '#' tests stay on for every file type: TOML
    comments are '#' too.
    """
    line_start = buf.rfind("\n", 0, idx) + 1
    if "#" in buf[line_start:idx]:
        return "the anchor sits after a '#' on its line (comment)"
    if old.lstrip().startswith("#"):
        return "the anchor is itself a '#' comment"
    if rel.endswith(".py"):
        before = buf[:idx]
        if before.count('"""') % 2 or before.count("'''") % 2:
            return "the anchor sits inside a triple-quoted block (docstring or string literal)"
    return None

edits = []
edir = os.path.join(spec, "edits")
for sub in sorted(os.listdir(edir)):
    d = os.path.join(edir, sub)
    edits.append((read_text(os.path.join(d, "file")),
                  read_text(os.path.join(d, "old")),
                  read_text(os.path.join(d, "new"))))

total = len(edits)
orig = {}
bufs = {}
order = []

for j, (rel, old, new) in enumerate(edits, start=1):
    where = "edit %d/%d" % (j, total)
    if rel not in bufs:
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            refuse("%s: '%s' is not a file in this repository" % (where, rel))
        try:
            orig[rel] = read_text(path)
        except OSError as exc:
            refuse("%s: cannot read '%s': %s" % (where, rel, exc))
        bufs[rel] = orig[rel]
        order.append(rel)

    if new == old:
        refuse("%s: 'new' is identical to 'old' in '%s' -- a no-op by construction" % (where, rel))

    count = bufs[rel].count(old)
    if count != 1:
        refuse("%s: anchor occurs %dx in '%s', must occur exactly once%s"
               % (where, count, rel,
                  " (an earlier edit of this mutation may have changed it)" if j > 1 else ""))

    idx = bufs[rel].index(old)
    verdict = comment_verdict(bufs[rel], idx, old, rel)
    if verdict is not None:
        line_no = bufs[rel].count("\n", 0, idx) + 1
        refuse("%s: %s (%s:%d) -- mutating prose proves nothing; pick an anchor in code"
               % (where, verdict, rel, line_no))

    bufs[rel] = bufs[rel][:idx] + new + bufs[rel][idx + len(old):]

# The backstop. count == 1 and new != old still do not prove the tree changed; this does,
# and it catches cases neither of those anticipate (for instance two edits that cancel out).
# A mutation that leaves the tree byte-identical and then reports "reddened nothing" is the
# worst output this tool can produce, because it is indistinguishable from a real finding.
changed = [rel for rel in order if bufs[rel] != orig[rel]]
if not changed:
    refuse("every edit applied, yet the file content is byte-identical to the tree -- "
           "this mutation changes nothing")

os.makedirs(os.path.join(plan, "new"))
with open(os.path.join(plan, "files"), "wb") as fh:
    for rel in order:
        fh.write((rel + "\n").encode("utf-8"))
for n, rel in enumerate(order, start=1):
    with open(os.path.join(plan, "new", "%03d" % n), "wb") as fh:
        fh.write(bufs[rel].encode("utf-8", "surrogateescape"))
PY
}

# Classify a captured test log into TSV rows: <kind>\t<test id>\t<message>, kind being
# A (assertion kill), E (error kill) or U (unclassifiable -- reported loudly, never folded
# silently into either bucket).
py_classify() {
    python3 - "$1" <<'PY'
import os
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")

# Trap A: pytest colorizes depending on the environment, and the line then really begins
# "\x1b[31mFAILED". Escape codes also sit *inside* the test id, so stripping has to happen
# before the id is extracted, not merely before the prefix is matched.
def strip(line):
    return ANSI.sub("", line.rstrip("\n"))

def split_id(rest):
    # "FAILED <id> - <message>". A parametrized id can itself contain " - ", so prefer the
    # last "] - " when the id is parametrized; otherwise the first " - ".
    at = rest.rfind("] - ")
    if at != -1:
        return rest[:at + 1], rest[at + 4:]
    at = rest.find(" - ")
    if at != -1:
        return rest[:at], rest[at + 3:]
    return rest, ""

# Trap B: pytest *rewrites* assertions, so a genuine assertion failure usually carries no
# exception name at all ("assert [244, 331] == [244, 434]"), sometimes carries
# "AssertionError:" (explicit message, or a repr pytest truncated), and carries "Failed:"
# for pytest.fail and for pytest.raises not raising. All three are assertion kills.
# Classifying on the string "AssertionError" scores the bare ones as error kills and
# quietly slanders a well-tested change.
# Blind spot: a helper that raises its own exception type to signal a failed expectation is
# an error kill here, and a test whose assertion message begins with an exception-like name
# could fool the assertion test. Both are visible in the reported message text.
ASSERTION = ("assert", "AssertionError", "Failed:")

# Trap B2: other ecosystems name their assertion failure something that is not "AssertionError"
# but still ends in "Error"/"Failure", so NAMED_EXC below claims it and *every* genuine assertion
# kill in that language is reported as an error kill -- a well-tested change slandered wholesale
# rather than one case at a time. Each of these is an assertion failure in its own vocabulary.
# Selected by --env; unioned with the base tuple above, since "assert" and "AssertionError" are
# near-universal and cost nothing to keep.
ENV_ASSERTION = {
    "pytest": (),
    "mvn": (
        "AssertionFailedError",    # JUnit 5 / opentest4j -- what assertEquals and AssertJ throw
        "ComparisonFailure",       # JUnit 4
        "MultipleFailuresError",   # JUnit 5 assertAll
        "Expecting",               # AssertJ, when it reports without an exception name
    ),
    "go": ("Error Trace:", "Not equal:", "expected:"),
    "rust": ("assertion",),
    "dotnet": ("AssertionException", "EqualException", "Xunit.Sdk"),
}

ENV = os.environ.get("GIT_MUTATE_ENV", "pytest")
ASSERTION = ASSERTION + ENV_ASSERTION.get(ENV, ())
_extra = os.environ.get("GIT_MUTATE_ASSERTION_PATTERN", "")
EXTRA_ASSERTION = re.compile(_extra) if _extra else None
NAMED_EXC = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*(Error|Exception|Exit|Warning|Interrupted)?:")

# Surefire/Failsafe print no FAILED/ERROR summary lines at all -- the per-test outcome lives
# only in target/*-reports/TEST-*.xml. Reading the console log therefore yields nothing to
# classify, which reports every mutation as "not measured" no matter how well tested the code
# is. Under --env mvn, classify from the XML instead and skip the console entirely.
def classify_surefire():
    import glob
    import xml.etree.ElementTree as ET

    ASSERTION_TYPES = (
        "AssertionError",
        "AssertionFailedError",
        "ComparisonFailure",
        "MultipleFailuresError",
    )
    rows = []
    paths = sorted(
        glob.glob("**/target/surefire-reports/TEST-*.xml", recursive=True)
        + glob.glob("**/target/failsafe-reports/TEST-*.xml", recursive=True)
    )
    for path in paths:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError:
            continue
        cls = root.get("name", "?").split(".")[-1]
        for case in root.iter("testcase"):
            node = case.find("failure")
            if node is None:
                node = case.find("error")
            if node is None:
                continue
            kind_name = (node.get("type") or "").split(".")[-1]
            msg = (node.get("message") or "").replace("\n", " ").replace("\t", " ").strip()
            kind = "A" if kind_name in ASSERTION_TYPES else "E"
            rows.append((kind, "%s::%s" % (cls, case.get("name", "?")), "%s: %s" % (kind_name, msg)))
    return rows

if ENV == "mvn":
    for kind, test_id, msg in classify_surefire():
        print("%s\t%s\t%s" % (kind, test_id, msg))
    sys.exit(0)

seen = set()
for raw in open(sys.argv[1], "r", encoding="utf-8", errors="replace"):
    line = strip(raw)
    match = re.match(r"^(FAILED|ERROR)\s+(\S.*)$", line)
    if not match:
        continue
    head, rest = match.group(1), match.group(2)
    test_id, msg = split_id(rest)
    if test_id in seen:
        continue
    seen.add(test_id)
    if msg.startswith(ASSERTION) or (EXTRA_ASSERTION and EXTRA_ASSERTION.search(msg)):
        kind = "A"
    elif head == "ERROR":
        # A collection or teardown error is an error kill whatever it says -- and an
        # import-time error produces these and no FAILED lines at all. An import failure
        # keeps its reason out of the summary line, so say so rather than printing nothing.
        kind = "E"
        if not msg:
            msg = "collection error (pytest keeps the reason out of the summary line)"
    elif msg and NAMED_EXC.match(msg):
        kind = "E"
    else:
        kind = "U"
    print("%s\t%s\t%s" % (kind, test_id, msg))
PY
}

# ---------------------------------------------------------------------------------------
# Lock, marker, snapshot, restore
# ---------------------------------------------------------------------------------------

work=""
holding_lock=0
RUN_PID=""

# Restores every file the manifest names -- not only the ones the current mutation touched.
# Unconditional restore cleans up after a mutation that died mid-write, and costs nothing.
# Each restore is cmp-verified; a mismatch is the loudest thing this tool can say.
restore_all() {
    local manifest="$lock/manifest" n rel snap failed=0
    [ -f "$manifest" ] || return 0
    while IFS=$'\t' read -r n rel || [ -n "$n" ]; do
        [ -n "$n" ] || continue
        snap="$lock/snap/$n"
        if [ ! -f "$snap" ]; then
            echo "$SELF: MISSING SNAPSHOT for '$rel' ($snap) -- cannot restore it" >&2
            failed=1
            continue
        fi
        cp -p "$snap" "$root/$rel" 2>/dev/null || {
            echo "$SELF: FAILED TO WRITE '$rel' back from $snap" >&2
            failed=1
            continue
        }
        cmp -s "$snap" "$root/$rel" || {
            echo "$SELF: RESTORE VERIFICATION FAILED for '$rel' (snapshot: $snap)" >&2
            failed=1
        }
    done < "$manifest"
    return "$failed"
}

# Snapshot a file, unless it is already in the manifest. The first snapshot of a path is the
# authoritative one: it was taken from the tree before this sweep touched anything.
snapshot_file() {
    local rel="$1" manifest="$lock/manifest" n
    if [ -f "$manifest" ] && cut -f2 "$manifest" | grep -Fxq -- "$rel"; then
        return 0
    fi
    mkdir -p "$lock/snap"
    n=0
    [ -f "$manifest" ] && n=$(wc -l < "$manifest" | tr -d ' ')
    n=$(printf '%04d' "$((n + 1))")
    cp -p "$root/$rel" "$lock/snap/$n" || return 1
    printf '%s\t%s\n' "$n" "$rel" >> "$manifest"
}

kill_run() {
    [ -n "$RUN_PID" ] || return 0
    # Kill the process group we started, by the pgid we own. Never a name match: a
    # `pkill -f <script>` in an earlier harness matched its own backgrounded shell and
    # killed the job before it patched anything.
    local pgid
    pgid=$(ps -o pgid= -p "$RUN_PID" 2>/dev/null | tr -d ' ')
    if [ -n "$pgid" ] && [ -n "$SELF_PGID" ] && [ "$pgid" != "$SELF_PGID" ]; then
        kill -TERM "-$pgid" 2>/dev/null
        sleep 1
        kill -KILL "-$pgid" 2>/dev/null
    else
        kill -TERM "$RUN_PID" 2>/dev/null
    fi
    RUN_PID=""
    return 0
}

release() {
    [ "$holding_lock" -eq 1 ] || return 0
    rm -f "$marker"
    rm -rf "$lock"
    holding_lock=0
}

on_exit() {
    local rc=$?
    trap - EXIT INT TERM HUP
    kill_run
    if [ "$holding_lock" -eq 1 ]; then
        if ! restore_all; then
            cat >&2 <<EOF

$SELF: ============================================================================
$SELF: RESTORE FAILED. THE WORKING TREE MAY STILL BE MUTATED.
$SELF: Snapshots are in $lock/snap (see $lock/manifest).
$SELF: The lock and marker are being kept on purpose so nothing else samples this
$SELF: tree; 'git mutate --recover' retries the restore. Do NOT commit until it is clean.
$SELF: ============================================================================
EOF
            [ -n "$work" ] && rm -rf "$work"
            exit 4
        fi
        release
    fi
    [ -n "$work" ] && rm -rf "$work"
    exit "$rc"
}

on_signal() {
    local sig="$1"
    echo "" >&2
    echo "$SELF: $sig received -- killing the test command and restoring the tree." >&2
    kill_run
    exit 130
}

# ---------------------------------------------------------------------------------------
# --recover
# ---------------------------------------------------------------------------------------

if [ "$mode" = "recover" ]; then
    [ -d "$lock" ] || die "no sweep state at $lock -- nothing to recover"
    pid=$(sed -n 's/^pid=//p' "$lock/info" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        die "a sweep is still running (pid $pid). Refusing to restore under a live sweep."
    fi
    if [ ! -f "$lock/manifest" ]; then
        echo "$SELF: the stale sweep had snapshotted nothing; clearing its lock and marker." >&2
        rm -f "$marker"
        rm -rf "$lock"
        exit 0
    fi
    echo "$SELF: restoring from the snapshot the stale sweep took:"
    while IFS=$'\t' read -r n rel || [ -n "$n" ]; do
        [ -n "$n" ] || continue
        if cmp -s "$lock/snap/$n" "$root/$rel"; then
            echo "  already identical  $rel"
        else
            echo "  restoring          $rel"
        fi
    done < "$lock/manifest"
    holding_lock=1
    if ! restore_all; then
        echo "$SELF: RESTORE FAILED; lock kept at $lock." >&2
        exit 4
    fi
    release
    echo "$SELF: tree restored and cmp-verified; lock and marker cleared."
    exit 0
fi

# ---------------------------------------------------------------------------------------
# Parse the mutations file and pick the mutations to run
# ---------------------------------------------------------------------------------------

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "$work"' EXIT       # replaced by on_exit once the lock is held

mkdir "$work/spec"
mutations_source="$mutations_file"
mutations_label="'$mutations_file'"
if [ "$mutations_file" = "-" ]; then
    mutations_source="$work/stdin.toml"
    mutations_label="standard input"
    cat > "$mutations_source" || die "cannot read mutations from standard input"
fi
py_parse "$mutations_source" "$work/spec" "$mutations_label" || exit 1

mut_dirs=""
for d in "$work"/spec/*; do
    name=$(cat "$d/name")
    if [ -n "$selected" ] && ! printf '%s' "$selected" | grep -Fxq -- "$name"; then
        continue
    fi
    mut_dirs="$mut_dirs$d
"
done

if [ -n "$selected" ]; then
    while IFS= read -r want; do
        [ -n "$want" ] || continue
        found=0
        for d in "$work"/spec/*; do
            [ "$(cat "$d/name")" = "$want" ] && found=1
        done
        [ "$found" -eq 1 ] || die "no mutation named '$want' in $mutations_file"
    done <<< "$selected"
fi

[ -n "$mut_dirs" ] || die "no mutations selected"
n_selected=$(printf '%s' "$mut_dirs" | grep -c .)

# ---------------------------------------------------------------------------------------
# --check: guards only. Mutates nothing, runs nothing, needs no lock.
# ---------------------------------------------------------------------------------------

if [ "$mode" = "check" ]; then
    echo "$SELF --check: $n_selected mutation(s) from $mutations_file (no tests run, tree untouched)"
    refused=0
    i=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        i=$((i + 1))
        name=$(cat "$d/name")
        plan="$work/plan.$i"
        mkdir -p "$plan"
        if out=$(py_plan "$root" "$d" "$plan" 2>&1); then
            echo "  ok       $name  ($(tr '\n' ' ' < "$plan/files"))"
        else
            echo "  REFUSED  $name  ${out:-(no reason given)}"
            refused=$((refused + 1))
        fi
    done <<< "$mut_dirs"
    echo
    if [ "$refused" -gt 0 ]; then
        echo "$SELF: $refused mutation(s) would be refused; nothing was measured."
        exit 3
    fi
    echo "$SELF: every anchor is unique, in code, and changes the file."
    exit 0
fi

# ---------------------------------------------------------------------------------------
# Take the lock. A second concurrent sweep in the same repo must refuse rather than
# interleave: two sweeps mutating one tree would attribute each other's edits.
# ---------------------------------------------------------------------------------------

if ! mkdir "$lock" 2>/dev/null; then
    pid=$(sed -n 's/^pid=//p' "$lock/info" 2>/dev/null)
    started=$(sed -n 's/^started=//p' "$lock/info" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        die "a 'git mutate' sweep is already in flight in '$root' (pid $pid, since ${started:-unknown}).
    Refusing to interleave: the tree can only hold one mutation at a time."
    fi
    {
        echo "$SELF: a previous sweep (pid ${pid:-unknown}, since ${started:-unknown}) left state at"
        echo "$SELF:   $lock"
        echo "$SELF: and is no longer running -- it was killed hard enough that it could not restore."
        if [ -f "$lock/manifest" ]; then
            echo "$SELF: it had snapshotted these files, which may still be mutated:"
            cut -f2 "$lock/manifest" | sed "s/^/$SELF:   /"
        fi
        echo "$SELF: run 'git mutate --recover' to restore them from that snapshot and cmp-verify."
        echo "$SELF: Refusing to restore automatically: a snapshot of unknown age restoring silently"
        echo "$SELF: would revert real work under the guise of a safety mechanism."
    } >&2
    exit 1
fi
holding_lock=1
trap on_exit EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

{
    echo "pid=$$"
    echo "host=$(hostname 2>/dev/null)"
    echo "started=$(date -Is 2>/dev/null || date)"
    echo "mutations=$mutations_file"
} > "$lock/info"

# The marker is untracked and deliberately NOT gitignored: its whole job is to be glaring in
# `git status`, so that anything sampling this repo mid-sweep -- git report, another worker,
# a human -- sees why the tree is dirty instead of concluding a mutation was left behind.
cat > "$marker" <<EOF
A 'git mutate' sweep is in flight in this repository.

  pid:        $$
  host:       $(hostname 2>/dev/null)
  started:    $(date -Is 2>/dev/null || date)
  mutations:  $mutations_file

While a mutation is applied, tracked files in this tree are MODIFIED on purpose and the test
gate is RED. Do not conclude anything about this repository's state until the sweep finishes
and this file disappears.

If no such process is running, the sweep was killed before it could restore: run
'git mutate --recover' to put the tree back from the snapshot it took.

This file is untracked and deliberately not gitignored -- it exists to show up in
'git status'. 'git mutate' removes it when the sweep ends.
EOF

# ---------------------------------------------------------------------------------------
# Resolve the test command
# ---------------------------------------------------------------------------------------

# The tension: a narrow test subset is fast but can miss a mutation reddening something
# outside it, while the whole pre-commit gate is slow and -- worse -- not measurable, since
# ruff or basedpyright failing reddens the gate while reddening no test, which would print
# as "reddened nothing": a broken measurement wearing a finding's clothes. Resolution: run
# the gate's *own* pytest hook, with the gate's own selection (so nothing is narrowed by
# us), minus coverage (a coverage floor failing is not a test reddening, and it taxes every
# mutation), plus the flags that make classification possible.
resolve_test_cmd() {
    local cfg="$root/.pre-commit-config.yaml" entries count
    if [ -n "$cmd_override" ]; then
        test_cmd="$cmd_override"
        test_cmd_source="--cmd"
    else
        [ -f "$cfg" ] || {
            echo "$SELF: no --cmd given, and no .pre-commit-config.yaml in '$root' to take a test command from." >&2
            return 1
        }
        entries=$(sed -n 's/^[[:space:]]*entry:[[:space:]]*//p' "$cfg" | grep -E '(^|[[:space:]/])pytest([[:space:]]|$)')
        count=$(printf '%s' "$entries" | grep -c .)
        if [ "$count" -eq 0 ]; then
            echo "$SELF: no pytest hook in $cfg. Pass the test command with --cmd." >&2
            return 1
        fi
        if [ "$count" -gt 1 ]; then
            echo "$SELF: $cfg has $count pytest hooks:" >&2
            printf '%s\n' "$entries" | sed "s/^/$SELF:   /" >&2
            echo "$SELF: refusing to guess which one measures behaviour. Pass one with --cmd." >&2
            return 1
        fi
        # Drop coverage: a --cov-fail-under failing is not a test reddening, and coverage
        # would be paid once per mutation for nothing.
        test_cmd=$(printf '%s' "$entries" | sed -E 's/(^|[[:space:]])--cov[^[:space:]]*//g; s/[[:space:]]+$//')
        test_cmd_source=".pre-commit-config.yaml"
    fi
    # Add the flags classification depends on, unless the command already sets them. Only
    # for a pytest command: any other command is run exactly as given.
    case "$test_cmd" in
        *pytest*)
            case "$test_cmd" in *"-p no:randomly"*) ;; *) test_cmd="$test_cmd -p no:randomly" ;; esac
            case "$test_cmd" in *--tb=*) ;; *) test_cmd="$test_cmd --tb=line" ;; esac
            case "$test_cmd" in *" -r"*) ;; *) test_cmd="$test_cmd -rfE" ;; esac
            ;;
    esac
    return 0
}

test_cmd=""
test_cmd_source=""
resolve_test_cmd || exit 1

# ---------------------------------------------------------------------------------------
# Running the test command
# ---------------------------------------------------------------------------------------

RUN_TIMEDOUT=0

# NO_COLOR and COLUMNS are belt to the ANSI-stripping braces, and COLUMNS is load-bearing in
# its own right: pytest truncates each summary line to the terminal width, and a pipe means
# 80 columns, which silently eats the failure text of any test with a long id -- leaving a
# line we cannot classify at all.
run_test_cmd() {
    local log="$1" st
    RUN_TIMEDOUT=0
    # Surefire reports persist between runs, and a mutation that fails to compile writes no new
    # ones. Reading the previous run's passing XML would report that mutation as a survivor --
    # a false finding, which is the one output this tool must never produce. Clear them first so
    # "no reports" means "nothing ran", not "nothing failed".
    #
    # Deliberately narrow: -type f and a -path that must END at the report file, so the parent
    # really is target/surefire-reports and not merely some path containing "/target/". Deleting
    # only the XML the classifier reads means no directory is ever removed, so a repo with its
    # own docs/target/annual-reports keeps it. No rm, no -rf, no -exec: find's own -delete
    # cannot be handed a path it did not match.
    if [ "${GIT_MUTATE_ENV:-pytest}" = "mvn" ]; then
        find "$root" -type f \
            \( -path '*/target/surefire-reports/TEST-*.xml' \
            -o -path '*/target/failsafe-reports/TEST-*.xml' \) \
            -delete 2>/dev/null
    fi
    # stdin from /dev/null: the sweep loop reads its mutation list from a here-string, and a
    # test command inheriting that stdin could eat it.
    ( cd "$root" && exec env NO_COLOR=1 COLUMNS=1000 $run_prefix bash -c "$test_cmd" ) \
        < /dev/null > "$log" 2>&1 &
    RUN_PID=$!
    # Backgrounding plus wait, rather than running in the foreground, is what lets a ^C run
    # the trap immediately instead of after the test command finishes.
    wait "$RUN_PID"
    st=$?
    RUN_PID=""
    [ "$st" -eq 124 ] && RUN_TIMEDOUT=1
    return "$st"
}

# ---------------------------------------------------------------------------------------
# Baseline: what is red before any mutation
# ---------------------------------------------------------------------------------------

echo "$SELF: $n_selected mutation(s) from $mutations_file"
echo "$SELF: test command ($test_cmd_source): $test_cmd"
echo "$SELF: sweep in flight; '$MARKER_NAME' marks this tree as transiently dirty."
echo

baseline_ids="$work/baseline.ids"
: > "$baseline_ids"
run_test_cmd "$work/baseline.log"
baseline_rc=$?
py_classify "$work/baseline.log" > "$work/baseline.rows"
if [ "$RUN_TIMEDOUT" -eq 1 ]; then
    die "the unmutated test command timed out after ${timeout_secs}s. Nothing can be measured; raise --timeout."
fi
# A failing baseline that matches no FAILED/ERROR line at all is not "no pre-existing
# failures" -- it is a suite this classifier cannot read, and every mutation afterwards would
# be scored against a measurement that was never real. Refuse before sweeping, the same way an
# ambiguous or missing pytest hook refuses below.
if [ "$baseline_rc" -ne 0 ] && [ ! -s "$work/baseline.rows" ]; then
    die "the unmutated test command exited $baseline_rc but produced no line this classifier
recognises as FAILED/ERROR ('$test_cmd'). The classifier is pytest-shaped: it cannot tell a
real failure from another runner's output, so no mutation afterwards would be measurable.
Pass a pytest-compatible command with --cmd."
fi
if grep -q '^E' "$work/baseline.rows"; then
    {
        echo "$SELF: the unmutated suite is red with errors:"
        awk -F'\t' '$1=="E" {print "  " $2 "  " $3}' "$work/baseline.rows" | sed "s/^/$SELF:/"
        echo "$SELF: nothing is measurable while the suite errors -- every mutation would look like a kill."
    } >&2
    exit 1
fi
awk -F'\t' '$1!="E" {print $2}' "$work/baseline.rows" > "$baseline_ids"
n_baseline=$(wc -l < "$baseline_ids" | tr -d ' ')
if [ "$n_baseline" -gt 0 ]; then
    {
        echo "$SELF: WARNING: $n_baseline test(s) already fail before any mutation:"
        sed "s/^/$SELF:   /" "$baseline_ids"
        echo "$SELF: they are excluded from every mutation's kills -- a test already red cannot be a kill."
        echo
    } >&2
fi

# ---------------------------------------------------------------------------------------
# The sweep
# ---------------------------------------------------------------------------------------

mkdir "$work/res"

i=0
while IFS= read -r d; do
    [ -n "$d" ] || continue
    i=$((i + 1))
    idx=$(printf '%03d' "$i")
    name=$(cat "$d/name")
    res="$work/res/$idx"
    printf '%s' "$name" > "$res.name"
    printf '[%d/%d] %s ... ' "$i" "$n_selected" "$name"

    plan="$work/plan.$idx"
    mkdir -p "$plan"
    if ! why=$(py_plan "$root" "$d" "$plan" 2>&1); then
        echo "REFUSED: $why"
        echo "refused" > "$res.status"
        printf '%s' "$why" > "$res.note"
        continue
    fi

    # Snapshot at mutation time, from the tree about to change -- never a snapshot directory
    # populated earlier by something else, which would revert legitimate work on restore.
    snap_ok=1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        snapshot_file "$rel" || { snap_ok=0; break; }
    done < "$plan/files"
    if [ "$snap_ok" -ne 1 ]; then
        echo "REFUSED: could not snapshot the files this mutation touches"
        echo "refused" > "$res.status"
        printf '%s' "could not snapshot the files this mutation touches" > "$res.note"
        continue
    fi

    # Apply. Writing through cat keeps the file's inode and mode.
    n=0
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        n=$((n + 1))
        cat "$plan/new/$(printf '%03d' "$n")" > "$root/$rel"
    done < "$plan/files"

    run_test_cmd "$work/log.$idx"
    mut_rc=$?
    timed_out="$RUN_TIMEDOUT"

    # Restore before doing anything else with the result, so that even a bug in the
    # reporting below cannot leave the tree mutated.
    if ! restore_all; then
        exit 4
    fi

    if [ "$timed_out" -eq 1 ]; then
        echo "TIMED OUT after ${timeout_secs}s -- not measured"
        echo "timeout" > "$res.status"
        printf 'the test command timed out after %ss; this mutation was not measured' "$timeout_secs" > "$res.note"
        continue
    fi

    py_classify "$work/log.$idx" > "$res.rows.all"
    if [ "$n_baseline" -gt 0 ]; then
        awk -F'\t' 'NR==FNR {seen[$0]=1; next} !($2 in seen)' "$baseline_ids" "$res.rows.all" > "$res.rows"
    else
        cp "$res.rows.all" "$res.rows"
    fi

    n_a=$(awk -F'\t' '$1=="A" {n++} END {print n+0}' "$res.rows")
    n_e=$(awk -F'\t' '$1=="E" {n++} END {print n+0}' "$res.rows")
    n_u=$(awk -F'\t' '$1=="U" {n++} END {print n+0}' "$res.rows")
    printf '%s %s %s\n' "$n_a" "$n_e" "$n_u" > "$res.counts"

    # A mutation that does not compile was never put to the tests, so nothing was learned about
    # them. Saying so plainly beats every alternative: "reddened nothing" blames the tests for a
    # mutation they never saw, and an error kill implies a test ran and threw. In a compiled
    # language this is common enough that it needs its own sentence, not a bucket to interpret.
    compile_note=""
    if [ -s "$work/log.$idx" ]; then
        compile_note=$(grep -m1 -E "cannot find symbol|COMPILATION ERROR|Unresolved compilation|error: .*expected|SyntaxError|cannot be resolved" \
            "$work/log.$idx" 2>/dev/null | sed 's/^[[:space:]]*//; s/\x1b\[[0-9;]*m//g' | cut -c1-160)
    fi
    if [ -z "$compile_note" ] && [ -s "$res.rows.all" ]; then
        compile_note=$(awk -F'\t' '$3 ~ /Unresolved compilation|cannot be resolved|cannot find symbol/ {print $3; exit}' "$res.rows.all" | cut -c1-160)
    fi

    if [ -n "$compile_note" ]; then
        echo "compilation failed -- not measured"
        echo "compile-failed" > "$res.status"
        # Surefire puts "Unresolved compilation problem:" in the message attribute and the
        # offending symbol in the stack trace, so the note can arrive detail-less; say the
        # useful half rather than trailing a bare colon.
        compile_note=$(printf '%s' "$compile_note" | sed 's/[[:space:]]*:[[:space:]]*$//')
        printf 'error: compilation failed, so the tests never ran against this mutation (%s)' \
            "$compile_note" > "$res.note"
    elif [ "$n_u" -gt 0 ]; then
        echo "unclassifiable output -- not measured"
        echo "unclassified" > "$res.status"
        # Naming one offending line turns "unclassifiable" from a verdict into a lead: it is
        # almost always a missing " - <message>" suffix, or an assertion type this --env does
        # not know, and both are obvious the moment you can see the line.
        sample=$(awk -F'\t' '$1=="U" {print $2 " - " $3; exit}' "$res.rows")
        printf '%s line(s) matched FAILED/ERROR but carry no failure text we can classify (env=%s); first was: %s' \
            "$n_u" "$GIT_MUTATE_ENV" "$sample" > "$res.note"
    elif [ ! -s "$res.rows.all" ] && [ "$mut_rc" -ne 0 ]; then
        # The command failed, so this is not a well-defended behaviour -- it is a suite this
        # classifier cannot read. Reporting it as a survivor would be worse than an error: it
        # reads as a real finding in the tool whose whole purpose is to prevent exactly that.
        # Tested against the UNFILTERED classify output, not the baseline-excluded one: a
        # mutation that only reddens an already-baseline-red test also exits non-zero, but the
        # classifier read it fine -- the baseline filter emptying res.rows there is by design,
        # not a sign of an unreadable format.
        echo "test command exited $mut_rc but matched nothing -- not measured"
        echo "unclassified" > "$res.status"
        printf 'the test command exited %s but produced no FAILED/ERROR line this pytest-shaped classifier recognises; pass a pytest-compatible command with --cmd' "$mut_rc" > "$res.note"
    elif [ "$n_a" -eq 0 ] && [ "$n_e" -eq 0 ]; then
        echo "reddened nothing"
        echo "survived" > "$res.status"
    elif [ "$n_a" -eq 0 ]; then
        echo "reddened $n_e, all by error -- proves nothing"
        echo "error-only" > "$res.status"
    else
        echo "reddened $((n_a + n_e)): $n_a by assertion, $n_e by error"
        echo "killed" > "$res.status"
    fi
done <<< "$mut_dirs"

# ---------------------------------------------------------------------------------------
# Report. Findings first: a mutation that reddened nothing, or only by error, is the thing
# worth thinking about. No percentage and no score -- "killed 9/10" invites chasing a
# number, "this mutation reddened nothing" invites thought.
# ---------------------------------------------------------------------------------------

print_rows() {
    local res="$1" want="$2" label="$3"
    [ -f "$res.rows" ] || return 0
    awk -F'\t' -v want="$want" -v label="$label" \
        '$1==want {printf "      %-9s %s -- %s\n", label, $2, $3}' "$res.rows"
}

# Statuses are printed in the order given, not in file order: a mutation that reddened
# nothing is the finding worth reading first.
section() {
    local title="$1" any=0 want f res status name note
    shift
    for want in "$@"; do
    for f in "$work"/res/*.status; do
        [ -f "$f" ] || continue
        res="${f%.status}"
        status=$(cat "$f")
        [ "$status" = "$want" ] || continue
        if [ "$any" -eq 0 ]; then
            echo
            echo "== $title =="
            any=1
        fi
        name=$(cat "$res.name")
        note=""
        [ -f "$res.note" ] && note=$(cat "$res.note")
        case "$status" in
            survived)
                echo "  $name: reddened nothing."
                echo "      No test in this run distinguishes the mutated code from the original."
                ;;
            error-only)
                read -r a e u < "$res.counts"
                echo "  $name: reddened $e, ALL BY ERROR -- proves nothing."
                echo "      An error kill says the mutation broke the code, not that a test checks the behaviour."
                print_rows "$res" E error
                ;;
            refused)
                echo "  $name: REFUSED -- $note"
                ;;
            timeout|unclassified|compile-failed)
                echo "  $name: NOT MEASURED -- $note"
                ;;
            killed)
                read -r a e u < "$res.counts"
                echo "  $name: reddened $((a + e)) -- $a by assertion, $e by error."
                print_rows "$res" A assertion
                print_rows "$res" E error
                ;;
        esac
    done
    done
    return 0
}

echo
echo "======================================================================"
section "FINDINGS -- read these first" survived error-only
section "NOT MEASURED -- the sweep is incomplete here" refused unclassified timeout compile-failed
section "KILLED BY ASSERTION" killed
echo

count_status() {
    local wanted="$1" f n=0
    for f in "$work"/res/*.status; do
        [ -f "$f" ] || continue
        case " $wanted " in *" $(cat "$f") "*) n=$((n + 1)) ;; esac
    done
    echo "$n"
}

n_findings=$(count_status "survived error-only")
n_unmeasured=$(count_status "refused timeout unclassified compile-failed")
n_killed=$(count_status "killed")

echo "$SELF: $n_killed killed by assertion, $n_findings finding(s), $n_unmeasured not measured."

if [ "$n_unmeasured" -gt 0 ]; then
    exit 3
fi
if [ "$n_findings" -gt 0 ]; then
    exit 2
fi
exit 0
MUTATE_PAYLOAD_EOF
chmod +x "$bindir/git-mutate"

cat > "$mandir/git-mutate.1" <<'MANPAGE_PAYLOAD_EOF'
.TH GIT-MUTATE 1 "August 2026" "git-mutate" "Git Manual"
.SH NAME
git-mutate \- break the code on purpose and report whether the tests noticed
.SH DESCRIPTION
Git handles
.B \-\-help
before invoking external subcommands, so the complete help is provided by the command's
.B \-h
option instead:
.PP
.RS
.B git mutate \-h
.RE
.PP
That help includes the mutations-file format, a worked example, the guards, and the exit statuses.
MANPAGE_PAYLOAD_EOF

cat > "$skilldir/SKILL.md" <<'SKILL_PAYLOAD_EOF'
---
name: mutation-first-verification
description: >-
  Verify that tests actually defend the behaviour they name, by breaking the behaviour and watching
  what fails. Use when reviewing your own or someone else's tests, before trusting a green suite,
  when a change is load-bearing enough that a silent regression would go unnoticed, or when writing a
  spec someone else will implement. Provides `git mutate`, installed on PATH by this skill.
---

# Mutation-first verification

`git mutate` is installed on your PATH by this skill. It is a tool you run, not a file to read —
`git mutate --help` is the interface, and reading its source into context is wasted budget.


Self-contained: nothing below depends on any particular repository.

The one-sentence version: **a test that would still pass if the behaviour it names were broken is not
evidence, and the only way to find out is to break the behaviour and watch.**

---

## Why coverage is not the thing

Coverage answers *"did this line execute?"*. That question is satisfied by any test written from the
implementation — which is what you get whenever code and tests are authored in the same sitting by the same
author, because there is nothing to disagree with the code except the code.

Observed on one 1039-line module at **100% coverage with 47 tests**: three separate bugs of the same shape in
one function, a prefix check no test distinguished from substring matching, a test asserting the broken
outcome as though it were the contract, and a mock keyed wrongly so it never exercised the function it named.
Every one of those passed. Coverage measured effort, not correctness.

Mutation asks the question coverage cannot: **would anything notice if this changed?** That cannot be
satisfied by paraphrasing the code, because answering it requires knowing what the code is *for*.

## The loop

**Use `git mutate` (in `git-scripts`, on `PATH`). Do not hand-roll a harness.** Prefer
one-use TOML on stdin: `git mutate -` runs it, and `git mutate --check -` validates its
anchors without running tests. Use a heredoc as shown by `git mutate -h`; it leaves no temp
file to clean up or accidentally preserve after its anchors have gone stale.

**Run it unpiped.** It prints one line per mutation as that mutation finishes, so an unpiped run is a
live progress report. A `grep`/`head` filter blocks until the whole sweep ends — a run that is stuck or
refusing every anchor then looks exactly like one that is working — and `head` can SIGPIPE the sweep
mid-mutation, the one way to leave a tree needing `--recover`.

**Your job is choosing the mutation.** That is the whole intellectual content and the tool cannot do it. Its
job is everything mechanical, and *that* is where the errors have actually landed:

- **Four environment-dependent settings**, every one of which silently produces a *wrong number* rather than
  an error. ANSI colour defeats a `startswith("FAILED")` filter, and whether pytest colours through a pipe
  depends on `FORCE_COLOR` — the same script over the same mutations gave **0 red** for one person and
  **6 red** for another. `COLUMNS` truncates each summary line to the terminal width, 80 through a pipe, so a
  long test id loses its failure message entirely: **92% of one repository's test ids** are long enough for that. Add
  `-p no:randomly` (comparable orderings) and `--tb=line` (the line the classification reads).
- **Kill classification.** pytest *rewrites* assertions, so a real assertion failure usually prints as a bare
  `assert x == y` with no exception name. Keying on `"AssertionError"` scores a well-tested change as
  half error-kills. The tool reports assertion-kills, error-kills and *unclassifiable* separately — an
  error-only kill proves nothing, and so does a line it could not read.
- **Anchor guards.** Exactly one match, on *every* edit rather than a privileged first one; `new` different
  from `old`; the file actually changed; and a refusal when a **Python** anchor sits in a docstring — the real case
  that motivated it (`max_tokens=1`) passed a uniqueness check while matching only a comment about removed
  behaviour.
- **Snapshot, restore, `cmp`** on every exit path including interruption. Never `git checkout` — it discards
  uncommitted work, including other people's.

**⚠ A mutation count is a claim of measurement. Never write one you have not run.** Observed: a worker
wrote a commit message's figures from their *plan* rather than from a sweep, then ran it and found **two of
seven mutations survived** — so the numbers were wrong and two behaviours were undefended. They corrected it,
but a number written from a plan is indistinguishable from a measured one, and in a commit message it is
permanent and nobody re-checks it. The same applies to a spec quoting a baseline, a report quoting a gate,
and a summary quoting a rate.

**Read the report per behaviour, never as a score.** "29 mutations, 29 killed" hides which behaviours are
actually defended. A behaviour with zero reddening tests, or one reddened only by errors, is the finding.

A behaviour with **zero** reddening tests is a finding, not a formality. Twice here a survivor was a live
defect: a prefix match that had silently become a substring match, and a guard subsumed by later checks.

## The five traps

These are empirical. Each one produced a false "verified" in practice.

**1. A mutation that raises proves nothing.** If your edit makes the code throw before reaching the guard, the
red test is telling you about the exception, not the guard. Check *why* each test failed — you want
`AssertionError` or `DID NOT RAISE`, not `KeyError`, `NameError`, or a collection error. Re-run it
well-formed: change a value, invert a condition, `if False and …` — something that still runs.

**2. A mutation that does not exercise the guard proves nothing either.** You can aim at the wrong mechanism
and conclude a good test is vacuous. Real case: forcing an `embodied` property to `True` left a keep-rule
test green, which looked like a broken test — but the test called the presence function directly and never
routed through that property. Mutating the actual short-circuit reddened it immediately. **Before concluding
a test is weak, confirm your mutation reached the code the test depends on.**

**And the inverse is the one nothing warns you about: a kill does not prove the mutation reached the
behaviour you named.** Real case: a mutation meant to break "scans every position, not sampled ones"
replaced the scan with a half-window stride. It was killed — but *not* by the misalignment fixture written
for exactly that property, because at that stride the fixture's period stayed phase-aligned and the fixture
never noticed. The count said "killed"; the behaviour was untested. **Check which tests reddened, not how
many** — a mutation that dies for the wrong reason is indistinguishable, in a total, from one that dies for
the right one.

**3. An assertion is vacuous if the fixture never supplies its subject.** A test asserting "X does not appear"
passes trivially when the fixture contains no X. Real case: a swap test placed the operation immediately
after the first setup call, where the value it asserted was legitimately absent — so the assertion held
before *and* after the fix, and encoded the bug as the contract. Fixtures must supply what the assertion
denies.

**4. A test parametrized over the constant it validates vanishes with the value it protects.** If the expected
value is read from the same constant the code reads, changing the constant changes both sides and nothing
fails. Golden values must be literals.

**5. A no-op mutation must be detected, not reported.** If your anchor does not match — a renamed symbol, a
reformatted line — you have changed nothing and the green suite means nothing. Always check the anchor before
writing, and treat a miss as an error. Real case: guessing `rfind` where the implementation used a scanning
loop; the check caught it, and without it the result would have been a confident false pass.

**Presence is not uniqueness — assert `count == 1`, not `anchor in source`.** An anchor matching two identical
lines passes an `in` check while `replace(..., 1)` silently edits the first one, so the mutation lands
somewhere you did not intend and the tests that stay green are the wrong tests. Observed twice: a prompt
string appearing verbatim in two blocks, and two identical lines in one function. Both times the `in` check
passed and the mutation missed. Re-anchor on surrounding lines until the match is unique — and note that one
of those misfires exposed a genuinely undefended behaviour, so a caught no-op is worth chasing rather than
just correcting.

`git mutate` enforces all five mechanically, and `--check` validates every anchor without running anything.
**Knowing the traps is still yours**: the tool can refuse a malformed mutation, but only you can notice that
a well-formed one aims at the wrong mechanism.

## Verifying someone else's work

**Reproduce their numbers, don't accept them.** Re-run at least the gate and one or two of their most
load-bearing mutations independently. Matching counts is cheap confidence; a mismatch is the whole point.

**Establish attribution before accepting "pre-existing".** When a report says a failure is unrelated, check:
which commit introduced the failing test, whether their diff touches it, and whether the failure message
names something they changed. Twice here the attribution was correct and once the *mechanism* given for it
was invented — same conclusion, wrong cause, which matters because the wrong cause gets fixed.

**Read the mechanism before asserting a cause.** The most reliable error in this session was concluding *why*
something failed from its symptom and writing that into a spec. Four times. Each time the correction came
from opening the file. If you are about to write "X is broken because Y", open Y first.

**Beware editable installs.** If packages are installed editable, `import pkg` reads the working tree — so
while someone else is mid-task, you are measuring *their uncommitted work*. Check `git status` before
measuring library behaviour, or read the committed revision in an isolated worktree
(`git worktree add --detach`). A finding was retracted here on the strength of code nobody had committed.

**Verify consumers, not just the thing.** Stripping vendored fixtures to their minimum was verified against
the one function that read them; two other suites loaded the same directories a different way and broke.
Checking the thing in front of you is not checking everything that reads it.

## Specs, if you write work for others to do

**Inline every must-follow rule.** The spec is the only channel to the person doing the work. Assume they
cannot see your memories, your conventions file, or this document. Repeat the traps in every spec.

**Require `git mutate` by name, and say why.** A worker told only "mutation-test it" writes a harness, and
the harness is where the silent failures live — four environment settings that produce a wrong count rather
than an error, and a kill classifier that is backwards by default. Naming the tool is one line; the
consequences of omitting it are a confident, wrong report.

**State the measured baseline and require it be re-measured.** "Gate green" is not a number. Ask for the
test count *before* the first edit, quoted.

**Say what is out of scope and why**, especially for things you noticed and deliberately left. Otherwise the
next person re-derives it, or worse, guesses at it.

**Do not specify a fix you have not read the code for.** Twice here a spec told a worker to fix a mechanism
that was already correct, or to add something that already existed. A good worker pushes back; that costs
them a round trip and costs you credibility.

**Ask for failures to be reported.** A report of "29 mutations, 29 killed" with no mention of the malformed
ones, the no-ops, or the survivors is less trustworthy than one that names them. The best reports here
included "this mutation was a no-op, re-run as follows" and "this survivor was a real defect, now fixed".

## Three structural smells worth naming

**Silent defaults hide absence.** `getattr(obj, "thing", "")` turns "unknown" into "empty", and empty is a
legal value that composes without complaint. Where a value's absence matters, make reading it fail —
`getattr` with a default only suppresses `AttributeError`, so a property raising `ValueError` propagates
through existing call sites untouched.

**Tests must not read mutable state someone regenerates.** A test that reads a live output artifact passes
until the artifact is regenerated, then fails for reasons unrelated to any code change. Snapshot the shape
into the test.

**A test that pins configuration is a lock, not a test.** It passes for as long as nobody changes their mind,
fails the moment somebody legitimately does, and the only way past is to edit the assertion — which nobody
does thoughtfully by the third time. Three landed in that repository and all three had to be dealt with in one day: a
resolved-spec baseline that was a **one-shot migration proof** left as a permanent test (deleted); a goldens
byte-pin that fires on every legitimate change, so the hash is updated as routine and stops being read; and
two tests that scanned shipped presets for a setting, going vacuous when that setting was measured harmful
and removed — keeping it alive to satisfy them was never an option.

The distinction: *"shipped configuration still passes the production gate"* is a real check and survives a
retune. *"Shipped configuration still contains X"* is hostage to it. **Pin the gate, not the value** — and
where a test needs a configuration with some property, **build it inside the test** rather than requiring the
shipped tree to keep providing one.

## When not to do this

Mutation testing is slow — minutes per mutation on a large suite, and a careful pass over one task can be an
hour. It earns that on load-bearing behaviour: guards, invariants, anything whose silent failure produces a
plausible-looking wrong answer. It does not earn it on formatting, on code whose failure is loud and
immediate, or on a throwaway script.

The judgement call is not "is this important" but **"if this broke silently, how long until anyone noticed?"**
Where the answer is "a long time, and the output would still look reasonable", mutate it.
SKILL_PAYLOAD_EOF

echo "installed:"
echo "  $bindir/git-mutate"
echo "  $mandir/git-mutate.1"
echo "  $skilldir/SKILL.md"
echo
case ":$PATH:" in
    *":$bindir:"*) ;;
    *) echo "NOTE: $bindir is not on your PATH. Add it, or the skill cannot run the tool."; echo ;;
esac
cat <<'NEXT'
To make the skill discoverable without being asked for by name, add a line to CLAUDE.md:

    ## Testing
    - Verify load-bearing behaviour with the `mutation-first-verification` skill: break the
      behaviour a test names and confirm that test is what fails. A green suite is not evidence
      until something has been broken.

Scope note: the kill classifier reads pytest's summary format by default. For another ecosystem
pass --env (mvn, go, rust, dotnet), or set it once per repo in .git/info/git-mutate; --env mvn also
reads Surefire XML, since Maven prints no summary lines to classify. On a runner it still cannot
read, the tool reports "not measured" rather than scoring your suite -- it declines rather than
guessing.
NEXT
