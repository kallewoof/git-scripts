#!/bin/bash
#
# The committed installer is generated from `git-mutate` plus the methodology, so it goes stale the
# moment either moves. That is not hypothetical: it happened within one commit of the installer
# landing, when the exit-status fix changed the tool.
#
# A stale installer is the worst shape this could take -- it looks like a working single file and
# hands a colleague a tool that is silently a version behind.

set -u

here=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0

ok()   { echo "  ok: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }

echo "test: the committed installer matches a fresh generation"

if [ ! -f "$here/mutation-first.sh" ]; then
    bad "no committed mutation-first.sh to check"
else
    fresh=$(mktemp)
    if "$here/make-skill.sh" "$fresh" >/dev/null 2>&1; then
        if cmp -s "$fresh" "$here/mutation-first.sh"; then
            ok "mutation-first.sh is current"
        else
            bad "mutation-first.sh is STALE -- run ./make-skill.sh and commit the result"
        fi
    else
        bad "make-skill.sh failed to run"
    fi
    rm -f "$fresh"
fi

echo "test: the installer extracts a byte-identical tool"

work=$(mktemp -d)
if "$here/mutation-first.sh" --project "$work" --bin "$work/bin" >/dev/null 2>&1; then
    if cmp -s "$work/bin/git-mutate" "$here/git-mutate"; then
        ok "extracted git-mutate is byte-identical to the source"
    else
        bad "extracted git-mutate DIFFERS from the source"
    fi
    if [ -x "$work/bin/git-mutate" ]; then
        ok "extracted git-mutate is executable"
    else
        bad "extracted git-mutate is not executable"
    fi
    skill="$work/.claude/skills/mutation-first-verification/SKILL.md"
    if head -1 "$skill" 2>/dev/null | grep -qx -- "---"; then
        ok "SKILL.md opens with frontmatter"
    else
        bad "SKILL.md has no frontmatter"
    fi
else
    bad "the installer failed to run"
fi
rm -rf "$work"

echo
echo "$((pass + fail)) assertions, $fail failed"
[ "$fail" -eq 0 ]
