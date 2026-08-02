<!--
The PR title is a Conventional Commits subject — it becomes the squash commit.
e.g. feat(panel): fold a directory subtree from the tree
-->

## Why

<!-- The problem this solves. The diff already says what changed. -->

Closes #

## Notes for the reviewer

<!--
Anything non-obvious: a constraint you hit, an approach you rejected, a design note in the
README this touches. Delete if there is nothing.
-->

## Checklist

- [ ] `make all` passes (lint + suite).
- [ ] New behaviour has a spec under `tests/codereview/`.
- [ ] `README.md` and `doc/codereview.txt` updated, if user-facing behaviour changed.
- [ ] Commits follow Conventional Commits (`make hooks` validates them).
