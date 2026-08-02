# Handoff — codereview-annotator.nvim: get the test suite into the repo

**Next session's job:** port ~254 existing assertions from `tests/_scratch/` into a real
plenary suite with CI. Features are a ranked backlog at the bottom — **do not start them.**

## Where things are

| What | Where |
| --- | --- |
| Plugin repo | `~/Codes/lua/codereview-annotator.nvim` (private, `master`, commit `f26256e`) |
| GitHub | https://github.com/felipeva/codereview-annotator.nvim |
| Neovim config wiring | `~/.config/nvim/lua/plugins/codereview.lua` (`dir =` spec + 3 adapters) |
| Design rationale | `README.md` § *Design notes* — read this before changing anything |
| User-facing docs | `doc/codereview.txt` |
| **Test sources to port** | `tests/_scratch/` — delete the directory once the port is done |

This document lives at `docs/agents/HANDOFF.md`. Paths below are repo-relative, and the
scratch suites derive the runtimepath from their own location, so they run from any clone.

The plugin is ~3,900 lines across 14 modules. It renders a unified syntax-highlighted git
diff with a folder-tree panel, typed annotations that queue up, reviewed-file collapsing,
and a batch submit through injected adapters. It works and is in daily use.

**It has zero tests in the repo.** That is the entire problem this handoff exists to fix.

## Decisions already made (do not re-litigate)

| Decision | Choice |
| --- | --- |
| Harness | **plenary.nvim busted** — `PlenaryBustedDirectory` runs each file in its own nvim, matching the process-per-suite isolation the scratch suites already depend on |
| Interactive test | **Port to Lua, keep it in the suite** — not Python |
| CI | **GitHub Actions, nvim stable + nightly, core parsers only** |
| Feature work | **Not this session** |

## The work

### 1. Port the suites — `tests/_scratch/` → `tests/codereview/*_spec.lua`

Each scratch file is one `nvim -l` script with a hand-rolled `check(label, got, want)`.
The port is mechanical: `check(l, got, want)` → `it(l, function() assert.same(want, got) end)`.

| Scratch file | Becomes | Covers |
| --- | --- | --- |
| `t1.lua` | `diff_spec.lua` | scope resolution, unified-diff parsing, rename/binary/untracked, blob hashing |
| `t2.lua` | `render_spec.lua` | anchor map, byte columns, navigation, collapse, panel, scope cycling |
| `t3.lua` | `syntax_spec.lua` | treesitter harvest/replay, caching, guardrails |
| `t4.lua` | `annotate_spec.lua` | targeting, cross-file clamp, deleted-line rule, types, drop |
| `t5.lua` | `payload_spec.lua` | grouping, `@ref` vs inline, out-of-tree fallback, submit |
| `t6a.lua` + `t6b.lua` | `state_spec.lua` | persistence across processes, blob invalidation, corrupt files |
| `t8.lua` | `panel_spec.lua` | tree build, chain compaction, folding, subtree review, navigation |
| `t10.lua` | `focus_spec.lua` | queue-float focus across the async picker, submit closing the float |
| `pty_test.py` + `pty_init.lua` | `interactive_spec.lua` | **insert-mode leak** — see §2 |
| `mkfixture.sh` | `tests/fixtures/mkfixture.sh` | flat fixture — diff, annotation, payload, state suites |
| `mktree.sh` | `tests/fixtures/mktree.sh` | nested fixture — tree panel and focus suites |
| `perf2.lua` | keep as `tests/perf.lua`, not in CI | open-time budget on a 60-file diff |

Both fixture scripts take a target path and rebuild from scratch. Run the matching one
before its suites; they are not interchangeable, and `t8`'s assertions depend on exactly
which files the nested fixture contains.

**Three traps, all of which already bit once:**

- **`t6a`/`t6b` are deliberately two processes.** Persistence is only meaningfully tested
  across a genuine restart. Under plenary they must stay two files, or one file that
  spawns a child nvim — not one process calling `state.load()` twice.
- **`XDG_STATE_HOME` must be per-test and cleared.** Reusing it makes assertions pass
  because a *previous run's* state was restored. It also writes into the real
  `~/.local/state/nvim/codereview/`, where the user has genuine review state.
- **Several assertions were derived from git at runtime** (`git diff --numstat`) precisely
  because hardcoded counts went stale three times. Keep them derived.
- **The tree fixture is structural.** `t8` asserts on compaction (`apps/api/src` collapses,
  `apps` does not) and on per-directory tallies, so adding or omitting a file changes what
  it expects. `mktree.sh` documents which files exist and why; regenerate rather than
  hand-editing a fixture repo.

### 2. `interactive_spec.lua` — the one test that cannot be headless

Insert mode is **unreachable** in headless Neovim: `startinsert` needs the interactive
input loop, so `mode()` always returns `n`. A headless test of the composer's insert-mode
leak passes whether or not the fix exists — the first version of this test did exactly
that and was worthless.

The working approach (verified this session, both directions):

```lua
local job = vim.fn.jobstart({ "nvim", "--listen", sock, "-u", init },
                            { pty = true, width = 120, height = 40 })
-- drive with:  nvim --server <sock> --remote-send '<keys>'
-- read with:   nvim --server <sock> --remote-expr 'mode()'
```

`tests/_scratch/pty_test.py` is the proven Python version — port its assertions, not its
structure. `pty_init.lua` is the minimal composer stub that reproduces the leak (a float
entered with `startinsert`, submitted from an insert-mode mapping, closing its own window
without `stopinsert`).

