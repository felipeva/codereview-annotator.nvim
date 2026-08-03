# codereview-annotator.nvim

[![test](https://github.com/felipeva/codereview-annotator.nvim/actions/workflows/test.yml/badge.svg?branch=master&event=push)](https://github.com/felipeva/codereview-annotator.nvim/actions/workflows/test.yml?query=branch%3Amaster)
[![Neovim 0.12+](https://img.shields.io/badge/Neovim-0.12%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A code review surface for Neovim: one unified, syntax-highlighted diff of everything a
branch changed, with vim-native navigation, typed annotations that queue up, reviewed-file
collapsing, and a batch submit that hands the whole review to an agent as a single message.

```
┌─ tree ──────────────┐┌─ Code review · branch vs origin/master · 2/7 · +9 -4 ──┐
│ ▾ apps          1/4 ││ ○ ▾ apps/api/src/main.ts                +12 -3  [3 notes]│
│   ▾ api/src     1/2 ││ @@ -19,6 +19,8 @@ function boot()                         │
│     ▾ routes    0/1 ││  19 │  const app = express()                              │
│       ○ users.ts    ││ ▌20 │ -const cfg = load()                                 │
│     ● main.ts     3 ││ ▌21 │ +const cfg = loadConfig()                           │
│   ▾ web/src     0/2 ││ ▌    │   🐞 why the rename? no callers were updated        │
│     ✓ index.ts      ││  22 │  app.listen(cfg.port)                               │
│ ▾ packages/…    0/1 ││                                                           │
│   ○ types.ts        ││ ✓ ▸ apps/api/src/routes.ts                       +4 -0    │
│ ○ README.md         ││                                                           │
│ 2/7 reviewed        ││ ○ ▾ apps/web/src/index.ts                        +2 -1    │
└─────────────────────┘└───────────────────────────────────────────────────────────┘
```

The tree collapses single-child directory chains (`apps/api/src`, not three nested rows),
sorts directories before files, and carries a reviewed tally on every directory so you can
see which packages are done without opening them.

Everything is drawn natively, and the syntax highlighting is recovered with
`vim.treesitter.get_string_parser` — see [Design notes](#design-notes).

## Requirements

- Neovim **0.12+** (`vim.treesitter.get_string_parser`, `vim.system`, `virt_lines`)
- `git`
- Treesitter parsers for the languages you review — optional; files without one fall back
  to flat diff colours

## Install

```lua
{
  "felipeva/codereview-annotator.nvim",
  cmd = "CodeReview",
  opts = {},
}
```

Nothing else is required. With no adapters wired the view renders, annotates and queues;
the batch lands in the `+` register instead of an agent, and stays queued because nothing
consumed it.

## Usage

`:CodeReview` opens the branch review. `:CodeReview staged`, `unstaged`, `worktree`, or any
git revspec (`:CodeReview HEAD~3`, `:CodeReview main...feature`) opens that instead.

### From any buffer

Annotating does not need a review open. `:CodeReviewAnnotate bug` queues a note about the
file you are looking at; with no type it offers the same picker `aa` does.

```lua
require("codereview").annotate("bug")  -- the selection, or the whole file
require("codereview").annotate()       -- pick the type from a menu, or decline one
```

That is the entry point to bind a key to — nothing needs to reach into the plugin's
internal modules to capture. Bind it in both modes and the selection decides the scope:

```lua
vim.keymap.set({ "n", "x" }, "<leader>ab", function()
  require("codereview").annotate("bug")
end, { desc = "Annotate as a bug" })
```

| Where you are | What gets captured |
| --- | --- |
| Normal mode | The whole file |
| A visual selection | Exactly those lines |
| `:'<,'>CodeReviewAnnotate bug` | Exactly those lines |
| `:12,20CodeReviewAnnotate bug` | Lines 12 to 20 |
| A file outside any checkout | The file, by absolute path |
| A buffer with nothing on disk | A bare note, with no path at all |

The last two are not second-class. They queue, submit and survive a restart like anything
else — a scratch buffer is a fine place to leave a thought for the batch.

Errors and warnings overlapping what you captured ride along with the note, so they stop
being retyped by hand. Hints and info are left out — they are rarely why you are
annotating, and they bury the diagnostic that is.

```
why is this branch unreachable?

Diagnostics:
- ERROR L12 undefined global `foo` (lua_ls)
- WARN  L14 unused local `bar` (lua_ls)
```

What it queues is an ordinary annotation: it records the file's blob, so it goes stale the
same way, it appears in the same queue float next to anything captured during a review, it
groups under its type in the same payload, and it goes out in the same batch to the same
target. A selection travels as `@path#L12-20` when the delivery target can resolve the
path, and inlines its code when it cannot. The buffer itself is never touched.

### Sending one annotation now

A thought you want acted on should not have to wait for a batch you have not finished
assembling. The same entry point sends one annotation on its own instead of queueing it:

```lua
require("codereview").annotate("bug", nil, { immediate = true })
require("codereview").annotate(nil, nil, { immediate = true })  -- or pick the type, or decline one
```

Delivery is a property of the call, not a different door: everything above still applies —
the same paths, the same blob, the same diagnostics, the same drafts and `@` references,
and the same picker with its `no type` entry. It renders through the same renderer a batch
does, so what arrives is an ordinary review payload that happens to hold one annotation
([ADR-0004](docs/adr/0004-an-immediate-send-is-a-batch-of-one.md)) — untyped, if that is
what you chose, in the group that carries no directive.

That a type is optional at all is a consequence of this: a batch of one would otherwise
force one onto the fastest interaction there is.

The queue is untouched: an annotation sent this way never joins it, and whatever is already
queued is neither delivered nor cleared. It is governed by the same rule a batch is, though:
a `send` that reports it did not go says why — as an error, since something was written and
nothing received it — and nothing claims the note was sent. The note itself is kept as a
draft, so annotating that file again offers it back. A batch of one has no queue to wait in,
and by the time delivery answers, the composer has closed.

You are asked where it goes **before** the composer opens, through `pick_target` — so
declining costs no typing. Decline and nothing is sent. With no `pick_target` wired there
is nothing to choose between, so it goes with no target and `send` decides what that means.
Because the note owns that choice rather than the batch, the composer's footer names the
target *this note* will reach, and `^T` in the composer reroutes the note, leaving the
batch pointing where it was.

### Inside the view

| Key | Action |
| --- | --- |
| `ab` `af` `as` `an` `ai` | Annotate as bug / fix / suggestion / nitpick / issue |
| `aa` | Annotate, picking the type from a menu or declining one |
| `x` | Drop the annotation under the cursor |
| `R` | Toggle reviewed on this file (collapses it) |
| `za` | Toggle expansion without marking reviewed |
| `gs` | Cycle scope, re-rendering in place |
| `gr` | Re-read the diff from git |
| `<CR>` | Open the real file here, in a new tab |
| `Q` | Review the queue |
| `<C-t>` | Choose the delivery target |
| `<C-s>` | Submit the batch |
| `q` | Close |

### Getting around

| Key | Action |
| --- | --- |
| `]f` `[f` | Next / previous file |
| `]F` `[F` | Next / previous **unreviewed** file — wraps |
| `]h` `[h` | Next / previous hunk |
| `]a` `[a` | Next / previous annotation |
| `<C-p>` | Jump to a file by name, from a list |
| `<Tab>` | Move between the diff and the tree |

`]F` is the one that matters once a review is underway: the point of marking files reviewed
is to stop looking at them, so the useful motion is "the next thing I have not done", not
"the next file", which walks back through everything already finished.

The tree follows the diff cursor — whatever you are reading is highlighted, and the tree
scrolls to it. `<Tab>` into the tree lands on that same file rather than wherever the
cursor last was.

### In the tree

| Key | Action |
| --- | --- |
| `<CR>` / `o` | Open the file, or fold the directory |
| `h` / `zc` | Collapse the directory — on a file, collapses its parent |
| `l` / `zo` | Expand the directory |
| `za` | Toggle the directory |
| `zM` / `zR` | Collapse / expand every directory |
| `]f` `[f` | Next / previous file, skipping directory rows |
| `R` | Toggle reviewed — **on a directory, the whole subtree** |
| `<C-p>` | Jump to a file by name |
| `<Tab>` | Back to the diff |
| `q` | Close |

Jumping to a file that was collapsed because it is reviewed expands it: you asked to look
at it.

Annotation keys are prefixed with `a` rather than bound bare, because bare `b`, `f`, `n`
and `s` would shadow back-word, find-char, next-search and (if you use it) flash.nvim
inside the buffer. `a` is append, which is dead in a `nomodifiable` buffer, so the prefix
costs a keystroke and no motion.

### What gets annotated

| Cursor is on | Target |
| --- | --- |
| A diff line | That line |
| A visual selection | Those lines |
| A hunk header | The whole hunk |
| A file header | The whole file |

## Annotation types

A type is not decoration — it changes what the receiving agent is told to do.

| Type | Key | Group directive in the payload |
| --- | --- | --- |
| bug | `ab` | diagnose and fix these |
| fix | `af` | apply these changes |
| suggestion | `as` | evaluate; apply if sound |
| nitpick | `an` | low priority — batch these together |
| issue | `ai` | do NOT fix — summarize these for tracking |

`opts.types` replaces the whole set. Only `name` and `key` are required — everything else
is derived, so adding a type costs two fields:

```lua
types = {
  { name = "bug",      key = "b", directive = "diagnose and fix these" },
  { name = "nitpick",  key = "n", directive = "ignore unless trivial" },
  { name = "question", key = "q" },
}
```

| Field | Default |
| --- | --- |
| `name` | **required** — what `annotate()` takes and what an entry stores |
| `key` | **required** — pressed after the `a` prefix, so `q` binds `aq` |
| `label` | the name, title-cased and pluralised: `question` → `Questions` |
| `icon` | `icons.annotated` |
| `hl` | `CodeReview<Name>`, auto-linked to `DiagnosticInfo` so it has colour |
| `directive` | none — the payload heading is then just `## Questions (3)` |

Pluralisation is naive (`+s`, unless the name already ends in one), so a name English
declines irregularly wants an explicit `label`. Order is the order groups appear in the
payload, most actionable first.

A list that cannot work is rejected at `setup()` naming the entry that caused it — a
missing `name` or `key`, a duplicate of either, a `key` of `a` (which would shadow the
`aa` type picker), or a field of the wrong type. Start from the shipped set with
`require("codereview.types").defaults`.

### No type

The picker's last entry, after every configured type, is `no type`. It queues an untyped
annotation: a remark worth reading with no instruction attached. It is an entry like any
other — it shows on the diff, it is listed in the queue and it goes out with the batch —
and its group renders last, under a bare `## Untyped (n)` heading, because a group with
nothing to instruct has no directive to state.

Declining is not dismissing. Pressing escape still abandons the annotation entirely.

## The payload

Grouped by type, in the configured order, most actionable first, with anything untyped
last:

````markdown
Code review — 4 annotations on branch vs origin/master (8 files, 6 reviewed)

## Bugs (2) — diagnose and fix these

### 1. @apps/api/src/main.ts#L20-21

why the rename? no callers were updated

### 2. apps/api/src/routes.ts:14 (deleted)
```diff
-router.use(legacyAuth)
```

was this dropped on purpose?

## Nitpicks (1) — low priority — batch these together
...

## Untyped (1)

### 4. @apps/api/src/db.ts#L8

worth a look before we ship this
````

## Adapters

The plugin has no opinion about where a review goes, or about which pickers you use. Four
optional functions inject that:

```lua
opts = {
  -- Deliver the rendered batch. Report whether it was *handed off*, not whether it
  -- arrived: return nothing or `true` for dispatched, `false` and a reason for not.
  -- Raising counts as not dispatched too, with the error message as the reason.
  -- A dispatch is the one thing that empties the queue, so a batch that did not go is
  -- still there to retry, and an immediate send that did not go keeps its note as a
  -- draft. A refusal is reported as an error. Without this the payload goes to the +
  -- register, which is the default implementation of this same contract — it reports a
  -- non-dispatch (a register is not a consumer), which is why an unwired host keeps its
  -- queue, and it is a warning rather than an error because nothing is broken.
  send = function(payload, target) return true end,

  -- Choose a delivery target; call back with anything carrying `short` and `cwd`.
  -- `cwd` matters: refs are re-resolved against it at submit time.
  pick_target = function(cb) cb({ short = "agent", cwd = "/path" }) end,

  -- Choose a file to reference from `@` inside the composer. The plugin ships no picker,
  -- so without this `@` stays a literal `@` and says so. `first`/`last` are optional —
  -- omit them and the reference is to the file rather than to a range in it.
  pick_file = function(cb) cb({ path = "src/main.lua", first = 12, last = 20 }) end,

  -- Collect note text. Without it you get the composer the plugin ships, which implements
  -- this same contract — wiring one replaces that composer rather than upgrading a prompt.
  -- `ctx` describes what is being annotated: `scope`, `label`, `rel_path`, `file_path`,
  -- and `origin_win` — the window the annotation was started from. Focus goes back there
  -- once `on_accept` runs; a composer the user can *cancel* never calls it, so that path
  -- is the composer's to restore.
  --
  -- On an immediate send `ctx.routing` is also there — `{ label(), pick(on_done) }` for
  -- the target *this note* will reach. Name it, and change it with `pick`. It is absent
  -- for a note joining the queue, which the batch routes.
  compose = function(ctx, on_accept, label) on_accept(nil, "text") end,
}
```

[ADR-0005](docs/adr/0005-a-send-reports-dispatch-not-arrival.md) records why "dispatched"
is the narrow promise — the adapter most hosts wire is asynchronous, and holding the queue
until an agent confirmed would keep a sent batch queued for the length of that agent's work.

<details>
<summary>Wiring it to a Claude session over herdr</summary>

```lua
opts = {
  send = function(payload, target)
    require("util.claude").deliver({ scope = "none", prerendered = true }, target, payload)
  end,
  pick_target = function(cb) require("util.claude").pick_target(cb) end,
  compose = function(ctx, on_accept, label) require("util.claude").compose(ctx, on_accept, label) end,
}
```

`scope = "none"` and `prerendered = true` are both load-bearing, and `pick_target`'s `cwd`
is what decides whether refs survive. [`docs/herdr.md`](docs/herdr.md) explains why, and
spells out which queue is which.

</details>

## Configuration

```lua
opts = {
  context = 3,                     -- git diff -U
  untracked = true,                -- show untracked files in branch/worktree scopes
  syntax = true,                   -- treesitter highlighting
  max_syntax_bytes = 256 * 1024,   -- skip syntax above this size
  panel = { enabled = true, width = 34, position = "left" },
  icons = { reviewed = "✓", annotated = "●", unreviewed = "○",
            collapsed = "▸", expanded = "▾", change_bar = "▌" },
  types = nil,                     -- defaults to the five above; see Annotation types
}
```

Every highlight is a `default = true` link to a group your colorscheme already defines
(`DiffAdd`, `Added`, `DiagnosticError`, …), so overriding any `CodeReview*` group works
without the plugin fighting back.

## Persistence

Reviewed marks and the queue are stored per repository under
`stdpath("state")/codereview/`, keyed by scope and diff base, and survive a restart.

Each entry records the git blob it was captured against. On reload:

- a **reviewed mark** whose blob moved is silently un-marked — the file changed, so you
  have not reviewed what is there now;
- an **annotation** whose blob moved is kept and flagged `⚠ stale`, because the prose is
  still worth sending and only its line anchor is untrustworthy. A stale entry never
  travels as an `@ref`; its code is inlined instead.

Annotations with no repository behind them — a bare note, or a file outside any checkout —
have nowhere repository-shaped to live, so they go to a single store beside the others.
Nothing ever reconciles that store against a diff, so nothing would ever clear it: entries
older than **seven days** are dropped when it is read. That bounds its growth but not its
staleness, which is the accepted cost of not making those annotations second-class.

Each kind is judged against whatever its blob was actually taken from. A review annotation
is judged against the diff on screen, and a file the current scope does not include is not
evidence that anything changed — so it is left alone. An annotation captured from a buffer
has no scope behind it and is judged against the file on disk, at any scope and with no
review open. That distinction matters in a `staged` review, where the diff shows the index
and a buffer capture holds the working tree: judging one by the other would flag a note
about a file nobody has touched.

## Development

```sh
make deps    # clone plenary into .tests/
make test    # the suite: one Neovim per spec file, ~5s
make lint    # stylua --check
```

Tests are plenary/busted specs under `tests/codereview/`, each building its own throwaway
git fixture. CI runs them on Neovim stable and nightly with plenary as the only dependency
— no nvim-treesitter and no compiler, because the fixtures are Lua and Markdown and those
parsers ship with Neovim. See [`tests/README.md`](tests/README.md) for the layout, what is
deliberately not covered, and the traps worth knowing before changing a fixture.

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers the rest: the commit convention, the branch and
PR shape, and how to run a single spec.

## Design notes

Things that are non-obvious and cost real debugging time.

**Only one treesitter highlighter can attach per buffer.** A unified diff holding
TypeScript, Lua and JSON therefore cannot use `vim.treesitter.start`. Each file's content
is parsed as a *string* instead, the `highlights` query is walked, and the captures are
replayed as extmarks onto the rows where that content is drawn. Deleted lines come from a
separate parse of the pre-image, since they no longer exist in the post-image.

**`vim.treesitter.language.add()` is lazy in Neovim 0.12** and returns true for languages
with no parser installed. Availability has to be proven by actually instantiating a parser,
which is why the result is memoised per language rather than asked per file.

**Highlighting is bounded by the viewport, not by the diff.** A file is parsed the first
time any of its rows come near the window, and never otherwise. Parsing everything
rendered instead costs 60 files × 2 sides of parsing before the view can draw — a second
of latency for highlighting nobody can see yet. It parses the whole file once triggered,
though: harvesting only the visible slice would cache a partial capture set that the next
scroll invalidates.

**Blob hashes are resolved in two batched calls**, `git hash-object` for working-tree
files and `git cat-file --batch-check` for everything behind a ref. One process per file
was, measurably, more expensive than all the treesitter work combined — on a 60-file diff
it was over half the open time.

**`nvim_win_call` propagates only the first return value.** Returning `line("w0"), line("w$")`
from it silently loses the end of the range.

**Extmark columns are byte offsets, not display columns.** The change bar and the `│`
separator are multibyte, so each rendered row records where its code text actually begins;
assuming a fixed prefix width shifts every highlight on every changed line.

**Hunk bodies are consumed by their declared line counts**, not by scanning for the next
`@@` or `diff --git`. A diff of a patch file contains those markers as ordinary content.

**`\ No newline at end of file` arrives after the counters have run out.** When the last
line of a hunk carries it, a counter-only loop condition drops the marker and the file
silently gains a trailing newline it does not have.

**An `@ref` shows the file as it is now, not what changed.** So anything touching a deleted
line is inlined as a diff block instead — the line it names no longer exists, and that
number now belongs to unrelated code. A hunk is always inlined for the same reason.

**References are resolved at submit time, against the target's cwd.** The same queue can go
to an agent whose working directory is not this one; anything outside its tree falls back
to an absolute path with the code inlined.

**That cwd is realpath'd first, and only that side.** Every `abs_path` in the queue is
already canonical — `git rev-parse --show-toplevel` answers with symlinks resolved, and
buffer capture realpaths for the same reason — but a target's `cwd` is whatever the adapter
reported. On macOS a directory reached through `/var` is a symlink into `/private/var`, so
comparing the two unresolved makes every file look like it lives outside the target's own
tree, and the whole batch silently degrades to absolute paths with pasted snippets. It
resolves once per submit rather than per entry, and falls back to the string it was given:
a routed agent can name a directory that does not exist on this machine at all.

**Collapsing is done at render time, not with folds.** A collapsed file's body is never
emitted, so the buffer and the anchor map stay small on a large review, and there is one
mechanism instead of two.

**Untracked files are synthesised, not diffed.** `git diff --no-index` exits 1 when the
files differ — the normal case — and labels the pre-image `a/dev/null`. Building the entry
directly avoids both quirks.

**Progress is written on mutation, not on paint.** `paint` also runs on window resize, and
persisting there turns dragging a split into a stream of file writes.

**The tree's parent directory is found by depth, not by proximity.** `h` on a file folds
the directory containing it — but the nearest directory row *above* a file is often a
sibling directory the cursor already scrolled past, not its parent. Each row records its
tree depth, and the parent is the nearest directory row above with a smaller one.

**The panel repaints only when the cursor crosses into a different file.** Following the
diff cursor runs on every `CursorMoved`; rebuilding the tree on each keystroke is real work
on a large review.

**Closing a window does not end insert mode.** A composer opened with `startinsert` and
submitted from an insert-mode mapping closes its float while still inserting, and focus
lands in the review buffer mid-insert — no `InsertEnter` fires, because insert never ended.
Every navigation key is then a failed edit against a `nomodifiable` buffer instead of a
motion. The guard is a `BufEnter`/`WinEnter`/`InsertEnter` autocmd on the review buffer,
and the `stopinsert` is scheduled: issued inline, returning from the insert-mode mapping
puts Vim straight back into insert.

**Insert mode is unreachable in headless Neovim.** `startinsert` needs the interactive
input loop, so `mode()` always reports `n` under `--headless` and a headless test of the
bug above passes whether or not the fix exists. That one is verified by driving a real
Neovim over a pty and querying it with `--remote-expr`.

**`startinsert` does nothing on the tick a picker answers on.** A picker that closes with
`stopinsert` leaves the editor still reporting insert mode with the exit merely pending, so
the composer's request to start inserting is dropped as redundant and the exit lands
anyway. Reading `mode()` there is no help either — it reports the mode being left. The
composer feeds `<C-\><C-n>` and then `i` or `A` instead, which the input loop applies once
everything has settled, whichever mode the picker really left behind.

**Normal mode cannot hold a cursor past the last character of a line.** Both places the
composer positions a reviewer to keep typing — the end of a restored draft, the space after
a spliced reference — are exactly that column, so setting it arrives one short. Entering
insert with the bang (`startinsert!`, or `A` as a fed key) is what recovers it.

**A picker must return focus to whoever opened it.** `pick_target` used to hardcode focus
back to the diff window, so choosing an agent from the queue float dumped the cursor into
the diff — where `<C-s>` hits the *main* buffer's mapping, which submits the batch but
leaves the float open behind it. It also has to drive its own repaint: the picker is
asynchronous, so anything run after the call returns paints before a target exists.

## Built with Claude Code

This plugin was written with [Claude Code](https://claude.com/claude-code), and it is set
up so anyone can keep working on it that way. Said plainly for two reasons: so you know
what you are reading, and so you know agent-assisted contributions are welcome here rather
than merely tolerated.

The repo carries what an agent needs to be useful in it rather than merely fast:
[`CLAUDE.md`](CLAUDE.md) holds the workflow in imperative form, [`docs/agents/`](docs/agents/)
records where issues live and how they are labelled, and the *Design notes* above exist
because several obvious-looking approaches here are wrong for reasons no amount of reading
the code reveals. Point an agent at `CLAUDE.md` and it will follow the same branch, commit
and PR conventions a human contributor does.

The bar is the same either way — the tests pass, the design notes were read, and you can
answer questions about the change in review. There is no requirement to disclose tool use,
and no penalty for it.

## Contributing

Issues and pull requests are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) —
setup is `make hooks && make deps && make all`, and it takes about five seconds to know
whether the suite is green.

Open an issue first for anything with a design decision behind it; typo fixes and
obviously-correct one-liners can go straight to a PR. Participation is under the
[Code of Conduct](CODE_OF_CONDUCT.md); security reports go through
[`SECURITY.md`](SECURITY.md), not the issue tracker.

## License

[MIT](LICENSE) © Felipe Valencia
