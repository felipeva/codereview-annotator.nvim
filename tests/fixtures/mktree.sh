#!/bin/bash
# Rebuild the NESTED fixture repo used by panel_spec (tree) and focus_spec (queue float).
#
# Distinct from mkfixture.sh, which builds a flat src/-only repo for the diff and
# annotation suites. This one exists to exercise the tree: `apps/api/src` and
# `packages/shared/src` are single-child chains that must compact, while `apps` has two
# children so it must not. Omitting any file changes the tree shape and breaks the
# structural assertions -- panel_spec is sensitive to exactly which files are present.
# Regenerate with this script rather than hand-editing a fixture repo.
set -e
# Hermetic: no user or system git config. Without this the fixture inherits things that
# change what it is (commit.gpgsign, diff.renames, core.autocrlf, hooks) -- gpg signing in
# particular fails outright on a machine with no key, which is every CI runner.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
R="${1:?usage: mktree.sh <path>}"
rm -rf "$R"; mkdir -p "$R"; cd "$R"
git init -q -b master
git config user.email t@t.t; git config user.name T

mkdir -p apps/api/src/routes apps/web/src/components packages/shared/src docs

# 10 files. The three that are never modified keep directories in the tree that carry no
# changes, so "files under a directory" and the diff's file list stay distinguishable.
ALL="apps/api/src/main.lua apps/api/src/routes/users.lua apps/api/src/routes/auth.lua
     apps/web/src/components/button.lua apps/web/src/components/modal.lua
     apps/web/src/index.lua packages/shared/src/types.lua packages/shared/src/utils.lua
     docs/guide.md README.md"
for f in $ALL; do
  printf 'local a = 1\nlocal b = 2\nlocal c = 3\n' > "$f"
done
git add -A && git commit -qm base

git checkout -qb feature
# 7 of the 10 change: 4 under apps/, plus one each under packages/, docs/, and the root.
CHANGED="apps/api/src/main.lua apps/api/src/routes/users.lua
         apps/web/src/components/button.lua apps/web/src/index.lua
         packages/shared/src/types.lua docs/guide.md README.md"
for f in $CHANGED; do
  printf 'local a = 1\nlocal b = 22\nlocal c = 3\n' > "$f"
done
git add -A && git commit -qm work

echo "tree fixture: $R"
echo "  changed files: $(git diff --name-only "$(git merge-base master HEAD)" | wc -l | tr -d ' ') (expect 7)"
echo "  under apps/:   $(git diff --name-only "$(git merge-base master HEAD)" | grep -c '^apps/') (expect 4)"
