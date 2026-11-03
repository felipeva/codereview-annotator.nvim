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
# With `squash` after the path, the parent has landed instead -- the squash trap:
#
#   master           c0 - S                S is a1 and a2 squash-merged
#   feat/A           c0 - a1 - a2          kept after the merge, as a local branch often is
#   child            c0 - S - k1'          rebased with `git rebase --onto master feat/A`
#   origin/master    S                     fetched again after the merge
#   origin/feat/A    a1                    stale: never fetched again, never pruned
#
# Both feat/A and origin/feat/A now give c0 as the merge base with child, a strict ancestor of
# S, the merge base with the default branch. A review from either reads S as work of child.
# Both refs still resolve, so only the check that compares the two merge bases can reject them.
#
# Regenerate with this script rather than hand-editing a fixture repo.
set -e
# Hermetic: no user or system git config -- see mkcheckouts.sh.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
R="${1:?usage: mkstack.sh <path> [squash]}"
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

if [ "${2:-}" = squash ]; then
  git checkout -q master
  git merge -q --squash feat/A >/dev/null
  git commit -qm "feat: land feat/A"
  # Only master, so origin/feat/A stays where the first fetch left it.
  git fetch -q origin master
  git rebase -q --onto master feat/A child
fi

echo "stack fixture: $R"
