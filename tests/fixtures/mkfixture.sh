#!/bin/bash
# Rebuild the flat review fixture repo deterministically.
#
# Ordering matters: every `git commit` sweeps up whatever is staged, so the staged and
# unstaged working state is established LAST and nothing is committed after it.
#
# The sources are Lua and Markdown rather than TypeScript on purpose. Neovim core ships
# both parsers and their `highlights` queries, so syntax_spec exercises the real
# harvest/replay path on a bare Neovim -- no nvim-treesitter, no compiler in CI.
set -e
# Hermetic: no user or system git config. Without this the fixture inherits things that
# change what it is (commit.gpgsign, diff.renames, core.autocrlf, hooks) -- gpg signing in
# particular fails outright on a machine with no key, which is every CI runner.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
R="${1:?usage: mkfixture.sh <path>}"
rm -rf "$R"; mkdir -p "$R"; cd "$R"
git init -q -b master
git config user.email t@t.t; git config user.name T

# --- base commit on master ---
mkdir -p src
printf 'local app = require("app")\nlocal cfg = load()\napp.listen(cfg.port)\n' > src/main.lua
printf 'local a = 1\nlocal b = 2\n' > src/routes.lua
printf 'local gone = true\n' > src/gone.lua
# Three lines, not two: git's rename detection compares whole lines, so a two-line file
# with one line rewritten lands at 47% similarity -- just under the 50% default -- and the
# rename silently degrades into an add plus a delete. For the same reason this file stays
# ASCII: lengthening line one pushes the similarity index back under the threshold.
printf 'local name = "old"\nlocal second = 2\nlocal third = 3\n' > src/oldname.lua
# The fixture's only non-ASCII content, and it is deliberate. Everything else here is
# ASCII, and an ASCII line CANNOT fail the byte-splitting bug -- a span computed over bytes
# passes every assertion an ASCII fixture can make. é/è share their leading byte, as do
# 🎉/🎈, so a byte-wise diff emphasises a trailing byte alone: a boundary inside a
# character, which is a rendering error. It rides on the line this file already changes, so
# no count anywhere moves and nothing else has to know.
printf '# no trailing newline café 🎉' > src/nonl.md
printf 'x\0y\0binary\n' > src/blob.bin
printf 'ignored.txt\n' > .gitignore
git add -A && git commit -qm base

# --- committed work on the feature branch ---
git checkout -qb feature
printf 'local app = require("app")\nlocal cfg = load_config()\napp.listen(cfg.port)\n' > src/main.lua  # modify
git rm -q src/gone.lua                                                                          # delete
git mv src/oldname.lua src/newname.lua                                                          # rename...
printf 'local name = "new"\nlocal second = 2\nlocal third = 3\n' > src/newname.lua               # ...+ edit
printf 'local function fresh() end\n' > src/fresh.lua                                            # add
printf '# no trailing newline CHANGED cafè 🎈' > src/nonl.md   # both sides lack a trailing newline
git add -A && git commit -qm work

# --- uncommitted working state (must be last) ---
printf 'local a = 1\nlocal staged = 3\nlocal b = 2\n' > src/routes.lua
git add src/routes.lua                                         # staged: +1
printf 'local a = 1\nlocal staged = 3\nlocal b = 2\nlocal unstaged = 4\n' > src/routes.lua
                                                               # unstaged: +1 on top
printf 'local brand = "new"\nlocal second = 2\n' > src/untracked.lua   # untracked text
printf 'z\0z\n' > src/untracked.bin                            # untracked binary
printf 'secret\n' > ignored.txt                                # gitignored: must never appear

echo "fixture: $R"
echo "  branch   : $(git diff --numstat "$(git merge-base master HEAD)" | wc -l | tr -d ' ') tracked files"
echo "  staged   : $(git diff --cached --numstat | tr '\t' ' ' | tr '\n' ';')"
echo "  unstaged : $(git diff --numstat | tr '\t' ' ' | tr '\n' ';')"
echo "  untracked: $(git ls-files --others --exclude-standard | tr '\n' ' ')"
