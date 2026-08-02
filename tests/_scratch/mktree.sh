#!/bin/bash
# Rebuild the NESTED fixture repo used by t8 (tree panel) and t10 (queue focus).
#
# Distinct from mkfixture.sh, which builds a flat src/-only repo for the diff and
# annotation suites. This one exists to exercise the tree: `apps/api/src` and
# `packages/shared/src` are single-child chains that must compact, while `apps` has two
# children so it must not. Omitting any file changes the tree shape and breaks the
# structural assertions -- t8 is sensitive to exactly which files are present.
set -e
R="${1:?usage: mktree.sh <path>}"
rm -rf "$R"; mkdir -p "$R"; cd "$R"
git init -q -b master
git config user.email t@t.t; git config user.name T

mkdir -p apps/api/src/routes apps/web/src/components packages/shared/src docs

# 10 files. The three that are never modified keep directories in the tree that carry no
# changes, so "files under a directory" and the diff's file list stay distinguishable.
ALL="apps/api/src/main.ts apps/api/src/routes/users.ts apps/api/src/routes/auth.ts
     apps/web/src/components/Button.tsx apps/web/src/components/Modal.tsx
     apps/web/src/index.ts packages/shared/src/types.ts packages/shared/src/utils.ts
     docs/guide.md README.md"
for f in $ALL; do
  printf 'export const a = 1\nexport const b = 2\nexport const c = 3\n' > "$f"
done
git add -A && git commit -qm base

git checkout -qb feature
# 7 of the 10 change: 4 under apps/, plus one each under packages/, docs/, and the root.
CHANGED="apps/api/src/main.ts apps/api/src/routes/users.ts
         apps/web/src/components/Button.tsx apps/web/src/index.ts
         packages/shared/src/types.ts docs/guide.md README.md"
for f in $CHANGED; do
  printf 'export const a = 1\nexport const b = 22\nexport const c = 3\n' > "$f"
done
git add -A && git commit -qm work

echo "tree fixture: $R"
echo "  changed files: $(git diff --name-only "$(git merge-base master HEAD)" | wc -l | tr -d ' ') (expect 7)"
echo "  under apps/:   $(git diff --name-only "$(git merge-base master HEAD)" | grep -c '^apps/') (expect 4)"
