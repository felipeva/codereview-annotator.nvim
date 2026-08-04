# `lua/codereview/`

What each module owns, and the three things their headers cannot say from inside: how they
stack, where the one cycle is, and which of them are settled.

Every module opens with a docstring that says more than its row here does. The rows are for
choosing which of those to read — not for skipping them.

## Modules

`pure` means data in, data out: no buffers, no windows, no git. `stateful` carries what a
change there is felt through.

| Module | Owns | |
| --- | --- | --- |
| `annotate.lua` | The review path: cursor to entry, the deleted-line and hunk inlining rules, drop, grouping | stateful (queue, view) |
| `capture.lua` | The capture path: the same entry from an ordinary buffer, no review view involved | stateful (queue, buffer) |
| `composer.lua` | The shipped composer and its `@` reference picker — the default `compose` adapter, not a lesser one | stateful (float) |
| `config.lua` | `setup()`, the defaults, and the injected adapters: `send`, `pick_target`, `pick_file`, `compose`, `open_diff` | stateful (options) |
| `delivery.lua` | Where a batch is going, how that is chosen, and the submit that empties the queue only on dispatch | stateful (target, queue) |
| `diff.lua` | Unified-diff parsing, and the intra-line spans within a paired line | pure |
| `drafts.lua` | Note text abandoned in a composer, keyed by absolute path, in a store of its own | stateful (disk) |
| `git.lua` | Every shell-out in the plugin: scope resolution, `git diff`, blob hashes | stateful (git) |
| `hl.lua` | The highlight groups, all `default = true` links into whatever colorscheme is active | stateful (editor) |
| `init.lua` | The public surface a host reaches: `setup`, the user commands, `annotate(type)` | stateful (setup) |
| `panel.lua` | The file tree: build, chain compaction, folding, per-directory tallies | pure |
| `payload.lua` | The queue rendered as the message an agent receives; `@ref`s resolved at submit time | pure |
| `queue.lua` | The queue itself — module-level, not per-view, so reopening a view scatters nothing | stateful (memory) |
| `render.lua` | Parsed diff to buffer lines, extmarks and the anchor map; both panes from one walk | pure |
| `state.lua` | Persisted review progress, and the blob-hash check that makes persisting safe | stateful (disk) |
| `syntax.lua` | Treesitter harvest and replay onto the diff's rows, bounded by the viewport | stateful (extmarks) |
| `types.lua` | Annotation types: defaults, normalisation, labels, and the directive that earns a type its keystroke | pure |
| `view.lua` | The review view: buffers, windows, keymaps, navigation, both layouts, the queue float | stateful (windows) |

## How they stack

- **Require nothing**: `diff`, `drafts`, `panel`, `queue`, `types`.
- **Above them**, in that order: `git`, `payload`, `render`; then `state`, `config`; then
  `delivery`, `syntax`; then `composer`, `hl`.
- **The hubs**: `view` requires twelve of the modules above, `annotate` nine. A change that
  is not local to a leaf almost certainly reaches one of them.
- **On top**: `capture`, then `init`.

## The two cycles

`view` and `annotate` require each other. This is known and accepted — not a defect to fix
in passing. `annotate` needs the focused pane, the current view, the repaint and the anchor
under the cursor, which are genuine dependencies, and both sides use a function-local
`require`, so Lua resolves it lazily and nothing loads at file scope before it is ready.
Forcing the two apart costs more than it returns.

`git` and `state` are the second, and much the smaller: `state` mints a snapshot and hashes
blobs through `git`, and `git` reads the newest snapshot back out of the archive to resolve
the `since-batch` scope. Function-local on both sides, as above. The alternative is handing
the snapshot in from outside, which would put the one scope that needs it into every caller
of `resolve_scope` — and scope resolution is exactly what must stay one function.

## Where reading pays

- **Settled**, one to three commits each: `panel`, `drafts`, `diff`, `git`, `syntax`,
  `render`, `hl`. Read one when you need it, not to orient yourself.
- **Carries the churn**: `view` and `annotate` by a wide margin, then `config`, `composer`
  and `state`.

Re-derive with `git log --oneline --follow -- lua/codereview/<name>.lua` before leaning on
that grouping; it moves.

## One hop away

- [`CONTEXT.md`](../../CONTEXT.md) — the vocabulary, including the terms this project
  deliberately avoids and why. Use its words.
- [`docs/adr/`](../../docs/adr/) — the decisions. Contradicting one is allowed; doing it
  silently is not.
- [`docs/design-notes.md`](../../docs/design-notes.md) — the traps, grouped by subsystem.
  Read the group before changing rendering, diff parsing, blob hashing, references, or
  anything touching windows and modes. Several obvious-looking approaches here are wrong
  for reasons the code does not reveal.
- [`tests/README.md`](../../tests/README.md) — what each spec pins down, and a long list of
  ways a test here can pass while measuring nothing.

## This file is pinned

`tests/codereview/map_spec.lua` asserts that every module above has a row and that no row
names a module that is gone. Prose is not checked and cannot be; terseness is what keeps it
true. Add a module, add a row.
