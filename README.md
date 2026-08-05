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
│   ▾ web/src     0/2 ││ ▌   │   🐞 why the rename? no callers were updated        │
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
| `:CodeReview since-batch` | What changed since the last batch went out |
| `:CodeReview HEAD~3` | Any git revspec |
| `:CodeReview main...feature` | Any range |

Files are marked reviewed **against their git blob**, so a mark stops meaning anything
once the file changes underneath it.

**`since-batch` is the one to reach for while an agent is working.** Submitting records a
snapshot of the working tree, and this scope diffs against it — so what you get is the
agent's response to your review, without the work you already had in flight when you sent
it. It behaves like every other scope in every other respect: highlighted, navigable,
collapsible, annotatable, and drawn in both layouts. `gs` reaches it once something has
been dispatched from the repository, and never before that; asking for it by name with
nothing dispatched says so in a sentence.

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
left and its new path on the right — on the winbar as well as in the buffer, so the left
pane's sticky header names the pre-image path beside the revision it is showing.

Horizontal scrolling is **not** synchronised, because doing so would mean changing
`scrollopt`, a global option this plugin does not own.

One behavioural difference, and only one: a visual **range** cannot span both images,
because the two runs live in different windows and cannot be in one selection.
Pure-addition and pure-deletion ranges work, and annotating the hunk header captures both
images inlined — so what a split range cannot express is still one keystroke away.

A layout is a rendering choice and nothing else, so which one was on screen never reaches
the receiving agent ([ADR-0002](docs/adr/0002-one-queue-one-entry-shape.md)).

</details>

### See what changed *inside* a changed line

Rename one identifier in an eighty-column line and a plain diff shows you two eighty-column
lines, one red and one green, with nothing pointing at the four characters that differ. So
the **spans** that actually differ are emphasised inside the pair, and the rest of the line
keeps its ordinary red or green — you read the change, not the line.

```
▌20 │ -const cfg = load()
▌20 │ +const cfg = loadConfig()
                       ▔▔▔▔▔▔ emphasised
```

On by default, in both layouts, and in both panes on the same row.

```lua
opts = { spans = false }   -- true by default; validated at setup()
```

Granularity is characters, not words, so an edit inside an identifier is pointed at
precisely and a re-indentation is visible rather than mysterious. Where two lines share so
little that emphasising the change would emphasise nearly all of both, they are left plainly
coloured: that is a replacement, not an edit.

<details>
<summary>The details that occasionally matter</summary>

**Which lines pair.** The i-th deletion of a contiguous run pairs with the i-th addition of
the run that follows it — the pairing the split layout already uses to put a deletion and
its replacement on one row. Using it in both layouts is why the same characters are
emphasised either side of a `gl`. Where the runs are unequal the surplus lines carry
nothing, and neither does a pure addition, a pure deletion, or a file that exists on only
one side: there is nothing to compare them against.

**When it says nothing.** Above **60% of the longer line** inside spans, the pair is left
alone. The figure was read off real diffs rather than derived — at 70% a quarter of the
unrelated pairs inside a long run were still being emphasised, and every genuine one-line
edit above 60% turned out to be a replacement wearing an edit's clothes. A re-indentation is
nowhere near it: every reformatted pair measured came in under 10%.

**When the work happens.** At parse time, once per git read — never during a repaint. On a
12,000-line diff the spans cost about as much again as a whole repaint, and a repaint runs
on every resize, expansion, reviewed toggle and scope change. `make perf` reports the figure
on its own line so a change that moves the work back into the render is visible.

**Two highlight groups**, `CodeReviewAddSpan` and `CodeReviewDelSpan`, both taking
`DiffText`'s **background and nothing else**. A foreground there would sit beneath the
treesitter replay: it would lose wherever a parser had painted and win wherever one had not,
which is emphasis that changes colour depending on which languages you have installed.

The emphasis is a rendering refinement and nothing else. What you capture, what reaches the
queue and what the payload says are untouched
([ADR-0002](docs/adr/0002-one-queue-one-entry-shape.md)).

</details>

### A file tree that tracks your progress

The tree collapses single-child directory chains (`apps/api/src`, not three nested rows),
sorts directories before files, and carries a reviewed tally on every directory — so you
can see which packages are done without opening them. It follows the diff cursor, and
`<Tab>` into it lands on the file you were reading.

`gp` dismisses and summons it; `panel.enabled` decides whether a review *opens* with one.
Collapsed directories belong to the review rather than to the tree, so they are exactly as
you left them when it comes back.

### The pane you are in is the bright one

A review can hold three windows at once — the before pane, the after pane and the tree — and
the pane without focus is **muted**: its colours pulled toward the background, so where you
are is on screen instead of something you have to press a key to find out. The `cursorline`
goes with it, which is what stops the split layout lighting a row in both panes while saying
nothing about either.

