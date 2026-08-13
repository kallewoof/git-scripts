#!/bin/bash
#
# Build `mutation-first.sh` — a single self-extracting installer carrying the mutation-first
# verification skill, the `git mutate` tool it depends on, and the manual-page redirect Git needs
# for `git mutate --help`.
#
# The point of generating rather than hand-writing it: the installer embeds `git-mutate` and the
# methodology verbatim, and a hand-maintained copy of a 975-line script drifts from the original the
# first time either is touched. Run this after changing either source.
#
# Usage:  ./make-skill.sh [output-path]        (default: ./mutation-first.sh)

set -eu

here=$(cd "$(dirname "$0")" && pwd)
tool="$here/git-mutate"
manpage="$here/git-mutate.1"
method="${METHODOLOGY:-$here/../rp-stack/context/WOULD_ANYTHING_NOTICE.md}"
out="${1:-$here/mutation-first.sh}"

[ -f "$tool" ]   || { echo "make-skill: no git-mutate beside this script" >&2; exit 1; }
[ -f "$manpage" ] || { echo "make-skill: no git-mutate.1 beside this script" >&2; exit 1; }
[ -f "$method" ] || { echo "make-skill: no methodology at $method (set METHODOLOGY=)" >&2; exit 1; }

# A delimiter that cannot appear in either payload. Checked, not assumed: a collision would end the
# heredoc early and ship a truncated tool that still looks like a tool.
for d in MUTATE_PAYLOAD_EOF MANPAGE_PAYLOAD_EOF SKILL_PAYLOAD_EOF; do
    if grep -qF "$d" "$tool" "$manpage" "$method"; then
        echo "make-skill: delimiter '$d' occurs in a payload; pick another" >&2
        exit 1
    fi
done

{
cat <<'INSTALLER_HEAD'
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
INSTALLER_HEAD

cat "$tool"

cat <<'INSTALLER_MID'
MUTATE_PAYLOAD_EOF
chmod +x "$bindir/git-mutate"

cat > "$mandir/git-mutate.1" <<'MANPAGE_PAYLOAD_EOF'
INSTALLER_MID

cat "$manpage"

cat <<'INSTALLER_MANPAGE_END'
MANPAGE_PAYLOAD_EOF

cat > "$skilldir/SKILL.md" <<'SKILL_PAYLOAD_EOF'
INSTALLER_MANPAGE_END

# --- SKILL.md: frontmatter, then the methodology verbatim -----------------------------------------
cat <<'FRONTMATTER'
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

FRONTMATTER

# The methodology, minus its own title line (the frontmatter and H1 above replace it), with this
# project's names generalised: the war stories are what make the method credible, but a reader on
# another codebase should not have to decode which repo "autorp" was.
tail -n +2 "$method" \
    | sed -e 's/\bautorp'"'"'s\b/one repository'"'"'s/g' \
          -e 's/\bautorp\b/that repository/g' \
          -e 's/\bterea\b/a shared library/g' \
          -e 's/\brp-stack\b/the project/g' \
          -e 's/^Self-contained, and the authority.*$/Self-contained: nothing below depends on any particular repository./' \
          -e '/^another project; nothing below depends on any particular repo\.$/d'

cat <<'INSTALLER_TAIL'
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

Scope note: the kill classifier reads pytest's summary format. On another test runner the tool
reports "not measured" rather than scoring your suite -- it declines rather than guessing.
NEXT
INSTALLER_TAIL
} > "$out"

chmod +x "$out"
lines=$(wc -l < "$out" | tr -d ' ')
echo "wrote $out ($lines lines)"
echo "  git-mutate:  $(wc -l < "$tool" | tr -d ' ') lines (executed, never read into context)"
echo "  SKILL.md:    $(( $(wc -l < "$method" | tr -d ' ') + 12 )) lines (this is the context cost)"
