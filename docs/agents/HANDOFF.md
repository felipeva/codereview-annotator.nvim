# Handoff — codereview-annotator.nvim

**The test suite is in, and the host cutover is done.** `tests/_scratch/` is gone;
everything it proved now lives in `tests/codereview/*_spec.lua` under plenary, with CI.
Features are a ranked backlog at the bottom — **do not start them without grilling the item
first.**

## Where things are

| What | Where |
| --- | --- |
| Plugin repo | `~/Codes/lua/codereview-annotator.nvim` (`master`) |
| GitHub | https://github.com/felipeva/codereview-annotator.nvim |
| Neovim config wiring | `~/.config/nvim/lua/plugins/codereview.lua` (`dir =` spec + 3 adapters) |
| Design rationale | `docs/design-notes.md` — read this before changing anything |
| User-facing docs | `doc/codereview.txt` |
| Contributor workflow | `CLAUDE.md` for agents, `CONTRIBUTING.md` for humans — change both together |
| **Tests** | `tests/README.md` — layout, fixtures, what is deliberately not covered |

The plugin is ~4,500 lines across 15 modules. It renders a unified syntax-highlighted git
diff with a folder-tree panel, typed annotations that queue up, reviewed-file collapsing,
and a batch submit through injected adapters. It works and is in daily use.

Capture is the second entry point: `require("codereview").annotate(type)` queues an
annotation about the current buffer with no review open, and it is the **only** public
capture seam — extend it rather than adding a sibling. The host cutover deleted
`claude_queue.lua` and `claude_review.lua`; `<leader>aq` and `<leader>aR` now call
`annotate()` and `queue()`.

## What the port ended up as

377 cases across 14 spec files, ~540 assertions, under five seconds. `make test` runs
`PlenaryBustedDirectory` over `tests/codereview/`, one Neovim per spec file, each building
its own throwaway fixture.