**Verify the port has teeth**: revert the fix (remove the `BufEnter`/`WinEnter`/`InsertEnter`
autocmd in `view.lua` and the `stopinsert` in `annotate.lua`'s `collect`) and confirm the
test fails with `mode='i'`. If it still passes, the test is not reproducing the bug.

### 3. Rewrite the syntax fixtures in Lua

`syntax_spec` currently uses `.ts` fixtures, which need nvim-treesitter plus a compiled
parser — the only thing that would make CI slow and brittle.

Neovim core ships parsers **and** `highlights` queries for `lua`, `c`, `vim`, `vimdoc`,
`query`, `markdown` (verified on a bare `nvim --clean`; harvesting captures from Lua source
works with no plugins at all). Rewriting the fixtures in `.lua`/`.md` removes every parser
dependency from CI.

Keep one typescript case that marks itself `pending` when the parser is absent, so the
multi-language path is still exercised locally without ever failing CI.

### 4. Makefile + CI

```make
test:      # PlenaryBustedDirectory tests/codereview/ { minimal_init = tests/minimal_init.lua }
lint:      # stylua --check lua/    (note: stylua.toml sets syntax = "Lua52" for goto)
```

`.github/workflows/test.yml`: matrix over nvim `stable` and `nightly`, clone plenary as the
only dependency, run `make lint test`. No compiler, no parser build. Minimum supported
version is **0.12** — the plugin needs `vim.treesitter.get_string_parser`.

### 5. Then: `setup-matt-pocock-skills`

Run it **inside the plugin repo**. It scaffolds the per-repo config the other engineering
skills assume (issue tracker, triage labels, domain-doc layout) and writes
`docs/agents/issue-tracker.md`. It is interactive — it interviews across three sections and
must not be answered on the user's behalf. It is `disable-model-invocation: true`, so the
**user** invokes it.

The skills themselves are already installed globally (`~/.agents/skills`, symlinked into
`~/.claude/skills` and `~/.claude-personal/skills`, 44 of them). Nothing to install.

## Definition of done

- `make test` green locally and on both CI matrix legs
- All ~254 assertions accounted for — ported, or consciously dropped with a reason
- `interactive_spec` demonstrably fails when the insert-mode fix is reverted
- No test writes to the real `~/.local/state/nvim/`
- `tests/README.md` documents how to run them and what is deliberately not covered

## Backlog — ranked, NOT for this session

Ordered by value-per-effort. Every item builds on the existing anchor map (`render.lua`)
unless noted.

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
  trace — currently untested either way.
- **Symlinked roots.** `git rev-parse --show-toplevel` returns the *canonical* path, so on
  macOS a repo reached through `/var/...` yields a root of `/private/var/...`. Internally
  consistent (every `abs_path` is built from that root), but `payload.relative_to()`
  compares against a delivery target's reported `cwd` — if an agent reports the symlinked
  form, the prefix match fails and refs silently degrade to absolute paths with inlined
  code. Not a crash, and arguably the safe direction, but it means `@refs` can quietly stop
  being emitted. Worth a `vim.uv.fs_realpath()` on both sides. Surfaced by running the
  suite from `$TMPDIR`; the assertion in `tests/_scratch/t1.lua` now resolves both paths.
- **Two annotation systems coexist.** `<leader>a` (`~/.config/nvim/lua/util/claude*.lua`,
  buffer-based) and `<leader>r` (this plugin) keep **separate queues**. Deliberate, so the
  old flow kept working; worth retiring `claude_review.lua`'s `start()`/`annotate_hunk()`
  once this has proven itself. Those files are unmodified and documented in
  `~/.config/nvim/docs/claude-annotate.md`.
- **Private repo**: if the config ever switches from the local `dir =` spec to the GitHub
  one, lazy.nvim will need SSH auth. The current `dir =` spec never touches the network.
- **Perf budget**: opening a 60-file / 12k-line diff is ~290–400 ms. Two things keep it
  there — viewport-bounded syntax harvesting and batched blob hashing. `tests/perf.lua`
  guards it; if it regresses, suspect one of those two.

## Suggested skills

| Skill | When |
| --- | --- |
| `/tdd` | The port itself — each spec should fail before it passes, especially `interactive_spec` |
| `/setup-matt-pocock-skills` | Step 5, run inside the plugin repo (user must invoke; it interviews) |
| `/grilling` | Before starting any backlog item — all four themes are under-specified on purpose |
| `/diagnosing-bugs` | If a ported assertion fails: the code is in daily use, so suspect the port first |
| `/codebase-design` | Only if backlog item 4 (PR integration) starts — it needs a second delivery backend behind the existing adapter seam |

## Context worth carrying

Four real bugs were found by these tests during development; the assertions guarding them
are the ones most worth not losing:

1. `vim.treesitter.language.add()` is **lazy in 0.12** and returns true for languages with
   no parser installed — availability must be proven by instantiating a parser.
2. `\ No newline at end of file` on a hunk's **last** line arrives after both line counters
   have hit zero, so a counter-only loop condition drops it.
3. The tree's parent directory must be found by **depth**, not proximity — the nearest
   directory row above a file is often a sibling it scrolled past.
4. `nvim_win_call` propagates **only the first return value**, silently losing the end of a
   `line("w0"), line("w$")` range.

No credentials, tokens, or personal data appear in this document or in `tests/_scratch/`.
