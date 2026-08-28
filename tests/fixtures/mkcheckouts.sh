#!/bin/bash
# Rebuild the CHECKOUTS fixture: one repository, in three checkouts of it.
#
# Distinct from the other four, and the only one whose *checkouts* are the point.
# mkfixture.sh covers every file status, mktree.sh has the directory shape, mkcommits.sh
# has the history, mkbig.sh has the size -- and each of them builds one checkout, which is
# what nothing scoped per checkout can be tested against. A second *copy* of a repository
# will not do either: two copies are two repositories, and a checkout picker reads git's
# own worktree listing of one.
#
# The shape it builds:
#
#   <path>/main      the repository itself, on master
#   <path>/agent-a   a checkout of it, on branch agent-a
#   <path>/agent-b   a checkout of it, on branch agent-b
#
# So <path> is a plain directory holding three checkouts, not a repository. That is the one
# way this script differs from the other four, which build a repository *at* the path they
# are given, and it is what keeps the whole fixture inside one directory that goes away in
# one `rm`: a checkout added beside the repository instead would be left behind by any
# caller that removes only what it was given. <path> itself is inside no repository, which
# a caller wanting a directory outside every checkout can use.
#
# Three rules ride on that shape and can be seen in no other fixture here:
#
#   * The three checkouts share one repository, so `git worktree list` names all three and
#     `--git-common-dir` is one directory. Two copies of a repository would pass anything
#     asserted about separation and nothing asserted about the listing.
#   * Each checkout is on a branch of its own, so the reviewed marks, the trim and the
#     archive that are kept per branch cannot be confused with what is kept per checkout.
#   * **src/main.lua exists at the same repository-relative path in all three.** An entry
#     captured in one checkout is therefore identical to an entry captured in another
#     everywhere but its absolute path -- which is what makes "the owning checkout is
#     derived from the entry's own paths" a claim with something to fail on. Give the
#     checkouts different file names and a rule reading the repository-relative path alone
#     passes.
#
# Each checkout carries a commit of its own over master and an uncommitted edit, so a
# branch review and a worktree review both have something to draw in each one.
#
# Regenerate with this script rather than hand-editing a fixture repo.
set -e
# Hermetic: no user or system git config. Without this the fixture inherits things that
# change what it is (commit.gpgsign, diff.renames, core.autocrlf, hooks) -- gpg signing in
# particular fails outright on a machine with no key, which is every CI runner.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
R="${1:?usage: mkcheckouts.sh <path>}"
rm -rf "$R"; mkdir -p "$R"; cd "$R"

# --- the repository, and the checkout it is opened in ---
git init -q -b master main
cd main
git config user.email fixture@example.com; git config user.name "Fixture Author"

mkdir -p src
printf 'local function main()\n  return 0\nend\n\nreturn main\n' > src/main.lua
printf 'return { port = 8080 }\n' > src/config.lua
git add -A
git commit -qm "chore: seed the repository"

# --- a checkout for each agent, on a branch of its own ---
#
# Added from the repository, so both are linked checkouts of it rather than clones.
add_checkout() {
  local name="$1" line="$2"
  git worktree add -q -b "$name" "../$name"
  (
    cd "../$name"
    # A commit of its own, so a branch review of this checkout is not empty.
    printf 'local function main()\n  %s\n  return 0\nend\n\nreturn main\n' "$line" > src/main.lua
    git add -A
    git commit -qm "feat: work in $name"
    # And work that is not committed, so a worktree review is not empty either.
    printf 'return { port = 8080, agent = "%s" }\n' "$name" > src/config.lua
  )
}
add_checkout agent-a 'local from = "agent-a"'
add_checkout agent-b 'local from = "agent-b"'

echo "checkouts fixture: $R"
echo "  main:    $R/main ($(git -C "$R/main" branch --show-current))"
echo "  agent-a: $R/agent-a ($(git -C "$R/agent-a" branch --show-current))"
echo "  agent-b: $R/agent-b ($(git -C "$R/agent-b" branch --show-current))"
echo "  checkouts of one repository: $(git -C "$R/main" worktree list | wc -l | tr -d ' ') (expect 3)"
echo "  src/main.lua in each:        $(ls "$R"/*/src/main.lua | wc -l | tr -d ' ') (expect 3)"
