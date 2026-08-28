# `lua/codereview/`

What each module owns, and the three things their headers cannot say from inside: how they
stack, where the cycles are, and which of them are settled.

Every module opens with a docstring that says more than its row here does. The rows are for
choosing which of those to read — not for skipping them.

## Modules

`pure` means data in, data out: no buffers, no windows, no git. `stateful` carries what a
change there is felt through.

| Module | Owns | |
| --- | --- | --- |
| `annotate.lua` | The review path: cursor to entry, the deleted-line and hunk inlining rules, drop, grouping | stateful (queue, view) |
| `archive.lua` | The archive read back: which batch went last, the read-only float listing it and the **preamble** it went under, and the projection of archived entries onto the diff's anchors | stateful (float) |
| `capture.lua` | The capture path: the same entry from an ordinary buffer, no review view involved | stateful (queue, buffer) |
| `checkout.lua` | Moving the review to another **checkout**: the listing behind the choice, the picker the plugin ships as the default `pick_checkout` adapter, and the open a **switch** ends in | stateful (view) |
| `composer.lua` | The shipped composer and its `@` reference picker — the default `compose` adapter, not a lesser one | stateful (float) |
| `config.lua` | `setup()`, the defaults, and the injected adapters: `send`, `pick_target`, `pick_file`, `compose`, `open_diff`, `pick_checkout` | stateful (options) |
| `delivery.lua` | Where a batch is going, how that is chosen, the **preamble** composed at submit time, and the submit that empties the queue only on dispatch | stateful (target, queue) |
| `diff.lua` | Unified-diff parsing, and the intra-line spans within a paired line | pure |
| `drafts.lua` | Note text abandoned in a composer, keyed by absolute path — or by repository, for a **preamble** — in a store of its own | stateful (disk) |
| `fade.lua` | The **faded** file rule: which rows one file's fade covers, and which group a faded row carries in place of its own | stateful (editor) |
| `git.lua` | Every shell-out in the plugin: scope resolution, `git diff`, blob hashes, the pre-image a **trim** with a hole in it is built from, and the one query answered on a later tick — how much each commit on the branch changed | stateful (git) |
| `hl.lua` | The highlight groups: `default = true` links into whatever colorscheme is active, and the three families of blended twins — the **muted** window's, the **faded** file's and the **counterpart row**'s | stateful (editor) |
| `init.lua` | The public surface a host reaches: `setup`, the user commands, `annotate(type)` | stateful (setup) |
| `keymaps.lua` | Every key the review view binds — the diff's and the tree's — onto a buffer handed in, driving actions handed in | stateful (editor) |
| `panel.lua` | The file tree: build, chain compaction, folding, per-directory tallies | pure |
| `payload.lua` | The queue rendered as the message an agent receives; `@ref`s resolved at submit time | pure |
| `queue.lua` | The queue itself — one per **checkout**, one more for what belongs to no checkout, and the single id counter they all draw from | stateful (memory) |
| `queue_float.lua` | The float over the queue: an entry as a run of bar-marked rows, and the keys that drop, jump, copy and submit | stateful (float) |
| `render.lua` | Parsed diff to buffer lines, extmarks and the anchor map; both panes from one walk; what a file is called wherever it is named, and how a winbar is assembled from typed segments | pure |
| `state.lua` | Persisted review progress, filed under the **checkout** each entry is about, which checkout the plugin is acting on at all, the blob comparisons over it — staleness, and touchedness kept in a function of its own — each branch's **trim**, checked against `HEAD` before it is handed back, and the **sweep** that discards the state of checkouts that are gone | stateful (disk) |
| `syntax.lua` | Treesitter harvest and replay onto the diff's rows, bounded by the viewport | stateful (extmarks) |
| `trim_float.lua` | The float over the branch's commits: the first-parent listing from the base handed in, a checkbox and a size on every row, and the pick that applies the **trim** they add up to | stateful (float) |
| `types.lua` | Annotation types: defaults, normalization, labels, and the directive that earns a type its keystroke | pure |
| `view.lua` | The review view: the `CRView` it owns, the paint, navigation, delivery, opening and closing | stateful (windows) |
| `view_layout.lua` | Where the review's windows are: the panes, the before pane, the toggle between the unified and split layouts, which of them is muted, and which group each lights its row in | stateful (windows) |
| `view_panel.lua` | The file tree's stateful half: its window and buffer, the repaint that follows the diff cursor, and the actions its keys run | stateful (windows) |