| Spec | From | Covers |
| --- | --- | --- |
| `types_spec` | new | configurable annotation types: defaulting, validation, custom type end to end |
| `diff_spec` | `t1` | scope resolution, unified-diff parsing, rename/binary/untracked, blob hashing |
| `render_spec` | `t2` | anchor map, byte columns, navigation, collapse, panel, scope cycling |
| `syntax_spec` | `t3` | treesitter harvest/replay, caching, guardrails |
| `annotate_spec` | `t4` | targeting, cross-file clamp, deleted-line rule, types, drop |
| `payload_spec` | `t5` | grouping, `@ref` vs inline, out-of-tree fallback, submit |
| `state_spec` | `t6a`+`t6b` | persistence across processes, blob invalidation, corrupt files |
| `panel_spec` | `t8` | tree build, chain compaction, folding, subtree review, navigation |
| `focus_spec` | `t10` | queue-float focus across the async picker, submit closing the float |
| `viewless_spec` | new (#7) | queue persists and restores with no review view; reviewed marks for unopened scopes |
| `capture_spec` | new (#9, #10) | buffer capture: whole file, selection, command range, diagnostics riding along |
| `staleness_spec` | new (#11) | a buffer capture judged against the file on disk, not the diff on screen |
| `norepo_spec` | new (#13) | the `note` kind, files outside a checkout, the global store and its sweep |
| `interactive_spec` | `pty_test.py` | the insert-mode leak, in a real pty-backed Neovim |
| `perf.lua` | `perf2.lua` | open-time report on a 60-file diff — deliberately not in CI |

Four of those drive a second Neovim rather than asserting in-process —
`viewless_child.lua`, `capture_child.lua`, `norepo_child.lua`, `state_child.lua`. The queue
restores **once per session** (`state.ensure_queue` latches), so anything testing restore or
clobbering needs a second *process*, not an in-process reset.

Decisions worth not re-litigating, and the four things that changed along the way:

- **Fixtures are Lua and Markdown, not TypeScript.** Neovim core ships both parsers *and*
  their `highlights` queries, so `syntax_spec` exercises the real replay path on a bare
  Neovim. CI needs plenary and nothing else — no nvim-treesitter, no compiler. One
  typescript case marks itself `pending` when the parser is absent.
- **The rename fixture is three lines, not two.** git compares whole lines, so a two-line
  file with one line rewritten lands at 47% similarity — under the 50% default — and the
  rename silently degrades into an add plus a delete.
- **git config is neutralised** in both the fixture scripts and `minimal_init.lua`
  (`GIT_CONFIG_GLOBAL=/dev/null`). Inherited settings change what a fixture *means*:
  `diff.renames = false` breaks the rename case, and `commit.gpgsign` makes building a
  fixture depend on a gpg agent — which no CI runner has.
- **`make test-file`, never `:PlenaryBustedFile`.** That command spawns a child without
  `-u`, so it loads your real config instead of `tests/minimal_init.lua` and the plugin
  is found only by accident of the cwd.

`interactive_spec` was verified to have teeth: with the `BufEnter`/`WinEnter`/`InsertEnter`
autocmd in `view.lua` and the `stopinsert` in `annotate.lua` removed, it fails with
`mode='i'` and `]h` stops navigating — the exact reported symptom. Re-check that after any
change near the composer.

## Backlog — ranked

Ordered by value-per-effort. Every item builds on the existing anchor map (`render.lua`)
unless noted. All four themes are under-specified on purpose — `/grilling` first.

**1. Diff fidelity** — cheapest real quality jump.
Word-level intra-line highlighting so a one-token change stops looking like two rewritten
lines; `-w` ignore-whitespace toggle; `-U` context adjustment without reopening; per-hunk
folding. All operate on machinery that already exists.

**2. Review workflow** — the papercuts hit every session.
Edit an annotation in place instead of drop-and-retype; undo a drop; jump from a queue entry
back to its line; auto-mark a file reviewed once every hunk in it has been visited;
`:CodeReviewExport review.md`.

**3. Ecosystem polish** — what it needs before being shareable.
`:checkhealth codereview`; native telescope/fzf-lua/snacks picker support instead of plain
`vim.ui.select`; statusline component over `require("codereview").count()`;
`:CodeReview <file>` for a single path.

**4. GitHub PR integration** — largest by far; treat as its own project.
`:CodeReview pr 123` via `gh pr diff`, and submitting posts annotations back as a real PR
review with inline comments. Needs new scope resolution, a second delivery backend, and
comment-position mapping that GitHub is strict about (`line` + `side`, against the diff's
post-image). Do not start this alongside anything else.

## Known gaps and sharp edges

- **`git diff` long tail**: submodules, mode-only changes, and combined (merge) diffs are
  not handled. They should degrade to a visible "unsupported entry" row rather than a stack
  trace — currently untested either way, and called out as such in `tests/README.md`.
- ~~**Symlinked roots.**~~ Fixed in #17. `payload.resolve_base()` realpaths the delivery
  target's `cwd` once per submit, so an adapter may report either form. Only that side
  needed it — every `abs_path` is already canonical, from `git rev-parse --show-toplevel`
  or from capture's own `fs_realpath`. `relative_to` stays a pure string predicate on
  purpose; do not move the resolution into it. The suite runs from `$TMPDIR`, so on macOS
  `payload_spec` exercises a genuinely symlinked root for free — and on Linux, where the
  two forms coincide, that case marks itself `pending` rather than passing vacuously.
- **The gitsigns diff base is gone.** The host's `claude_review.start()` also called
  `gitsigns.change_base(merge_base, true)`, which made `]h`/`[h` walk branch-relative hunks
  in ordinary buffers. The plugin never touched gitsigns, so the cutover removed that with
  nothing replacing it. Deliberate, but it is the one behaviour the cutover lost — if `]h`
  feels wrong outside a review, this is why.
- **The local delivery path still needs claudecode.nvim.** `util.claude.deliver` falls back
  to `deliver_local` when no target is chosen, and that requires `claudecode`. Picking a
  herdr target avoids it entirely, and since #16 a picked target sticks with no review view
  open. Removing claudecode.nvim was considered and deferred; doing it later means either
  always picking a target or changing that fallback.
- **The no-repository store bounds growth, not staleness.** Accepted in the PRD and
  documented in both the README and `:help codereview-persistence-norepo`. An old note about
  a scratch file can still claim a line span that has moved, and nothing will ever flag it.
- **Everything here is world-readable.** The repo is open source under MIT, so commits,
  issues and PRs are public. External PRs are a triage surface — see
  `docs/agents/issue-tracker.md`.
- **Perf budget**: opening a 60-file / 12k-line diff is ~120 ms on a bare Neovim (the
  ~290–400 ms figure was with nvim-treesitter loaded). Two things keep it there —
  viewport-bounded syntax harvesting and batched blob hashing. `make perf` reports it and
  fails past a deliberately loose ceiling; if it regresses, suspect one of those two.

## Suggested skills

| Skill | When |
| --- | --- |
| `/grilling` | Before starting any backlog item — all four themes are under-specified on purpose |
| `/tdd` | Any new feature: the suite is there now, so red-green is cheap |
| `/diagnosing-bugs` | If a spec starts failing: the code is in daily use, so suspect the test or the fixture first |
| `/codebase-design` | Only if backlog item 4 (PR integration) starts — it needs a second delivery backend behind the existing adapter seam |

## Context worth carrying

Four real bugs were found by these tests during development; the assertions guarding them
are the ones most worth not losing:

1. `vim.treesitter.language.add()` is **lazy in 0.12** and returns true for languages with
   no parser installed — availability must be proven by instantiating a parser.
   (`syntax_spec`, "returns nil for a filetype whose parser is not installed")
2. `\ No newline at end of file` on a hunk's **last** line arrives after both line counters
   have hit zero, so a counter-only loop condition drops it.
   (`diff_spec`, "records `\ No newline at end of file` on both sides")
3. The tree's parent directory must be found by **depth**, not proximity — the nearest
   directory row above a file is often a sibling it scrolled past.
   (`panel_spec`, "h on a file folds its own parent, not the sibling above it")
4. `nvim_win_call` propagates **only the first return value**, silently losing the end of a
   `line("w0"), line("w$")` range. (Guarded indirectly by `syntax_spec`'s viewport cases.)

No credentials, tokens, or personal data appear in this document or in `tests/`.