The file tree is never muted. It is the map of the review — the paths, the icons, the
per-directory tallies and the `+N -M` counts — so it draws in your colorscheme's own colours
whichever window you are in, with the row for the file you are reading lit. Move into it and
the panes mute, both of them in the split layout and the one of them in the unified layout,
so you can see that your keys now act on the tree.

The colours come from your own colorscheme, blended: nothing here has a palette of its own,
and a group the plugin cannot know about is left bright rather than guessed at, so an
unfamiliar theme degrades to *less muted* and never to *wrong*. A float — the composer, the
queue float, the last-batch float — changes nothing: the bright window is the review window
you were last in, not the window with the cursor in it.

`muted = { enabled = false }` turns it off whole; `strength` is one number from 0 to 1
saying how far toward the background a colour goes.

### The file you are in is the only one at full strength

Every other file in the review is **faded**: the colours of its rows pulled toward the
background, so the file you are reading has a boundary and the file you just left stops
competing with it. Cross into another file and the fade follows the cursor. Move from one
hunk to the next inside one file and nothing changes at all — the unit is the file.

A faded file keeps its header row bright, with its path, its `+N -M` and its note count, so
the review reads as bright headers over quiet bodies with one file at full strength. Its
hunk headers fade with its body.

The colours are the muting's, blended from your own colorscheme at a strength of its own,
and a faded file keeps its syntax structure rather than flattening to one tone: what changes
is which group each mark carries, never the order they are drawn in. A group your theme
gives no colour of its own is left bright, exactly as it is in a muted window.

`faded = { enabled = false }` turns it off whole; `strength` is its own number, and it is
gentler than the muting's by default because this covers every file but one.

### The file you are in, on the winbar

A file's header row scrolls off the top as soon as you read past the first screenful of it.
The **sticky header** keeps it:

```
 ○ ▾ src/routes.lua  +12 -3  [2 notes]        branch vs master · 2/7 reviewed · +40 -9
```

The same icon, chevron, path, `+N -M` and note count the in-buffer header carries, with the
review summary right-aligned beside it. It names the file the **cursor** is in — not the one
at the top of the window — so it is the file an annotation would attach to, which is what
you are reaching for when you annotate twenty lines into a hunk. It works with the tree
dismissed, and with a review opened without one.

In the split layout each pane names its own side, so a rename reads correctly on the side
holding the old name; the unified layout spells it `old → new`, exactly as the file header
does. On a pane too narrow for both halves the summary gives way first — starting with what
the file beside it now says twice — and the path keeps its tail.

The bar is chrome of the review window it sits on, so it mutes with that window: on the pane
without focus the sticky header recedes with everything else in it.

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

`gy` — in the diff, in the float, or as `:CodeReviewCopy` from anywhere — puts the payload
in the `+` register without submitting it. It is the same text `send` would have been
handed, target and all, and it costs the batch nothing: the queue is untouched, so reading
what an agent will be told is not a decision to send it.

### Read the last batch back after it goes

A submit clears the queue, which is the moment "what did I actually ask for?" stops having
an answer anywhere but the agent's transcript. `:CodeReviewLastBatch` gives it one: the
annotations of the batch that went last, grouped by type exactly as the queue float and the
payload group them, with the target it went to and when it went in the frame.

`gb` opens that same float from inside a review, in the diff and in the tree, so which
window you are in never decides whether the key exists. The command needs no review open —
a batch is not a window, and what you asked for is worth checking from anywhere. A bare note
is listed like anything else, even though it was kept in a different store than the
annotations with a file behind them.

It is **read-only**, and that is a statement about the record rather than a feature left
out. An archived entry says something happened; a surface that let you drop, edit or
resubmit one would be claiming the plugin can revise what an agent already received. To
raise a point again, annotate again — that is an ordinary capture, and it joins the next
batch.

### What you already reported stays on the diff

A dispatched batch does not leave the review view. Its entries keep the anchors they were
bound to and are drawn dimmed beneath the code they were about, projected exactly as live
annotations are. A reviewer who keeps going while the agent works is otherwise looking at a
diff with no memory of what it already sent, and reports the same finding twice.

They draw in **every scope**, not only `since-batch` — knowing what has already been said is
worth as much wherever you are. An anchor carrying both a queued and an archived entry draws
both, the queued one first: what is still to send outranks what has already gone. `x` there
drops the queued one and never the archived one; nothing on the diff can revise a batch that
already went, for the same reason the last-batch float is read-only.

Their two highlight groups are their own — `CodeReviewArchived` for the marker and
`CodeReviewArchivedNote` for the prose — and are `default = true` links like everything else
here, so a colorscheme can say how dim "already sent" looks. `archived = false` turns them
off wholesale, and the diff then renders exactly as it did before the archive existed.

### Where the agent has and has not been