## How they stack

- **Require nothing**: `diff`, `drafts`, `panel`, `queue`, `types`.
- **Above them**, in that order: `git`, `payload`, `render`; then `state`, `config`; then
  `archive`, `delivery`, `keymaps`, `syntax`; then `checkout`, `composer`, `hl`, `fade`,
  `queue_float`, `trim_float`, `view_layout`; then `view_panel`.
- **The hubs**: `view` requires thirteen of the modules above, `annotate` nine. A change that
  is not local to a leaf almost certainly reaches one of them.
- **On top**: `capture`, then `init`.

## The four cycles

`view` and `annotate` require each other. This is known and accepted — not a defect to fix
in passing. `annotate` needs the focused pane, the current view, the repaint and the anchor
under the cursor, which are genuine dependencies, and both sides use a function-local
`require`, so Lua resolves it lazily and nothing loads at file scope before it is ready.
Forcing the two apart costs more than it returns.

`git` and `state` are the second, and much the smaller: `state` mints a snapshot and hashes
blobs through `git`, and `git` reads the newest snapshot back out of the archive to resolve
the `since-batch` scope. The **trim** rides the same edge in both directions — `git` reads the
branch's stored trim to resolve `branch`, and `state` asks `git` which branch that is and
whether `HEAD` still descends from what it stored. Function-local on both sides, as above. The
alternative is handing the snapshot in from outside, which would put the one scope that needs
it into every caller of `resolve_scope` — and scope resolution is exactly what must stay one
function.

`delivery` and `composer` are the third, and the smallest. A **preamble** is composed at
submit time, so the submit has to reach whichever composer is wired — and the plugin's own
is the *default implementation* of that adapter rather than a fallback beside it (ADR-0003),
so "whichever is wired" always includes it. The composer points back for one field: the
footer it draws names the batch's target, and routing is delivery's. Function-local on both
sides, as above. The alternative was handing the composer in from every caller, which buys
nothing and spreads the one rule ADR-0003 exists to keep in one place.

`state` and `view` are the fourth, and the newest. `state` answers which **checkout**
everything resolves against, and after a **switch** that answer is the open review's root
rather than the working directory's — so it has to be able to ask whether a review is open
(ADR-0008). Function-local, as above, and one-directional in spirit: `view` requires `state`
function-locally already, and `state` reads one field off the view it is handed back. The
alternative was `view` *telling* `state` which checkout it is on, which is a second copy of
"which review is open" that can drift the moment a tab is closed from outside — and
ADR-0008 exists because a copy of exactly this fact goes stale silently.

`keymaps`, `queue_float`, `trim_float`, `view_layout` and `view_panel` would each be a
fifth. All five run the view's exported actions, and all five take them as an argument —
`view` hands itself in — rather than requiring `view` for them. That is deliberate, and it is
what leaves `keymaps` a function of its arguments and the configured annotation types.
`queue_float` reads no view state either: the one field it needs, the window a float is open
in, stays on `view` behind two accessors, because closing a float on submit is a rule about
the view's windows. `trim_float` reads none at all: what it takes beside the view is the
repository and the commit the branch starts at, both as plain values, because a second
derivation of *where does this branch start* is a second chance to answer it differently.
The view keeps the one refusal only the view can make — the **scope** on screen.
`view_layout` and `view_panel` do read view state, but never their own copy of it: the
`CRView` table is handed in beside the view and mutated in place, exactly as `syntax` and
`state` are handed it, so there is still one table and `view` still owns it. The one edge
between the two is `view_panel` requiring `view_layout` for the window construction both
surfaces share, and it points one way only.

## Where reading pays

- **Settled**, one to three commits each: `panel`, `drafts`, `diff`, `git`, `syntax`,
  `render`, `hl`, `archive`, `keymaps`. Read one when you need it, not to orient yourself.
  `keymaps` is the one to open when the question is what a key does or where to add one —
  it is a table, not a search through the surface that happens to bind it.
- **Carries the churn**: `view` and `annotate` by a wide margin, then `config`, `composer`
  and `state`. `queue_float`, `view_layout` and `view_panel` are all newly split out of
  `view` and inherit its history rather than starting clean — the float's rows and its keys
  have both been rewritten recently, the panes carry every trap the split layout ever cost,
  and the tree's window has been dismissible for less time than it has existed.

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
