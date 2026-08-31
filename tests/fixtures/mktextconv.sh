#!/bin/bash
# Rebuild the one fixture with a textconv filter configured.
#
# It is a repository of its own rather than two lines added to `mkfixture`, because a
# textconv driver changes what `git diff` prints for every path it is attached to: the
# binary file that fixture keeps would stop reading as binary, and the cases that prove
# binary handling would pass with binary handling deleted. A filter fixture has to be a
# repository only that filter can be told from.
#
# `git cat-file` runs no textconv filter and has no option to, so a path with one attached
# cannot be answered out of a batch. Both kinds of path are here, in one repository, which
# is the only shape in which "left out of the batch" can be told from "batched nothing".
set -e
# Hermetic: no user or system git config. Without this the fixture inherits things that
# change what it is (commit.gpgsign, diff.renames, core.autocrlf, hooks) -- gpg signing in
# particular fails outright on a machine with no key, which is every CI runner.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
R="${1:?usage: mktextconv.sh <path>}"
rm -rf "$R"; mkdir -p "$R"; cd "$R"
git init -q -b master
git config user.email t@t.t; git config user.name T

mkdir -p src
# `sed` and nothing else: the filter has to run on every machine this suite runs on, and
# what it does only has to be visible, not useful.
git config diff.cooked.textconv "sed s/RAW/COOKED/"
printf '*.bin diff=cooked\n' > .gitattributes

printf 'RAW one\nRAW two\n' > src/filtered.bin
printf 'local plain = "old"\n' > src/plain.lua
git add -A && git commit -qm base

git checkout -qb feature
printf 'RAW one\nRAW three\n' > src/filtered.bin
printf 'local plain = "new"\n' > src/plain.lua
git add -A && git commit -qm work

echo "textconv fixture: $R"
echo "  driver   : $(git config --get-regexp '^diff\..*\.textconv$')"
echo "  filtered : $(printf 'src/filtered.bin\nsrc/plain.lua\n' | git check-attr diff --stdin | tr '\n' ';')"