Each entry of the **last** batch says whether its file has changed since that batch was
dispatched — `file changed` or `file unchanged` beside the note — and the winbar tallies the
ones that have not:

```
 Code review · branch vs master · 2/7 reviewed · +40 -12 · 1 note · 2 untouched · → janus
```

`2 untouched` is the answer to *did it ignore something*, and it is exact on the case that
matters: a file the agent never opened. The comparison is **per file**, against the snapshot
the batch went out with — the same commit `since-batch` diffs against, so a file the tally
calls touched is exactly a file that scope shows you.

The word is *touched*, not *addressed*. The plugin knows the file moved. It does not know
that anyone read your note, agreed with it, or acted on it, and it will not imply otherwise.
It is also not **staleness**: that is the same kind of comparison against a different blob,
it is about entries still in the queue, and it means *this note may now be wrong* rather than
*something happened here*. The two are never merged, and an archived entry never shows a
stale flag.

Three things are left unjudged rather than guessed at — a file the current scope does not
cover, a file that was untracked when the batch went (a snapshot does not record those), and
a **bare note**, which is about no file at all. A file *deleted* since the dispatch counts as
touched. Nothing judged means no segment at all rather than a zero to misread.

That the scope decides who is judged is why the tally reads `0 untouched` inside
`since-batch`: that scope shows you exactly the files that moved, so every entry it covers is
touched by definition, and the ones you are looking for are the ones it is not showing.
`branch` and `worktree` are where the number earns its keep.

