#!/bin/bash
# Rebuild the review fixture repo deterministically.
#
# Ordering matters: every `git commit` sweeps up whatever is staged, so the staged and
# unstaged working state is established LAST and nothing is committed after it.
set -e
R="${1:?usage: mkfixture.sh <path>}"
rm -rf "$R"; mkdir -p "$R"; cd "$R"
git init -q -b master
git config user.email t@t.t; git config user.name T

# --- base commit on master ---
mkdir -p src
printf 'const app = express()\nconst cfg = load()\napp.listen(cfg.port)\n' > src/main.ts
printf 'export const a = 1\nexport const b = 2\n' > src/routes.ts
printf 'delete me\n' > src/gone.ts
printf 'rename me\nsecond line\n' > src/oldname.ts
printf 'no trailing newline' > src/nonl.ts
printf 'x\0y\0binary\n' > src/blob.bin
printf 'ignored.txt\n' > .gitignore
git add -A && git commit -qm base

# --- committed work on the feature branch ---
git checkout -qb feature
printf 'const app = express()\nconst cfg = loadConfig()\napp.listen(cfg.port)\n' > src/main.ts   # modify
git rm -q src/gone.ts                                                                            # delete
git mv src/oldname.ts src/newname.ts                                                             # rename...
printf 'renamed now\nsecond line\n' > src/newname.ts                                             # ...+ edit
printf 'export function fresh() {}\n' > src/fresh.ts                                             # add
printf 'no trailing newline CHANGED' > src/nonl.ts            # both sides lack a trailing newline
git add -A && git commit -qm work

# --- uncommitted working state (must be last) ---
printf 'export const a = 1\nSTAGED LINE\nexport const b = 2\n' > src/routes.ts
git add src/routes.ts                                          # staged: +1
printf 'export const a = 1\nSTAGED LINE\nexport const b = 2\nUNSTAGED LINE\n' > src/routes.ts
                                                               # unstaged: +1 on top
printf 'brand new\nsecond\n' > src/untracked.ts                # untracked text
printf 'z\0z\n' > src/untracked.bin                            # untracked binary
printf 'secret\n' > ignored.txt                                # gitignored: must never appear

echo "fixture: $R"
echo "  branch   : $(git diff --numstat "$(git merge-base master HEAD)" | wc -l | tr -d ' ') tracked files"
echo "  staged   : $(git diff --cached --numstat | tr '\t' ' ' | tr '\n' ';')"
echo "  unstaged : $(git diff --numstat | tr '\t' ' ' | tr '\n' ';')"
echo "  untracked: $(git ls-files --others --exclude-standard | tr '\n' ' ')"
