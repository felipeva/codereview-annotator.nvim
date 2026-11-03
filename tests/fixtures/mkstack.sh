#!/bin/bash
# Rebuild the STACK fixture: a stacked branch, which no other fixture has.
#
#   master           c0
#   feat/A           c0 - a1 - a2          forked from master
#   child            c0 - a1 - a2 - k1     forked from feat/A, checked out
#   origin/feat/A    a1                    one commit behind the local feat/A
#   origin/master    c0                    and origin/HEAD points at it
#
# Three refs, three different merge bases with child: origin/master gives c0, origin/feat/A
# gives a1, feat/A gives a2. A test of a **base branch** needs that, or a review measured from
# the wrong one reads the same `before` and passes. origin/feat/A is behind on purpose, so a
# remote-tracking ref stored as typed and the local branch of the same name cannot be told
# apart only by the label.
#
# The remote is this repository itself (`git remote add origin .`), fetched once, so the
# fixture is one directory and nothing in the plugin ever fetches it again. Each commit adds
# a file of its own, so the paths in a review say which commits it holds.
#
# Regenerate with this script rather than hand-editing a fixture repo.
set -e
# Hermetic: no user or system git config -- see mkcheckouts.sh.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
R="${1:?usage: mkstack.sh <path>}"
rm -rf "$R"; mkdir -p "$R"; cd "$R"

git init -q -b master
git config user.email fixture@example.com; git config user.name "Fixture Author"

commit() {
  printf '%s\n' "$1" > "$1.txt"
  git add -A
  git commit -qm "feat: add $1"
}

commit c0
git checkout -q -b feat/A
commit a1

# The remote, while feat/A is at a1 and master at c0.
git remote add origin .
git fetch -q origin
git remote set-head origin master

commit a2
git checkout -q -b child
commit k1

echo "stack fixture: $R"
