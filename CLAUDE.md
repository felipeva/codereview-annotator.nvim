# CLAUDE.md

Operating instructions for agents working in `codereview-annotator.nvim`.

"Always talk in ASD-STE100 Simplified Technical English. Always read CONTEXT.md files, and use their ubiquitous language."

## Workflow for new changes

Anything with a feature or design decision behind it runs through the skill chain below,
in order. Do not skip to code.

1. **`/to-prd`** — synthesises the conversation into a PRD and publishes it to the issue
   tracker (a GitHub issue here) labelled `ready-for-agent`. It does not interview; it
   works from what has already been discussed, so do that discussion first.
2. **`/to-issues`** — breaks the PRD into independently-grabbable issues, one per vertical
   slice.
3. **Branch off the issue id**: `<type>/<issue>-<slug>`, e.g.
   `feat/12-single-annotation-queue`. `<type>` is the Conventional Commits type the work
   will land under, so the branch, the commits and the PR title all agree.
4. **Commit** per the rules below. The `commit-msg` hook validates every one.
5. **Open the PR** with `gh pr create`. The title is a Conventional Commits subject; the
   body closes the issue (`Closes #12`).

Both PRD skills are `disable-model-invocation: true` — **the user invokes them.** Ask for
`/to-prd` rather than trying to run it, and never hand-roll a PRD to work around that.

Straight-to-`master` is only for what has no issue behind it: docs corrections,
formatting, CI plumbing. Anything a PRD was written for gets a branch and a PR.

`CONTRIBUTING.md` is the same workflow written for outside contributors. Change both when
one moves, or they drift.

## Commits

**Conventional Commits, enforced by `.githooks/commit-msg`.** Install it once per clone —
git does not version hooks itself, so nothing carries without this:

```sh
make hooks     # git config core.hooksPath .githooks
```

Subject: `<type>(<optional scope>)!: <description>`

- types: `build` `chore` `ci` `docs` `feat` `fix` `perf` `refactor` `revert` `style` `test`
- description: lowercase imperative, no trailing period
- subject at most 72 characters, blank line before the body
- body explains **why**, not what — the diff already says what

`test` is canonical. The three commits predating the hook use `tests:`, which it now
rejects; leave that history alone.

## Verifying a change

`make all` (lint + the full suite) before committing anything under `lua/`. It takes about
five seconds. See `tests/README.md` for the layout and the traps.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues (`felipeva/codereview-annotator.nvim`), via the `gh` CLI. The repo is public, so external PRs **are** a triage surface — an outside contributor often states a request as a PR and never files an issue. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical label vocabulary, unmodified: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Design notes

`docs/design-notes.md` records every non-obvious constraint that cost real debugging time,
grouped by subsystem. Several obvious-looking approaches here are wrong for reasons reading
the code does not reveal — read the relevant group before changing rendering, diff parsing,
blob hashing, reference resolution, or anything touching windows and modes.
