#!/bin/bash
# Rebuild the HISTORY fixture repo used by trim_float_spec (the branch's commit list).
#
# Distinct from mkfixture.sh, which builds a flat src/-only repo covering every file
# status, and from mktree.sh, whose directory shape is the point. Here the *history* is
# the point, so this is the smallest of the four: no statuses, no binary, no rename.
#
# The shape it builds, and why each part of it is there:
#
#   B0  chore: seed the repository        master
#   B1  chore: bump the year              master, and the merge base
#   c1  feat: read the config file        feature
#   c2  test: cover the config reader     feature
#   s1  fix: tighten the lexer            lexer, off B1 -- arrives through the merge
#   M   Merge branch 'lexer'              feature
#   c3  test: assert the host as well     feature, and it depends on c2
#   c4  docs: write the readme            feature
#
# `--first-parent B1..HEAD` is c4, c3, M, c2, c1. Two rules that are otherwise untestable
# ride on that:
#
#   * s1 is in `B1..HEAD` and NOT on the first-parent line, so a listing that forgot
#     `--first-parent` lists a sixth row. Without a merge the two listings are one listing
#     and nothing can tell them apart.
#   * The merge base is B1, while the oldest listed commit's parent is B0. The two are
#     different commits, which is what a trim that resolves the oldest row has to notice.
#     The lexer branch is cut from master's tip rather than from the branch point for this
#     reason alone: it is what pulls the merge base forward past B0.
#
# c3 is the one commit here that depends on another: it rewrites the line c2 introduced,
# in the file c2 added. Every other commit on the branch touches a file no other commit
# touches, so any one of them can leave the review on its own. c3 cannot, while c2 stays:
# a review that takes c3 out has to apply c3 to a tree that does not hold the file c2
# added, and that merge conflicts. A refusal that has no such commit to refuse passes
# while it measures nothing -- the recorded trap that a filter test needs a fixture only
# that filter can reject. c2 and c3 are on opposite sides of the merge on purpose: they
# are not next to each other, so taking both out applies the two of them in turn instead
# of reading a tree that some commit already has.
#
# The commits are dated apart from each other, so the relative date on a row is a fact a
# reader can check rather than "0 seconds ago" five times over. Each date is an offset back
# from the moment this script runs, which is what keeps "5 days ago" saying that however
# long the fixture has existed -- a fixed calendar date would drift into a different
# sentence every day.
#
# Regenerate with this script rather than hand-editing a fixture repo.
set -e
# Hermetic: no user or system git config. Without this the fixture inherits things that
# change what it is (commit.gpgsign, diff.renames, core.autocrlf, hooks) -- gpg signing in
# particular fails outright on a machine with no key, which is every CI runner.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
R="${1:?usage: mkcommits.sh <path>}"
rm -rf "$R"; mkdir -p "$R"; cd "$R"
git init -q -b master
# Two words, and neither of them a letter that could turn up inside a subject: a row that
# must not name the author is asserted against this string.
git config user.email fixture@example.com; git config user.name "Fixture Author"

# commit <seconds ago> <subject> -- authored and committed at the same moment, because it
# is the *author* date that `%ar` reports and the *committer* date that `git log` orders by.
#
# Seconds back from now rather than "5 days ago": the environment variables take a raw
# `<epoch> <zone>`, and only `git commit --date` reads git's friendlier date words.
NOW="$(date +%s)"
commit() {
  local when="$((NOW - $1)) +0000"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git commit -qm "$2"
}
DAY=86400
HOUR=3600

mkdir -p src

# --- master ---
printf 'local port = 8080\n' > src/config.lua
git add -A
commit $((6 * DAY)) "chore: seed the repository"

# --- the branch's own work ---
git checkout -qb feature
printf 'local port = 8080\nlocal host = "localhost"\n' > src/config.lua
git add -A
commit $((5 * DAY)) "feat: read the config file"

printf 'local cfg = require("config")\nassert(cfg.port)\n' > src/config_spec.lua
git add -A
commit $((4 * DAY)) "test: cover the config reader"

# --- master moves on, and the side branch is cut from where it moved to ---
git checkout -q master
printf 'local year = 2024\n' > src/lexer.lua
git add -A
commit $((3 * DAY)) "chore: bump the year"

git checkout -qb lexer
printf 'local year = 2025\nlocal strict = true\n' > src/lexer.lua
git add -A
commit $((2 * DAY)) "fix: tighten the lexer"

# --- the merge, and the two commits after it ---
git checkout -q feature
MERGED="$((NOW - 20 * HOUR)) +0000"
GIT_AUTHOR_DATE="$MERGED" GIT_COMMITTER_DATE="$MERGED" \
  git merge -q --no-ff -m "Merge branch 'lexer' into feature" lexer

# The assert line is the one c2 wrote, in the file c2 added: this is the commit that cannot
# leave the review while c2 stays in it.
printf 'local cfg = require("config")\nassert(cfg.port and cfg.host)\n' > src/config_spec.lua
git add -A
commit $((10 * HOUR)) "test: assert the host as well"

printf '# The project\n' > README.md
git add -A
commit $((1 * HOUR)) "docs: write the readme"

BASE="$(git merge-base master HEAD)"
echo "history fixture: $R"
echo "  on the first-parent line: $(git log --first-parent --format=%h "$BASE..HEAD" | wc -l | tr -d ' ') (expect 5)"
echo "  in the range at all:      $(git log --format=%h "$BASE..HEAD" | wc -l | tr -d ' ') (expect 6)"
echo "  merge base:               $(git rev-parse --short "$BASE") (chore: bump the year)"
echo "  oldest listed commit:     $(git log --first-parent --format=%h "$BASE..HEAD" | tail -1)"