`CodeReviewTouched` and `CodeReviewUntouched` are the groups, and `archived = false` turns
the tally off along with everything else.

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
| `gs` | Cycle scope, re-rendering in place — `since-batch` joins once a batch has gone |
| `gr` | Re-read the diff from git |
| `gp` | Show or hide the file tree |
| `gl` | Switch between the unified and split layouts |
| `gb` | Read the last dispatched batch back |
| `<CR>` | Open the real file here, in a new tab |
| `gd` | Read this file in your own diff tool — only bound with [`open_diff`](#adapters) wired |
| `Q` | Review the queue |
| `gy` | Copy the batch to the `+` register, without submitting it |
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
| `gd` | Read the file under the cursor in your own diff tool — only bound with [`open_diff`](#adapters) wired |
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
| `gb` | Read the last dispatched batch back |
| `q` | Close |

Jumping to a file that was collapsed because it is reviewed expands it: you asked to look
at it.

### In the queue float

Each annotation is a run of rows carrying a bar in its type's colour — its location, the
code it inlines, and its note, kept as you wrote it and wrapped to the float. The bar runs
through blank lines *inside* a note and stops between annotations, so you can always see
where one ends. Every row belongs to the annotation it is drawn under, so `x` drops what is
under the cursor and not what a heading further up happened to say.

| Key | Action |
| --- | --- |
| `<CR>` | Jump to the annotation under the cursor |
| `x` | Drop it |
| `gy` | Copy the batch to the `+` register, without submitting it |
| `<C-t>` | Choose the delivery target |
| `<C-s>` | Submit the batch |
| `q` / `<Esc>` | Close, keeping the queue |

`gy` leaves the float open, because it takes nothing out of the queue — everything it is
listing is still there.

### In the last-batch float

`gb`, or `:CodeReviewLastBatch` from anywhere, lists an annotation the same way — the
reserved gutter, the bar in its type's colour, the code it inlined and its note — so the two
read as one family. What is missing is every key that would change something.

| Key | Action |
| --- | --- |
| `q` / `<Esc>` | Close |
| `x` `<C-s>` | Bound only to say why they do nothing here |

Those two are bound rather than left off so that the queue float's muscle memory gets a
sentence instead of `E21`. Nothing else is: the batch has gone, and there is nothing left
to route, drop or send.

## Configuration

```lua
opts = {
  context = 3,                     -- git diff -U
  untracked = true,                -- show untracked files in branch/worktree scopes
  syntax = true,                   -- treesitter highlighting
  max_syntax_bytes = 256 * 1024,   -- skip syntax above this size
  layout = "unified",              -- "unified" or "split"; validated at setup
  spans = true,                    -- emphasise what changed inside a changed line
  archived = true,                 -- draw already-dispatched entries on the diff, dimmed,
                                   -- and tally the untouched ones on the winbar
  muted = { enabled = true,        -- mute the pane that does not have focus; never the tree
            strength = 0.5 },      -- how far its colours are pulled toward the background
  faded = { enabled = true,        -- fade every file except the one the cursor is in
            strength = 0.35 },     -- its own number: this covers every file but one
  panel = { enabled = true, width = 34, position = "left" },
  icons = { reviewed = "✓", annotated = "●", unreviewed = "○",
            collapsed = "▸", expanded = "▾", change_bar = "▌" },
  types = nil,                     -- defaults to the five above; see Typed annotations
}
```

Every highlight is a `default = true` link to a group your colorscheme already defines
(`DiffAdd`, `Added`, `DiagnosticError`, …), so overriding any `CodeReview*` group works
without the plugin fighting back. The two exceptions are `CodeReviewAddSpan` and
`CodeReviewDelSpan`, which take `DiffText`'s background and set no foreground — still
`default = true`, so overriding them works the same way.

Two families of groups are computed rather than linked, and they are not yours to set. A
**muted** pane draws through a twin of each group named `CodeReviewMuted.` plus the group
it blends — `CodeReviewMuted.CodeReviewAdd`, `CodeReviewMuted.@keyword`. A **faded** file's
rows are drawn in a twin named `CodeReviewFaded.` plus the same, at `faded.strength` instead
of `muted.strength`. Each holds that group's own colours pulled that far toward the
background, and each is written again on every colorscheme change, so setting one yourself is
overwritten. Set the strength, or the group the twin is named for. A group your theme gives
no colour of its own gets no twin in either family, and is drawn at full brightness — muted
or faded, that is the same rule.

## Adapters

The plugin has no opinion about where a review goes, about which pickers you use, or about
which diff tool you read a rewrite in. Five optional functions inject that — **none are
required.**

| Adapter | What it supplies | Without it |
| --- | --- | --- |
| `send` | Delivers the rendered batch | The payload goes to the `+` register |
| `pick_target` | Chooses a delivery target | No target; `send` decides what that means |
| `pick_file` | Picks a file for `@` in the composer | `@` stays a literal `@`, and says so |
| `compose` | Collects note text | The composer the plugin ships |
| `open_diff` | Reads one file in your own diff tool | `gd` is not bound at all |

```lua
opts = {
  send = function(payload, target) return true end,
  pick_target = function(cb) cb({ short = "agent", cwd = "/path" }) end,
  pick_file = function(cb) cb({ path = "src/main.lua", first = 12, last = 20 }) end,
  compose = function(ctx, on_accept, label) on_accept(nil, "text") end,
  open_diff = function(spec) end,  -- spec: { path, before, after, line }
}
```

**You cannot annotate in whatever `open_diff` opens.** Nothing there has an anchor map, so
it is a one-way trip: read the file closely, then come back to the review to say anything
about it. It is for the rewrite that Neovim's own diff mode reads better than a unified
diff does — a reformat, a re-indent, a file moved wholesale — not a second review surface.

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
  -- queue, and it is a warning rather than an error because nothing is broken. `gy` puts
  -- the payload in that register deliberately, whatever is wired here, so what an adapter
  -- receives is readable without submitting to find out.
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

  -- Read one file in the diff tool you already have — DiffviewOpen, :Gdiffsplit, your own
  -- diffthis pair. The plugin ships none of that: it hands over the file and the two refs
  -- its scope is between and stops caring. `path` is absolute and is the post-image path,
  -- so for a rename the pre-image lives elsewhere in `before`. `after` is nil whenever the
  -- post-image is the working tree — that is most scopes, and it is not an error: nil
  -- means the file on disk. `line` is nil when the file was named from the file tree,
  -- which knows a file and no position in it.
  --
  -- Bound to `gd` only while this is wired, in the diff and in the tree. A key that
  -- silently did nothing would be worse than no key.
  open_diff = function(spec)
    local rev = spec.after and (spec.before .. ".." .. spec.after) or spec.before
    vim.cmd(("DiffviewOpen %s -- %s"):format(rev, vim.fn.fnameescape(spec.path)))
  end,
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

Reviewed marks, the queue and the batches already dispatched are stored per repository
under `stdpath("state")/codereview/`, keyed by scope and diff base, and survive a restart.
Each entry records the git blob it was captured against. On reload:

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

</details>

<details>
<summary>What a dispatched batch leaves behind</summary>

A batch that is **dispatched** is kept rather than forgotten: the annotations as they went,
where they went, when, and a **snapshot** of the working tree at that moment — a commit
object minted with `git stash create`, which moves no ref, leaves the index alone and never
touches your files. On a clean tree there is nothing to record that `HEAD` does not already
say, and `HEAD` is what is stored.

A dispatch writes it and nothing else does. An adapter that declined, one that raised, the
`+` register the default send copies to and the one `gy` copies to deliberately all leave
it exactly as they leave the queue — a payload sitting in a register is not something an
agent received. An immediate send is a batch of one and is kept as one. The most recent
**twenty** batches are kept per store, oldest dropped on write.

`:CodeReviewLastBatch` reads the newest one back. A batch holding both kinds of annotation
is written to both stores and rejoined by the moment it was dispatched, which is what stops
a bare note being the one thing missing from what you read back.

</details>

<details>
<summary>What staleness is judged against</summary>

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
