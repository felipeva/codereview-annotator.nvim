# codereview-annotator.nvim

[![test](https://github.com/felipeva/codereview-annotator.nvim/actions/workflows/test.yml/badge.svg?branch=master&event=push)](https://github.com/felipeva/codereview-annotator.nvim/actions/workflows/test.yml?query=branch%3Amaster)
[![Neovim 0.12+](https://img.shields.io/badge/Neovim-0.12%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Review a diff in Neovim, leave typed notes on it, and hand the whole review to a coding
agent as one message.**

One syntax-highlighted diff of everything a branch changed — unified or side by side — with
vim-native navigation, a file tree, reviewed-file collapsing, and a batch submit at the end.

```
┌─ tree ──────────────┐┌─ Code review · branch vs origin/master · 2/7 · +9 -4 ─────┐
│ ▾ apps          1/4 ││ ○ ▾ apps/api/src/main.ts                 +12 -3  [3 notes]│
│   ▾ api/src     1/2 ││ @@ -19,6 +19,8 @@ function boot()                         │
│     ▾ routes    0/1 ││  19 │  const app = express()                              │
│       ○ users.ts    ││ ▌20 │ -const cfg = load()                                 │
│     ● main.ts     3 ││ ▌21 │ +const cfg = loadConfig()                           │
│   ▾ web/src     0/2 ││ ▌    │   🐞 why the rename? no callers were updated       │
│     ✓ index.ts      ││  22 │  app.listen(cfg.port)                               │
│ ▾ packages/…    0/1 ││                                                           │
│   ○ types.ts        ││ ✓ ▸ apps/api/src/routes.ts                       +4 -0    │
│ ○ README.md         ││                                                           │
│ 2/7 reviewed        ││ ○ ▾ apps/web/src/index.ts                        +2 -1    │
└─────────────────────┘└───────────────────────────────────────────────────────────┘
```

Everything is drawn natively in Neovim — no terminal window, no browser, no web view.

## Quick start

```lua
{
  "felipeva/codereview-annotator.nvim",
  cmd = "CodeReview",
  opts = {},
}
```

That is the whole setup. Six things get you through a review:

| Do this | What happens |
| --- | --- |
| `:CodeReview` | Opens the diff of everything your branch changed |
| `ab` | Annotates the line under the cursor as a **bug** (`af` fix, `as` suggestion, `an` nitpick, `ai` issue) |
| `R` | Marks this file reviewed — it collapses out of the way |
| `]F` | Jumps to the next file you have **not** reviewed |
| `Q` | Opens the queue, listing everything you have written so far |
| `<C-s>` | Submits the batch |

Nothing else is required. With no [adapters](#adapters) wired the review still renders,
annotates and queues; the submitted batch lands in the `+` register instead of an agent,
and stays queued because nothing consumed it.

**Requirements** — Neovim **0.12+** and `git`. Treesitter parsers are optional: files
without one fall back to flat diff colours.

## Features

### Review any diff, not just a branch

`:CodeReview` opens the branch review. Pass a scope to open something else, or press `gs`
inside the view to cycle between them in place.

| Command | What it shows |
| --- | --- |
| `:CodeReview` | Everything the branch changed against its base |
| `:CodeReview staged` | The index |
| `:CodeReview unstaged` | Working tree vs index |
| `:CodeReview worktree` | Everything uncommitted |
| `:CodeReview HEAD~3` | Any git revspec |
| `:CodeReview main...feature` | Any range |

Files are marked reviewed **against their git blob**, so a mark stops meaning anything
once the file changes underneath it.

### Unified or side by side

`layout = "unified"` (the default) stacks deleted and added lines in one column.
`layout = "split"` draws the same diff as two **panes** — the before-image on the left, the
after-image on the right — with corresponding code on the same screen row.

```lua
opts = { layout = "split" }   -- "unified" (default) or "split"; validated at setup()
```

```
┌─ tree ───────────┐┌─ Before · origin/master ────┐┌─ Code review · branch · 2/7 ─┐
│ ▾ apps       1/4 ││     apps/api/src/main.ts    ││ ● ▾ apps/api/src/main.ts +12 │
│   ▾ api/src  1/2 ││ @@ -19,6 @@                 ││ @@ +19,8 @@ function boot()  │
│     ● main.ts  3 ││  19 │  const app = express()││  19 │  const app = express() │
│   ▾ web/src  0/2 ││ ▌20 │ -const cfg = load()   ││ ▌20 │ +const cfg = loadCfg() │
│     ✓ index.ts   ││                             ││ ▌   │   🐞 why the rename?   │
│ ○ README.md      ││                             ││ ▌21 │ +cfg.validate()        │
│ 2/7 reviewed     ││  21 │  app.listen(cfg.port) ││  22 │  app.listen(cfg.port)  │
└──────────────────┘└─────────────────────────────┘└──────────────────────────────┘
```

The blank rows on the left are **filler**: the addition has no counterpart in the
before-image, so the left pane holds its place rather than letting the two drift apart.
Annotating from a filler row targets the whole file.

Both panes are syntax-highlighted, scroll together, and behave identically: collapsing,
reviewed marks, capture and navigation all work the same way, and the pane you are in
decides what is captured — a deleted line on the left, the post-image line on the right.

**`gl` switches layouts** without losing your place, from either pane or the file tree, so
you can reach for side-by-side on the one reformatted file without editing your config. The
choice lasts the rest of the session and resets when Neovim exits.

<details>
<summary>The details that occasionally matter</summary>

Buffer rows mean nothing across layouts — the same line of the same hunk sits at a
different row in each. What `gl` carries across is the **anchor** (the same line, of the
same hunk, of the same file), and the row carrying it is found again afterwards. So the
cursor lands in the pane its line belongs to, switching back is unambiguous, and a cursor
on filler falls back to that file's header. The landing line is centred, because preserving
an exact scroll offset across a structural move would be preserving something meaningless.

Chrome is split too: a hunk header shows its pre-image range on the left and its post-image
range plus git's section heading on the right, and a renamed file shows its old path on the
left and its new path on the right.

Horizontal scrolling is **not** synchronised, because doing so would mean changing
`scrollopt`, a global option this plugin does not own.

One behavioural difference, and only one: a visual **range** cannot span both images,
because the two runs live in different windows and cannot be in one selection.
Pure-addition and pure-deletion ranges work, and annotating the hunk header captures both
images inlined — so what a split range cannot express is still one keystroke away.

A layout is a rendering choice and nothing else, so which one was on screen never reaches
the receiving agent ([ADR-0002](docs/adr/0002-one-queue-one-entry-shape.md)).

</details>

### A file tree that tracks your progress

The tree collapses single-child directory chains (`apps/api/src`, not three nested rows),
sorts directories before files, and carries a reviewed tally on every directory — so you
can see which packages are done without opening them. It follows the diff cursor, and
`<Tab>` into it lands on the file you were reading.

`gp` dismisses and summons it; `panel.enabled` decides whether a review *opens* with one.
Collapsed directories belong to the review rather than to the tree, so they are exactly as
you left them when it comes back.

### Typed annotations

A type is not decoration — it changes what the receiving agent is told to do with that
group of notes.

| Type | Key | Group directive in the payload |
| --- | --- | --- |
| bug | `ab` | diagnose and fix these |
| fix | `af` | apply these changes |
| suggestion | `as` | evaluate; apply if sound |
| nitpick | `an` | low priority — batch these together |
| issue | `ai` | do NOT fix — summarize these for tracking |

`aa` opens a picker instead. Its last entry is **`no type`** — a remark worth reading with
no instruction attached. It behaves like any other entry and its group renders last, under
a bare `## Untyped (n)` heading. Declining a type is not dismissing: escape still abandons
the annotation entirely.

<details>
<summary>Replacing the type set</summary>

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
missing `name` or `key`, a duplicate of either, a `key` of `a` (which would shadow the `aa`
picker), or a field of the wrong type. Start from the shipped set with
`require("codereview.types").defaults`.

</details>

### Five things you can annotate

| Cursor is on | What gets annotated |
| --- | --- |
| A diff line | That line |
| A visual selection | Those lines |
| A hunk header | The whole hunk |
| A file header | The whole file |
| A filler row (split layout) | The whole file |

Plus a **bare note** with no file behind it at all — see below.

### Annotate from any buffer, with no review open

Capture does not need a review. `:CodeReviewAnnotate bug` queues a note about the file you
are looking at; with no type it offers the same picker `aa` does.

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

The last two are not second-class: they queue, submit and survive a restart like anything
else — a scratch buffer is a fine place to leave a thought for the batch. What you get is
an ordinary annotation, sharing the queue, the payload grouping, the batch and the
staleness rules with anything captured during a review. The buffer itself is never touched.

**Diagnostics ride along.** Errors and warnings overlapping what you captured are attached
to the note, so they stop being retyped by hand. Hints and info are left out — they are
rarely why you are annotating, and they bury the diagnostic that is.

```
why is this branch unreachable?

Diagnostics:
- ERROR L12 undefined global `foo` (lua_ls)
- WARN  L14 unused local `bar` (lua_ls)
```

### Send one annotation now

A thought you want acted on should not have to wait for a batch you have not finished
assembling. The same entry point sends one annotation on its own instead of queueing it:

```lua
require("codereview").annotate("bug", nil, { immediate = true })
require("codereview").annotate(nil, nil, { immediate = true })  -- or pick the type
```

Delivery is a property of the call, not a different door: the same paths, the same blob,
the same diagnostics, the same drafts and `@` references, and the same picker. What arrives
is an ordinary review payload that happens to hold one annotation
([ADR-0004](docs/adr/0004-an-immediate-send-is-a-batch-of-one.md)).

You are asked where it goes **before** the composer opens, so declining costs no typing.
The queue is untouched — an annotation sent this way never joins it, and whatever is
already queued is neither delivered nor cleared. If the send does not go through, the note
is kept as a draft so annotating that file again offers it back.

### The composer

Notes are written in a real buffer, not a prompt. Drafts are kept per target and survive
restarts, and `@` references another file — [`pick_file`](#adapters) supplies the picker.

### The queue and the batch

Annotations accumulate in a queue that survives `:qa` and restarts. `Q` opens a float
listing the batch, where `<CR>` jumps to any entry — closing the float and centring the
line the annotation is about, expanding the file first if it was collapsed. The queue is
therefore a way of navigating a review, not only of auditing it before you send.

Because the queue is shared with the capture path and the float opens with or without a
review, some of what it lists has nowhere to jump to: a bare note is about no file, there
may be no review open, or the file may be outside the current scope. Each says which.

### The payload

Grouped by type, in the configured order, most actionable first, with anything untyped
last. A diff is inlined where an `@ref` cannot carry the change.

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

## Keymaps

### In the diff

| Key | Action |
| --- | --- |
| `ab` `af` `as` `an` `ai` | Annotate as bug / fix / suggestion / nitpick / issue |
| `aa` | Annotate, picking the type from a menu or declining one |
| `x` | Drop the annotation under the cursor |
| `R` | Toggle reviewed on this file (collapses it) |
| `za` | Toggle expansion without marking reviewed |
| `gs` | Cycle scope, re-rendering in place |
| `gr` | Re-read the diff from git |
| `gp` | Show or hide the file tree |
| `gl` | Switch between the unified and split layouts |
| `<CR>` | Open the real file here, in a new tab |
| `Q` | Review the queue |
| `<C-t>` | Choose the delivery target |
| `<C-s>` | Submit the batch |
| `q` | Close |

Annotation keys are prefixed with `a` rather than bound bare, because bare `b`, `f`, `n`
and `s` would shadow back-word, find-char, next-search and (if you use it) flash.nvim
inside the buffer. `a` is append, which is dead in a `nomodifiable` buffer, so the prefix
costs a keystroke and no motion.

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
| `gp` | Dismiss the tree, landing back in the diff |
| `gl` | Switch between the unified and split layouts |
| `q` | Close |

Jumping to a file that was collapsed because it is reviewed expands it: you asked to look
at it.

### In the queue float

| Key | Action |
| --- | --- |
| `<CR>` | Jump to the annotation under the cursor |
| `x` | Drop it |
| `<C-t>` | Choose the delivery target |
| `<C-s>` | Submit the batch |
| `q` / `<Esc>` | Close, keeping the queue |

## Configuration

```lua
opts = {
  context = 3,                     -- git diff -U
  untracked = true,                -- show untracked files in branch/worktree scopes
  syntax = true,                   -- treesitter highlighting
  max_syntax_bytes = 256 * 1024,   -- skip syntax above this size
  layout = "unified",              -- "unified" or "split"; validated at setup
  panel = { enabled = true, width = 34, position = "left" },
  icons = { reviewed = "✓", annotated = "●", unreviewed = "○",
            collapsed = "▸", expanded = "▾", change_bar = "▌" },
  types = nil,                     -- defaults to the five above; see Typed annotations
}
```

Every highlight is a `default = true` link to a group your colorscheme already defines
(`DiffAdd`, `Added`, `DiagnosticError`, …), so overriding any `CodeReview*` group works
without the plugin fighting back.

## Adapters

The plugin has no opinion about where a review goes, or about which pickers you use. Four
optional functions inject that — **none are required.**

| Adapter | What it supplies | Without it |
| --- | --- | --- |
| `send` | Delivers the rendered batch | The payload goes to the `+` register |
| `pick_target` | Chooses a delivery target | No target; `send` decides what that means |
| `pick_file` | Picks a file for `@` in the composer | `@` stays a literal `@`, and says so |
| `compose` | Collects note text | The composer the plugin ships |

```lua
opts = {
  send = function(payload, target) return true end,
  pick_target = function(cb) cb({ short = "agent", cwd = "/path" }) end,
  pick_file = function(cb) cb({ path = "src/main.lua", first = 12, last = 20 }) end,
  compose = function(ctx, on_accept, label) on_accept(nil, "text") end,
}
```

<details>
<summary>The full contract for each</summary>

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

</details>

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

## Persistence

Reviewed marks and the queue are stored per repository under
`stdpath("state")/codereview/`, keyed by scope and diff base, and survive a restart. Each
entry records the git blob it was captured against. On reload:

- a **reviewed mark** whose blob moved is silently un-marked — the file changed, so you
  have not reviewed what is there now;
- an **annotation** whose blob moved is kept and flagged `⚠ stale`, because the prose is
  still worth sending and only its line anchor is untrustworthy. A stale entry never
  travels as an `@ref`; its code is inlined instead.

Two things deliberately do **not** persist: the delivery target, which names a live
destination a restart would make dead, and the layout `gl` last chose, which is a
preference rather than review progress. The store is per repository and neither of those
is; both last for the session and no longer.

<details>
<summary>Annotations with no repository behind them</summary>

A bare note, or a file outside any checkout, has nowhere repository-shaped to live, so it
goes to a single global store beside the others. Nothing ever reconciles that store against
a diff, so nothing would ever clear it: entries older than **seven days** are dropped when
it is read. That bounds its growth but not its staleness, which is the accepted cost of not
making those annotations second-class.

Each kind is judged against whatever its blob was actually taken from. A review annotation
is judged against the diff on screen, and a file the current scope does not include is not
evidence that anything changed — so it is left alone. An annotation captured from a buffer
has no scope behind it and is judged against the file on disk, at any scope and with no
review open. That distinction matters in a `staged` review, where the diff shows the index
and a buffer capture holds the working tree: judging one by the other would flag a note
about a file nobody has touched.

</details>

## Documentation

| Where | What is in it |
| --- | --- |
| `:help codereview` | The full reference — every command, mapping, option and Lua API |
| [`docs/design-notes.md`](docs/design-notes.md) | Every non-obvious constraint that cost real debugging time |
| [`docs/adr/`](docs/adr/) | The decisions behind the architecture, and why |
| [`CONTEXT.md`](CONTEXT.md) | The project's vocabulary — *scope*, *pane*, *filler*, *dispatch*, … |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Setup, tests, the commit convention, PR shape |

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

## Contributing

Issues and pull requests are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) —
setup is `make hooks && make deps && make all`, and it takes about five seconds to know
whether the suite is green.

Open an issue first for anything with a design decision behind it; typo fixes and
obviously-correct one-liners can go straight to a PR. Participation is under the
[Code of Conduct](CODE_OF_CONDUCT.md); security reports go through
[`SECURITY.md`](SECURITY.md), not the issue tracker.

### Built with Claude Code

This plugin was written with [Claude Code](https://claude.com/claude-code), and it is set
up so anyone can keep working on it that way. Said plainly for two reasons: so you know
what you are reading, and so you know agent-assisted contributions are welcome here rather
than merely tolerated.

The repo carries what an agent needs to be useful in it rather than merely fast:
[`CLAUDE.md`](CLAUDE.md) holds the workflow in imperative form, [`docs/agents/`](docs/agents/)
records where issues live and how they are labelled, and
[`docs/design-notes.md`](docs/design-notes.md) exists because several obvious-looking
approaches here are wrong for reasons no amount of reading the code reveals. Point an agent
at `CLAUDE.md` and it will follow the same branch, commit and PR conventions a human
contributor does.

The bar is the same either way — the tests pass, the design notes were read, and you can
answer questions about the change in review. There is no requirement to disclose tool use,
and no penalty for it.

## License

[MIT](LICENSE) © Felipe Valencia
