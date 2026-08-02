# CLAUDE.md

Operating instructions for agents working in `codereview-annotator.nvim`.

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

Issues live in this repo's GitHub Issues (`felipeva/codereview-annotator.nvim`), via the `gh` CLI. External PRs are **not** a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical label vocabulary, unmodified: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
