#!/bin/bash
# Rebuild the large fixture repo used by tests/perf.lua and by bounded_spec.
#
# 60 files of 200 lines by default, with half of every file rewritten on the feature
# branch: roughly 12k rendered rows once headers and context are counted. Sized to be the
# shape that actually hurt -- a review big enough that parsing every file up front is a
# second of latency on open.
#
# Both counts are arguments because one size cannot show everything: every cost in the
# review view is linear in the size of the diff, so `perf.lua` asks for this same shape at
# 60 files and again at 300, where a keystroke and a repaint are large enough to read a
# change from, and `bounded_spec` asks for 6 -- the smallest that renders a diff taller
# than a window and the margin around it, which is the only size at which a bounded paint
# can be told from an unbounded one.
set -e
# Hermetic: no user or system git config. Without this the fixture inherits things that
# change what it is (commit.gpgsign, diff.renames, core.autocrlf, hooks) -- gpg signing in
# particular fails outright on a machine with no key, which is every CI runner.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
R="${1:?usage: mkbig.sh <path> [files] [lines]}"
FILES="${2:-60}"
LINES="${3:-200}"
rm -rf "$R"; mkdir -p "$R"; cd "$R"
git init -q -b master
git config user.email t@t.t; git config user.name T

mkdir -p src
for f in $(seq 1 "$FILES"); do
  awk -v n="$LINES" 'BEGIN { for (i = 1; i <= n; i++) printf "local value_%d = compute(%d, \"seed\")\n", i, i }' \
    > "src/mod_$f.lua"
done
git add -A && git commit -qm base

git checkout -qb feature
for f in $(seq 1 "$FILES"); do
  # Every other line changes, so the diff interleaves rather than collapsing into one
  # enormous hunk -- which is what the anchor map and the viewport-bounded syntax pass
  # actually have to cope with.
  awk -v n="$LINES" 'BEGIN {
    for (i = 1; i <= n; i++) {
      if (i % 2 == 0) printf "local value_%d = compute(%d, \"changed\")\n", i, i
      else printf "local value_%d = compute(%d, \"seed\")\n", i, i
    }
  }' > "src/mod_$f.lua"
done
git add -A && git commit -qm work

echo "big fixture: $R"
echo "  files: $(git diff --name-only "$(git merge-base master HEAD)" | wc -l | tr -d ' ')"
echo "  lines: $(git diff --numstat "$(git merge-base master HEAD)" | awk '{ s += $1 + $2 } END { print s }')"
