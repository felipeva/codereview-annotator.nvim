# Handoff — codereview-annotator.nvim

**The test suite is in.** `tests/_scratch/` is gone; everything it proved now lives in
`tests/codereview/*_spec.lua` under plenary, with CI. Features are a ranked backlog at the
bottom — **do not start them without grilling the item first.**

## Where things are

| What | Where |
| --- | --- |
| Plugin repo | `~/Codes/lua/codereview-annotator.nvim` (private, `master`) |
| GitHub | https://github.com/felipeva/codereview-annotator.nvim |
| Neovim config wiring | `~/.config/nvim/lua/plugins/codereview.lua` (`dir =` spec + 3 adapters) |
| Design rationale | `README.md` § *Design notes* — read this before changing anything |
| User-facing docs | `doc/codereview.txt` |
| **Tests** | `tests/README.md` — layout, fixtures, what is deliberately not covered |

The plugin is ~3,900 lines across 14 modules. It renders a unified syntax-highlighted git
diff with a folder-tree panel, typed annotations that queue up, reviewed-file collapsing,
and a batch submit through injected adapters. It works and is in daily use.

## What the port ended up as

245 cases, ~310 assertions, ~5 seconds. `make test` runs `PlenaryBustedDirectory` over
`tests/codereview/`, one Neovim per spec file, each building its own throwaway fixture.

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
| `interactive_spec` | `pty_test.py` | the insert-mode leak, in a real pty-backed Neovim |
| `perf.lua` | `perf2.lua` | open-time report on a 60-file diff — deliberately not in CI |

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
- **Symlinked roots.** `git rev-parse --show-toplevel` returns the *canonical* path, so on
  macOS a repo reached through `/var/...` yields a root of `/private/var/...`. Internally
  consistent (every `abs_path` is built from that root), but `payload.relative_to()`
  compares against a delivery target's reported `cwd` — if an agent reports the symlinked
  form, the prefix match fails and refs silently degrade to absolute paths with inlined
  code. Not a crash, and arguably the safe direction, but it means `@refs` can quietly stop
  being emitted. Worth a `vim.uv.fs_realpath()` on both sides. The suite runs from
  `$TMPDIR` and so hits this constantly; `diff_spec` resolves both paths.
- **Two annotation systems coexist.** `<leader>a` (`~/.config/nvim/lua/util/claude*.lua`,
  buffer-based) and `<leader>r` (this plugin) keep **separate queues**. Deliberate, so the
  old flow kept working; worth retiring `claude_review.lua`'s `start()`/`annotate_hunk()`
  once this has proven itself. Those files are unmodified and documented in
  `~/.config/nvim/docs/claude-annotate.md`.
- **Private repo**: if the config ever switches from the local `dir =` spec to the GitHub
  one, lazy.nvim will need SSH auth. The current `dir =` spec never touches the network.
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
