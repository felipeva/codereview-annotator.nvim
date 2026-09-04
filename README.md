# codereview-annotator.nvim

[![test](https://github.com/felipeva/codereview-annotator.nvim/actions/workflows/test.yml/badge.svg?branch=master&event=push)](https://github.com/felipeva/codereview-annotator.nvim/actions/workflows/test.yml?query=branch%3Amaster)
[![Neovim 0.12+](https://img.shields.io/badge/Neovim-0.12%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Review a diff in Neovim. Annotate what needs work. Send the whole review to a coding agent
as one message.**

You get one syntax-highlighted diff of everything a branch changed, unified or side by side.
It has vim-native navigation, a file tree, reviewed-file collapsing, and a batch submit at
the end.

```
┌─ tree ──────────────┐┌─ branch vs origin/master · ✓2/7 · +9 -4 ──────────────────┐
│ ▾ apps          1/4 ││ ○ ▾ apps/api/src/main.ts                 +12 -3  [3 notes]│
│   ▾ api/src     1/2 ││ @@ -19,6 +19,8 @@ function boot()                         │
│     ▾ routes    0/1 ││  19 │  const app = express()                              │
│       ○ users.ts    ││ ▌20 │ -const cfg = load()                                 │
│     ● main.ts     3 ││ ▌21 │ +const cfg = loadConfig()                           │
│   ▾ web/src     0/2 ││ ▌   │   ✗ why the rename? no callers were updated         │
│     ✓ index.ts      ││  22 │  app.listen(cfg.port)                               │
│ ▾ packages/…    0/1 ││                                                           │
│   ○ types.ts        ││ ✓ ▸ apps/api/src/routes.ts                       +4 -0    │
│ ○ README.md         ││                                                           │
│ 2/7 reviewed ██░░░░░││ ○ ▾ apps/web/src/index.ts                        +2 -1    │
└─────────────────────┘└───────────────────────────────────────────────────────────┘
```

Neovim draws everything. There is no terminal window, no browser and no web view.

## Contents

- [Install](#install) · [Your first review](#your-first-review) · [Keymaps](#keymaps)
- [What you can review](#what-you-can-review) · [Annotations](#annotations) ·
  [The queue and the batch](#the-queue-and-the-batch)
- [Reading the diff](#reading-the-diff) · [Configuration](#configuration) ·
  [Adapters](#adapters) · [Persistence](#persistence)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "felipeva/codereview-annotator.nvim",
  cmd = "CodeReview",
  opts = {},
}
```

That is the whole configuration. Nothing else is required.

**Requirements:** Neovim 0.12 or later, and `git`. Treesitter parsers are optional. A file
without a parser falls back to flat diff colors.

Taking a commit out of the **middle** of a branch review needs **git 2.38 or later**, which
is where `git merge-tree --write-tree` arrives. That is the only thing the floor is for.
Every other reading works on any git, a trim included: a trim that only takes commits off the
start of the branch reads from a commit that already exists and merges nothing.

## Your first review

Six keys get you through a review.

1. Run `:CodeReview`. It opens the diff of everything your branch changed.
2. Move to a line that needs work. Press `ab` to annotate it as a bug.
3. Write the note in the composer. Press `<C-s>` to queue it.
4. Press `R` to mark the file reviewed. The file collapses out of the way.
5. Press `]F` to jump to the next file you have not reviewed.
6. Press `Q` to read the queue, then `<C-s>` to submit the batch.

`af`, `as`, `an` and `ai` annotate as a fix, a suggestion, a nitpick and an issue. Press `q`
to close the review.

> **Note:** With no [adapters](#adapters) wired, the review still draws, annotates and
> queues. The submitted batch goes to the `+` register instead of an agent. It stays queued,
> because nothing consumed it.

## Keymaps

### In the diff

| Key | Action |
| --- | --- |
| `ab` `af` `as` `an` `ai` | Annotate as bug / fix / suggestion / nitpick / issue |
| `aa` | Annotate. Pick the type from a menu, or decline one |
| `x` | Drop the annotation under the cursor |
| `R` | Toggle reviewed on this file, which collapses it — under **solo**, goes on to the next unreviewed file |
| `za` | Toggle expansion without marking the file reviewed |
| `gs` | Cycle scope and draw again in place |
| `gr` | Read the diff again from git |
| `gp` | Show or hide the file tree |
| `gl` | Toggle the unified and split layouts |
| `gb` | Read the last dispatched batch back |
| `gc` | List the commits on the branch, and check the ones to review |
| `gA` | Show or hide archived entries, for the rest of the session |
| `gS` | Switch the review to another checkout of this repository |
| `gw` | Fold long lines, or stop folding them, for the rest of the session |
| `go` | Draw one file at a time, or every file, for the rest of the session |
| `<CR>` | Open the real file here, in a new tab |
| `gd` | Read this file in your own diff tool ([`open_diff`](#adapters) only) |
| `Q` | Read the queue |
| `gy` | Copy the batch to the `+` register, without submitting it |
| `<C-t>` | Choose the delivery target |
| `<C-s>` | Submit the batch |
| `<C-a>` | Submit the batch under a [preamble](#the-preamble) |
| `q` | Close |

### Moving around

| Key | Action |
| --- | --- |
| `]f` `[f` | Next / previous file |
| `]F` `[F` | Next / previous **unreviewed** file, which wraps |
| `]h` `[h` | Next / previous hunk |
| `]a` `[a` | Next / previous annotation |
| `<C-p>` | Jump to a file by name, from a list |
| `<Tab>` | Move between the diff and the tree |

### In the composer

| Key | Action |
| --- | --- |
| `<C-s>` | Queue the note and close, or send it on an [immediate send](#send-one-annotation-now) |
| `<C-t>` | Choose where this note goes |
| `@` | Reference another file ([`pick_file`](#adapters) only) |
| `<C-d>` | Discard a restored draft |
| `q` / `<Esc>` | Abandon. Keep what you wrote as a draft |

The composer opens in insert mode. `<C-s>` and `<C-t>` work in insert and normal mode alike.

<details>
<summary>The file tree, the queue float, the last-batch float and the commit list</summary>

**In the file tree**

| Key | Action |
| --- | --- |
| `<CR>` / `o` | Open the file, or fold the directory |
| `gd` | Read this file in your own diff tool ([`open_diff`](#adapters) only) |
| `h` / `zc` | Collapse the directory. On a file, collapse its parent |
| `l` / `zo` | Expand the directory |
| `za` | Toggle the directory |
| `zM` / `zR` | Collapse / expand every directory |
| `]f` `[f` | Next / previous file. Skip directory rows |
| `R` | Toggle reviewed. On a directory, toggle the whole subtree — under **solo**, a file row goes on to the next unreviewed file |
| `<C-p>` | Jump to a file by name |
| `<Tab>` | Back to the diff |
| `gp` | Dismiss the tree and land back in the diff |
| `gl` `gb` `gc` `gA` `gS` `gw` `go` | The same as in the diff |
| `q` | Close |

If you jump to a file that was collapsed because it is reviewed, the plugin expands it. You
asked to look at it.

**In the queue float**

| Key | Action |
| --- | --- |
| `<CR>` | Jump to the annotation under the cursor |
| `x` | Drop it |
| `gy` | Copy the batch to the `+` register, without submitting it |
| `<C-t>` | Choose the delivery target |
| `<C-s>` | Submit the batch |
| `<C-a>` | Submit the batch under a [preamble](#the-preamble) |
| `q` / `<Esc>` | Close. Keep the queue |

`gy` leaves the float open, because it takes nothing out of the queue.

**In the last-batch float**

| Key | Action |
| --- | --- |
| `q` / `<Esc>` | Close |
| `x` `<C-s>` | Bound only to say why they do nothing here |

**In the commit list**

| Key | Action |
| --- | --- |
| `<Space>` | Take the commit under the cursor in or out of the review |
| `<Space>` in visual mode | Take every commit in the rows you drew in or out together |
| `]c` `[c` | Next / previous checked commit |
| `<CR>` | Apply the boxes and close |
| `q` / `<Esc>` | Close and change nothing |

</details>

Annotation keys carry an `a` prefix, because bare `b`, `f`, `n` and `s` shadow motions inside
the buffer. [Why, and why `]F` is the motion that matters](docs/rationale.md#annotation-keys).

## What you can review

`:CodeReview` opens the branch review. Pass a scope to open something else. Inside the view,
press `gs` to cycle between the scopes in place.

| Command | What it shows |
| --- | --- |
| `:CodeReview` | Everything the branch changed against its base |
| `:CodeReview staged` | The index |
| `:CodeReview unstaged` | Working tree against the index |
| `:CodeReview worktree` | Everything uncommitted |
| `:CodeReview since-batch` | What changed since the last batch went out |
| `:CodeReview HEAD~3` | Any git revspec |
| `:CodeReview main...feature` | Any range |

The plugin marks a file reviewed against its git blob. If the file changes underneath the
mark, the mark stops meaning anything.

### Review another checkout

You run agents in git worktrees. `:CodeReviewSwitch`, or `gS` inside the review, moves the
review to another **checkout** of the same repository — the main clone or any worktree of it
— without a second Neovim and without disturbing the tab you were working in.

It works with no review open, which is how you open a review somewhere else in the first
place. The list is built from git's own worktree listing; replace the chooser with
[`pick_checkout`](#adapters) to get it in the picker your config already uses.

`:CodeReviewBack` goes back to the checkout you came from. It is the same journey, with the
destination taken from where you have been rather than asked for — and the checkout you came
from is also the **first entry the picker offers**, so going back is the gesture you already
have. There is no forward and none is needed: after going back, going forward again is that
same first entry.

The checkouts you have been in are held one each, most recent first, so moving back and forth
between two does not fill the list with repeats. One whose directory is gone is walked over
and named, so a pruned agent worktree is visible rather than silent; one that is still there
with nothing in its branch scope says so and is kept, so you have not lost it. The trail lives
for the session and is never written to disk — it is where you have been, not what you were
reviewing.

Each checkout keeps its own queue, its own reviewed marks, its own trims and its own
archive. Leaving one is lossless and returning gives back exactly what you left, so
switching with annotations still queued is safe and is not confirmed. Your **global**
working directory never moves and the tab you started in keeps its own, so you can always
get back to where you started; only the review's own tab is pointed at the checkout, for
your LSP, your diff signs and a relative `:e`.

Returning also reopens the **scope** that checkout was last reviewed in — reviewed marks are
kept per scope, so which scope opens decides which marks come back. A checkout you have
never reviewed opens the branch review, and so does one whose remembered scope can no longer
be shown: a revspec whose branch has gone, or a `staged` scope you have since committed. A
restart is not a return, though — `:CodeReview` with no argument always means the branch
review, wherever you are and whatever you last read.

### Trim a branch review

A branch review can read any set of the branch's commits. Press `gc` to list them, newest
first. Every row carries a checkbox saying whether that commit is in your review. `<Space>`
toggles the row under the cursor, both ways, and `<CR>` applies the boxes and closes the list.

Uncheck the oldest commits and the review starts further up the branch. The scope label says
so: `branch vs origin/master · last 4`. Uncheck one commit in the middle — a formatter run, a
mechanical rename — and the commits older than it stay in the review. The label says that
differently, because the reading is no longer a run of commits: `branch vs origin/master ·
4 of 5`.

A run of commits — a rebase's worth of fixups, a stretch of mechanical churn — costs one
press rather than one per row. Draw the rows in visual mode and press `<Space>` once. The
rows all become the same rather than each one flipping, and what they become follows the row
you started on: start on a checked row and the whole run leaves the review, start on an
unchecked one and the whole run comes back in. So a run that is already half checked resolves
the way you drew it rather than the way it happened to be.

The top row is "All commits", and it works both ways. Check it and the whole branch is back
in the review. Uncheck it and every commit leaves, which is a review of your uncommitted work
alone, labelled `0 of 5`. A run that reaches that row leaves it alone and treats the commits
under it normally — it already means every box at once, and a run that happens to touch the
top of the list should not do something larger than you drew.

On a long branch, `]c` and `[c` move between the commits you have checked, so coming back to
a decision you already made costs a keystroke instead of a scroll. Neither wraps: at the last
checked commit `]c` says there is no next one rather than sending you somewhere you did not
ask for. The list is an ordinary buffer, so `/`, `n`, `N`, `gg` and `G` reach a commit by its
subject and reach the ends of the branch — nothing is mapped over them.

The cursor opens on the reading you already have: the oldest commit still in your review, or
"All commits" while the whole branch is in it.

The list's title counts what you have checked while you are checking it — `Commits on this
branch · 3 of 5 checked` — and it moves on every `<Space>`. With the whole branch in the
review it reads `5 commits`, and with nothing checked it says that instead. Nothing reaches
the review until `<CR>`, so the title is the one place that says what you are building before
you build it.

The list is as tall as your terminal lets it be, so a long branch shows more of itself on a
tall screen. It never grows past the commits it lists, and it stays a centered float: it
adjusts your review rather than replaces it.

Every row also says how big its commit is: `3f +212 -48` is three files, two hundred and
twelve lines added and forty-eight deleted. That is what separates a formatter run from a
one-line fix before you decide to read it. The counts cost a pass over the whole branch, so
the list does not wait for them — it opens on the commits and fills the columns in as git
answers. A merge row carries its first-parent diff, which is the change the review reads for
it, and no row carries the author: you are reading your own branch.

Some sets cannot be read. Taking a commit out can need a commit you are keeping — a formatter
run is the likeliest case of all, because it touched the same lines every other commit
touched. The plugin says so, names the commit and the files it collides in, and leaves the
list open with your cursor on the row. Nothing is stored, and the review behind it does not
move. Uncheck the commit it named as well, and the pick goes through.

A merge is the one case that is not about files. Unchecking a merge while a commit older
than it stays checked is refused with a sentence about merges, because everything that merge
brought is already outside your review: merging the default branch moves the merge base
forward. Unchecking the same merge with every commit older than it also unchecked is an
ordinary trim past the merge, and it is not refused at all.

Uncommitted and untracked work stay in the review under every trim. A branch review reads to
the working tree, and no trim reaches that end of it.

The plugin keeps the trim per branch, so the next session opens where your reading stopped.
Each branch keeps its own trim.

[What drops a trim, what survives one, and how the commit list is built](docs/rationale.md#trim)

### Review what the agent did

Reach for `since-batch` while an agent is working. A submit records a snapshot of the working
tree, and this scope diffs against that snapshot. You get the agent's response to your
review, without the work you already had in flight when you sent it.

`gs` reaches `since-batch` once a batch has gone from the repository, and never before. Ask
for it by name with nothing dispatched and the plugin says so in one sentence.

[How since-batch behaves in every other respect](docs/rationale.md#since-batch)

## Annotations

### Annotation types

A type is not decoration. It changes what the receiving agent is told to do with that group.

| Type | Glyph | Key | Group directive in the payload |
| --- | --- | --- | --- |
| bug | `✗` | `ab` | diagnose and fix these |
| fix | `✎` | `af` | apply these changes |
| suggestion | `✦` | `as` | evaluate; apply if sound |
| nitpick | `▫` | `an` | low priority — batch these together |
| issue | `⚑` | `ai` | do NOT fix — summarize these for tracking |

The glyph is what the picker offers each type with, and what a queued note carries in front
of its prose. It is also all an **archived** entry keeps: that entry gives up its type's
color on purpose, so the glyph is what still says what kind of finding it was. Plain
Unicode, one column wide — no patched font, here or anywhere else the plugin draws.

`aa` opens a picker instead. It offers each type as its glyph, its name, the key that
reaches it and its directive, so the menu teaches the keystroke that makes the menu
unnecessary:

```
✗  bug         ab  diagnose and fix these
✎  fix         af  apply these changes
✦  suggestion  as  evaluate; apply if sound
▫  nitpick     an  low priority — batch these together
⚑  issue       ai  do NOT fix — summarize these for tracking
•  no type
```

The rows are built from your own types, so a replaced set is offered with its own names and
its own keys, and a type with no directive is offered without one. The columns are measured
over your list, so a glyph or a name wider than the shipped ones widens its column rather than
pushing the rows out of line. None of this reaches the
agent: what a group is told to do is the directive itself, and the key and the glyph stay in
the picker.

The last entry is **`no type`**. An untyped annotation says that something is worth reading,
without saying what to do about it. It behaves like any other entry, and its group renders
last under a bare `## Untyped (n)` heading.

Declining a type is not dismissing. Press `<Esc>` to abandon the annotation.

<details>
<summary>Replacing the type set</summary>

`opts.types` replaces the whole set. Only `name` and `key` are required. The plugin derives
everything else, so a new type costs two fields:

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
| `label` | the name, title-cased and pluralized: `question` → `Questions` |
| `icon` | `icons.annotated` — an empty string counts as none and gets the same |
| `hl` | `CodeReview<Name>`, auto-linked to `DiagnosticInfo` so it has color |
| `directive` | none — the payload heading is then just `## Questions (3)`, and the picker's row for it stops at the key |

Order is the order the groups appear in the payload, most actionable first.

`setup()` rejects a list that cannot work, and names the entry that caused it. The causes are
a missing `name` or `key`, a duplicate of either, a `key` of `a` (which shadows the `aa`
picker), or a field of the wrong type. Start from the shipped set with
`require("codereview.types").defaults`.

</details>

### What you can annotate

| Cursor is on | What gets annotated |
| --- | --- |
| A diff line | That line |
| A visual selection | Those lines |
| A hunk header | The whole hunk |
| A file header | The whole file |
| A filler row (split layout) | The whole file |

You can also write a **bare note**, with no file behind it at all.

### Annotate from any buffer

Capture does not need a review. `:CodeReviewAnnotate bug` queues an annotation about the file
you are looking at. With no type it offers the same picker `aa` does.

```lua
require("codereview").annotate("bug")  -- the selection, or the whole file
require("codereview").annotate()       -- pick the type from a menu, or decline one
```

That is the entry point to bind a key to. Nothing needs to reach into the plugin's internal
modules to capture. Bind it in both modes, and the selection decides the scope:

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

The last two are not second-class. They queue, they submit, and they survive a restart like
anything else. A scratch buffer is a fine place to leave a thought for the batch.

What you get is an ordinary annotation. It shares the queue, the payload grouping, the batch
and the staleness rules with anything captured during a review. The plugin never touches the
buffer itself.

**Diagnostics ride along.** The plugin attaches errors and warnings that overlap what you
captured, so you stop retyping them by hand. It leaves out hints and info, which are rarely
why you are annotating and which bury the diagnostic that is.

```
why is this branch unreachable?

Diagnostics:
- ERROR L12 undefined global `foo` (lua_ls)
- WARN  L14 unused local `bar` (lua_ls)
```

### Send one annotation now

A thought you want acted on must not wait for a batch you have not finished assembling. The
same entry point sends one annotation on its own instead of queueing it:

```lua
require("codereview").annotate("bug", nil, { immediate = true })
require("codereview").annotate(nil, nil, { immediate = true })  -- or pick the type
```

Delivery is a property of the call, not a different door. You get the same paths, the same
blob, the same diagnostics, the same drafts, the same `@` references and the same picker.
What arrives is an ordinary review payload that holds one annotation
([ADR-0004](docs/adr/0004-an-immediate-send-is-a-batch-of-one.md)).

The plugin asks where it goes **before** the composer opens, so declining costs no typing.
The queue is untouched: an annotation sent this way never joins it, and whatever is already
queued is neither delivered nor cleared. If the send does not go through, the plugin keeps
the note as a draft and offers it back when you annotate that file again.

### The composer

You write notes in a real buffer, not a prompt. See [the composer keys](#in-the-composer)
above.

The plugin keeps drafts per target, and they survive restarts. `@` references another file,
and [`pick_file`](#adapters) supplies the picker.

## The queue and the batch

Annotations accumulate in a queue that survives `:qa` and restarts. `Q` opens a float that
lists the batch. Press `<CR>` to jump to any entry. The float closes, and the plugin centers
the line the annotation is about. If the file was collapsed, the plugin expands it first.

The queue is therefore a way of navigating a review, and not only of auditing it before you
send.

The queue is shared with the capture path, and the float opens with or without a review. Some
of what it lists therefore has nowhere to jump to:

- a bare note is about no file,
- no review is open, or
- the file sits outside the current scope.

Each entry says which.

**`gy` copies the batch without submitting it.** It works in the diff, in the float, and as
`:CodeReviewCopy` from anywhere. It puts the payload in the `+` register. This is the same
text `send` receives, target and all, and it costs the batch nothing. The queue is untouched,
so reading what an agent will be told is not a decision to send it.

### The preamble

`<C-s>` submits with no questions asked. `<C-a>` opens the composer first, and submits when
you submit the composer. It works in the diff and in the queue float.

What you write is the **preamble**: the prose above the batch, addressed to the agent, that is
not an annotation. It says what the batch is about as a whole — which part matters most, what
to ignore, and how the pieces relate. It replaces an untyped annotation in the middle of the
findings.

The payload draws the preamble above the header, so the agent reads it first.

[What a preamble is not, and what an abandoned composer keeps](docs/rationale.md#the-preamble)

### Read the last batch back

A submit clears the queue. That is the moment "what did I actually ask for?" stops having an
answer anywhere but the agent's transcript.

`:CodeReviewLastBatch` gives it one. It lists the annotations of the batch that went last,
grouped by type exactly as the queue float and the payload group them. It shows the
[preamble](#the-preamble) the batch went out under, the target it went to, and when it went.

`gb` opens that same float from inside a review, in the diff and in the tree. The command
needs no review open. A bare note is listed like anything else.

The float is **read-only**. [Why](docs/rationale.md#the-last-batch-float)

### What you already reported stays on the diff

A dispatched batch does not leave the review view. Its entries keep the anchors they were
bound to, and the plugin draws them dimmed beneath the code they were about. It projects them
exactly as it projects live annotations.

**`gA` shows or hides them** from inside a review, in the diff and in the tree. On a fresh
review over code you already annotated they are noise, so one key takes them off and the same
key brings them back. It repaints at once and runs in both directions. `archived = false`
turns them off in your configuration instead.

[Which scopes draw them, what `x` does there, and why `gA` overrides rather than writes](docs/rationale.md#archived-entries)

### Where the agent has and has not been

Each entry of the **last** batch says whether its file has changed since that batch was
dispatched. The entry reads `file changed` or `file unchanged`, and the winbar tallies the
files that have not changed:

```
 branch vs master · ✓2/7 · +40 -12 · ●1 · ↺2 · → janus
```

`↺2` is the answer to *did it ignore something*. It is exact on the case that matters: a file
the agent never opened. The comparison is **per file**, against the snapshot the batch went
out with. That is the same commit `since-batch` diffs against, so a file the tally calls
touched is exactly a file that scope shows you.

`CodeReviewTouched` and `CodeReviewUntouched` are the groups. `archived = false`, or `gA`
while you are reviewing, turns the tally off along with everything else.

[Why the word is "touched", what is left unjudged, and why the tally reads 0 in since-batch](docs/rationale.md#untouched-files)

### The payload

The payload groups annotations by type, in the configured order, most actionable first, with
anything untyped last. A diff is inlined where an `@ref` cannot carry the change. A preamble
sits above the header with a blank line under it. With no preamble the payload starts at the
header.

````markdown
the auth rewrite is the part to read — the route moves are mechanical

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

## Reading the diff

### Unified or split

`layout = "unified"` is the default. It stacks deleted and added lines in one column.
`layout = "split"` draws the same diff as two **panes**: the before-image on the left, and
the after-image on the right. Corresponding code sits on the same screen row.

```lua
opts = { layout = "split" }   -- "unified" (default) or "split". Validated at setup()
```

```
┌─ tree ───────────┐┌─ Before · origin/master ────┐┌─ branch · ✓2/7 ──────────────┐
│ ▾ apps       1/4 ││     apps/api/src/main.ts    ││ ● ▾ apps/api/src/main.ts +12 │
│   ▾ api/src  1/2 ││ @@ -19,6 @@                 ││ @@ +19,8 @@ function boot()  │
│     ● main.ts  3 ││  19 │  const app = express()││  19 │  const app = express() │
│   ▾ web/src  0/2 ││ ▌20 │ -const cfg = load()   ││ ▌20 │ +const cfg = loadCfg() │
│     ✓ index.ts   ││                             ││ ▌   │   ✗ why the rename?    │
│ ○ README.md      ││                             ││ ▌21 │ +cfg.validate()        │
│ 2/7 reviewed     ││  21 │  app.listen(cfg.port) ││  22 │  app.listen(cfg.port)  │
└──────────────────┘└─────────────────────────────┘└──────────────────────────────┘
```

The blank rows on the left are **filler**. The addition has no counterpart in the
before-image, so the left pane holds its place rather than letting the two panes drift apart.
Annotate from a filler row and the annotation targets the whole file.

Both panes are syntax-highlighted and they scroll together. Collapsing, reviewed marks,
capture and navigation all work the same way in each. The pane you are in decides what is
captured: a deleted line on the left, and the post-image line on the right.

**`gl` switches layouts** without losing your place, from either pane or from the file tree.
You can therefore reach for side-by-side on the one reformatted file, without editing your
configuration. The choice lasts the rest of the session, and it resets when Neovim exits.

### Long lines

A line wider than the pane runs off the right edge, and reading the end of it means scrolling
sideways — which moves every row at once, so you lose the line you were reading to reach the
end of it.

**`gw` folds it instead**, onto as many further rows as it needs. It works from the diff and
from the file tree, and pressing it again stops the folding.

```
▌ 42 │ +const url = buildEndpoint(config.host, config.port, "/api/v2/reviews", {
↳         retries: 3, timeout: 30_000 })
```

A continuation row is indented to the column the code starts at, and carries `↳` where the
change bar would be — neither the bar nor the line number repeats, because it is one line.
Nothing is added to the buffer: annotations, reviewed marks, counts and every navigation key
are exactly what they were.

It is off until you ask for it, and `wrap = true` has it on from the first review. The choice
`gw` makes lasts the rest of the session and is written nowhere — it says how wide *this*
terminal is, which is not something to restore into a different one tomorrow.

**A split layout never folds**, and `gw` says so rather than doing nothing: two panes that
fold by different amounts stop being row-aligned, and row alignment is what split is for.
`gl` back to unified folds again.

[Why unified only, and where the indent comes from](docs/rationale.md#wrap)

[What `gl` carries across, how the chrome splits, and the one behavior that differs](docs/rationale.md#the-split-layout)

### One file at a time

A review of thirty changed files is one continuous expanse, and nothing in it says where a
file ends. The tree, the sticky header and the fade each help; you can still lose track of
which file you are in.

**`go` draws one file** — the file you are reading — and none of the others. Press it again
and every file comes back. It works from the diff and from the tree, and it keeps the file
you are in either way, so narrowing and widening both leave you where you were rather than at
the top of the review.

You move through the review with the file keys you already have:

| Key | Where it goes |
| --- | --- |
| `]f` `[f` | The next and previous file |
| `]F` `[F` | The next and previous **unreviewed** file |
| `<C-p>` | Any file, by name |
| `<CR>` in the tree | The file on that row |

Each of them draws the file it names.

**`R` marks the file reviewed and takes you to the next unreviewed one**, because collapsing
the only file on screen would leave you a header row with nothing under it. On the last
unreviewed file it says the review is done and stays there. It is the one key whose meaning
solo changes. `]h` and `[h` stop at the drawn file's last and first hunk and say so rather
than repainting the whole view to reach another file's hunk, and `]a` and `[a` move between
that file's annotations.

The **tree** goes on listing every file with its reviewed marks and note counts, so you keep
the map of the review while reading one square of it, and the review summary counts the whole
scope — `✓2/7` does not become `✓0/1` because of how you are reading.

It works in both layouts: a soloed **split** draws the same one file in both panes, still
row-aligned. Every other view-wide key leaves it alone — `gl`, `gr`, `gs`, `gS`, `gp` and
`gA` each do their own job with one file still on screen, and `za` still collapses the file
you are reading down to its header.

It is off until you ask for it, and `solo = true` has it on from the first review. What `go`
says lasts the rest of the session and is written nowhere: a **scope** is kept per checkout
because it says what the review *is*, and how you read one afternoon is not something to
restore into a different one.

Your **queue**, the **archive** and what reaches the agent are untouched. An annotation
captured with one file on screen is byte-for-byte the annotation the same line produces with
all of them on screen — nothing about how you were reading is recorded or sent.

[Why one index space, and what moving between files costs](docs/rationale.md#solo)

### What changed inside a changed line

Rename one identifier in an eighty-column line. A plain diff then shows you two
eighty-column lines, one red and one green, with nothing pointing at the four characters that
differ.

So the plugin emphasizes the **spans** that actually differ inside the pair. The rest of the
line keeps its ordinary red or green, and you read the change instead of the line.

```
▌20 │ -const cfg = load()
▌20 │ +const cfg = loadConfig()
                       ▔▔▔▔▔▔ emphasized
```

Spans are on by default, in both layouts, and in both panes on the same row.

```lua
opts = { spans = false }   -- true by default. Validated at setup()
```

Granularity is characters, not words. An edit inside an identifier is therefore pointed at
precisely, and a re-indentation is visible rather than mysterious. Where two lines share so
little that emphasizing the change emphasizes nearly all of both, the plugin leaves them
plainly colored. That is a replacement, not an edit.

[Which lines pair, why the threshold is 60%, and when the work happens](docs/rationale.md#spans)

### The file tree

The tree collapses single-child directory chains, so you get `apps/api/src` and not three
nested rows. It sorts directories before files. It carries a reviewed tally on every
directory, so you can see which packages are done without opening them.

**The footer carries a progress bar** beside `N/M reviewed`, filled from those same two
numbers, so how far the review has got is something you see rather than a fraction you
convert. It draws in the footer's own colour and never in green — green already means a
finished directory in this tree. The bar is one length for the whole review: it is measured
against the widest tally the review can print, so it does not shrink by a column when the
reviewed count grows a digit. A review you have started fills at least one cell, and only a
finished review fills the last one. `icons.progress_full` and `icons.progress_empty` are the
two glyphs; replace both or neither, because the bar tells its two kinds of cell apart by
glyph and not by colour.

The tree follows the diff cursor, and `<Tab>` into it lands on the file you were reading.

A file row carries the reviewed, annotated or unreviewed mark first, then the glyph your
[`file_icon`](#adapters) adapter gave that file — the same glyph the diff and the sticky
header draw for it, decided by one rule so the three cannot disagree. **In the colour your
icon plugin chose for it**, on all three surfaces, when your adapter answers with a highlight
group beside the glyph, which `nvim-web-devicons` and `mini.icons` both do already. The mark
keeps its column and its own colour, the glyph comes out of the name's budget, and a narrow
panel cuts the name from the left, so the end of it survives.

A directory row carries a glyph of its own, from the [`dir_icon`](#adapters) adapter — a
second one, because a directory names no file and there is nothing `file_icon` could be asked
about it. It goes after the chevron, in your icon plugin's colour when your adapter names a
group, and a compacted row like `apps/api/src` is asked about `apps/api/src` and never about
`apps`, so the glyph and the name agree. The chevron keeps its column and the reviewed tally
keeps the right margin.

`gp` dismisses and summons the tree. `panel.enabled` decides whether a review *opens* with
one. Collapsed directories belong to the review rather than to the tree, so they are exactly
as you left them when the tree comes back.

### Focus and fade

A review can hold three windows at once: the before pane, the after pane and the tree.

**The pane without focus is muted.** Its colors are pulled toward the background, so where
you are is on screen instead of something you press a key to find out. The muted pane lights
the row opposite your cursor, in a group of its own. That is the **counterpart row**.

**Every file except the one you are in is faded.** The colors of its rows are pulled toward
the background, so the file you are reading has a boundary. Cross into another file and the
fade follows the cursor. The unit is the file, so moving between hunks changes nothing.

**The file tree is never muted.** It draws in your colorscheme's own colors under every
focus. Move into it and the panes mute, so you can see that your keys now act on the tree.

The colors come from your own colorscheme, blended. Nothing here has a palette of its own.

```lua
opts = {
  muted       = { enabled = true, strength = 0.5 },
  faded       = { enabled = true, strength = 0.35 },
  counterpart = { enabled = true, strength = 0.25 },
}
```

Set `enabled = false` on any of the three to turn it off. Each `strength` is one number from
0 to 1, saying how far toward the background a color goes.

[What the counterpart row is for, why the tree is exempt, and how the three differ](docs/rationale.md#focus-and-fade)

### A file's path

A file's header row draws the directories above the file quietly and the file's own name
brightly. The split is at the last separator, so the part every file in a directory shares
stops competing with the part that says which file this is. A file at the repository root
draws its name with nothing quiet in front of it.

A renamed file gets the rule on both of its paths, and the arrow between them is drawn as
punctuation. In the split layout each **pane** styles the path it names, so the old name is
styled on the side that holds it.

The **sticky header** below draws a path the same way, because one function answers what a
file is called. On a narrow pane the path is cut from the left and keeps the bright name.

`CodeReviewFileDir` and `CodeReviewFileName` are the groups, linked into your colorscheme
like every other.

### The sticky header

A file's header row scrolls off the top as soon as you read past the first screenful. The
**sticky header** keeps it on the winbar:

```
 ○ ▾ src/routes.lua  +12 -3  [2 notes]        branch vs master · ✓2/7 · +40 -9 · ●2 · → janus
```

It carries the same icon, chevron, path, `+N -M` and annotation count that the in-buffer
header carries — the path styled the same way, by the same rule, and the same glyph in the
same colour if you wired [`file_icon`](#adapters) — with the review summary right-aligned
beside it. It names the file the **cursor** is in, which is the file an annotation attaches
to.

It works with the tree dismissed, and with a review opened without one.

[Why glyphs, how the colors work, and what gives way on a narrow pane](docs/rationale.md#the-sticky-header)

## Configuration

```lua
opts = {
  context = 3,                     -- git diff -U
  untracked = true,                -- show untracked files in branch/worktree scopes
  syntax = true,                   -- treesitter highlighting
  max_syntax_bytes = 256 * 1024,   -- skip syntax above this size
  layout = "unified",              -- "unified" or "split". Validated at setup
  spans = true,                    -- emphasize what changed inside a changed line
  wrap = false,                    -- fold a line too wide for its window onto further rows.
                                   -- Unified only: a split layout stays row-aligned
  solo = false,                    -- draw one file at a time -- the file being read -- and
                                   -- move between files with `]f` `[f` `]F` `[F` `<C-p>`.
                                   -- `go` overrides this for the rest of the session
  archived = true,                 -- draw already-dispatched entries on the diff, dimmed,
                                   -- and tally the untouched ones on the winbar. `gA`
                                   -- overrides this for the rest of the session
  muted = { enabled = true,        -- mute the pane without focus, never the tree
            --                       a host's filetype glyph recedes with it
            strength = 0.5 },      -- how far its colors are pulled toward the background
  faded = { enabled = true,        -- fade every file except the one the cursor is in
            strength = 0.35 },     -- its own number: this covers every file but one
  counterpart = { enabled = true,  -- light the row opposite the cursor in a muted pane
                  strength = 0.25 }, -- gentler than the muting, so the row stays findable
  panel = { enabled = true, width = 34, position = "left" },
  icons = { reviewed = "✓", annotated = "●", unreviewed = "○",
            collapsed = "▸", expanded = "▾", change_bar = "▌",
            untouched = "↺", continuation = "↳",
            progress_full = "█", progress_empty = "░" },
                                   -- plain Unicode throughout: no Nerd Font anywhere.
                                   -- For a per-filetype icon beside these, wire the
                                   -- `file_icon` adapter, and `dir_icon` for a
                                   -- directory's own -- see Adapters
  types = nil,                     -- defaults to the five above. See Annotation types
}
```

Every highlight is a `default = true` link to a group your colorscheme already defines, so
overriding any `CodeReview*` group works. Three families of groups are computed rather than
linked, and none is yours to set.
[The full rules](docs/rationale.md#highlight-groups)

## Adapters

The plugin has no opinion about where a review goes, about which pickers you use, about
which diff tool you read a rewrite in, or about which icon a file or a directory deserves.
Eight optional functions inject that. **None are required.**

| Adapter | What it supplies | Without it |
| --- | --- | --- |
| `send` | Delivers the rendered batch | The payload goes to the `+` register |
| `pick_target` | Chooses a delivery target | No target. `send` decides what that means |
| `pick_file` | Picks a file for `@` in the composer | `@` stays a literal `@`, and says so |
| `compose` | Collects note text | The composer the plugin ships |
| `open_diff` | Reads one file in your own diff tool | `gd` is not bound at all |
| `pick_checkout` | Chooses which checkout to switch to | The picker the plugin ships |
| `file_icon` | Gives a file the icon its filetype has in your config, on the diff, the sticky header and the file tree — in your icon plugin's own colour on all three | No filetype icon. Nothing is called per file |
| `dir_icon` | Gives a directory its own icon, in its own colour, on its row in the file tree | No directory icon. Nothing is called per directory |

```lua
opts = {
  send = function(payload, target) return true end,
  pick_target = function(cb) cb({ short = "agent", cwd = "/path" }) end,
  pick_file = function(cb) cb({ path = "src/main.lua", first = 12, last = 20 }) end,
  compose = function(ctx, on_accept, label) on_accept(nil, "text") end,
  open_diff = function(spec) end,  -- spec: { path, before, after, line }
  pick_checkout = function(checkouts, cb) cb(checkouts[1].path) end,
  file_icon = function(path) return require("nvim-web-devicons").get_icon(path) end,  -- glyph, group
  dir_icon = function(path) return MiniIcons.get("directory", vim.fs.basename(path)) end,
}
```

[Why a send reports dispatch and not arrival, and why you cannot annotate inside `open_diff`](docs/rationale.md#adapters)

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
  -- register, which is the default implementation of this same contract -- it reports a
  -- non-dispatch (a register is not a consumer), which is why an unwired host keeps its
  -- queue, and it is a warning rather than an error because nothing is broken. `gy` puts
  -- the payload in that register deliberately, whatever is wired here, so what an adapter
  -- receives is readable without submitting to find out.
  send = function(payload, target) return true end,

  -- Choose a delivery target. Call back with anything carrying `short` and `cwd`.
  -- `cwd` matters: refs are re-resolved against it at submit time.
  pick_target = function(cb) cb({ short = "agent", cwd = "/path" }) end,

  -- Choose a file to reference from `@` inside the composer. The plugin ships no picker,
  -- so without this `@` stays a literal `@` and says so. `first`/`last` are optional --
  -- omit them and the reference is to the file rather than to a range in it.
  pick_file = function(cb) cb({ path = "src/main.lua", first = 12, last = 20 }) end,

  -- Collect note text. Without it you get the composer the plugin ships, which implements
  -- this same contract -- wiring one replaces that composer rather than upgrading a prompt.
  -- `ctx` describes what is being annotated: `scope`, `label`, `rel_path`, `file_path`,
  -- and `origin_win` -- the window the annotation was started from. Focus goes back there
  -- once `on_accept` runs. A composer the user can *cancel* never calls it, so that path
  -- is the composer's to restore.
  --
  -- On an immediate send `ctx.routing` is also there -- `{ label(), pick(on_done) }` for
  -- the target *this note* will reach. Name it, and change it with `pick`. It is absent
  -- for a note joining the queue, which the batch routes.
  compose = function(ctx, on_accept, label) on_accept(nil, "text") end,

  -- Read one file in the diff tool you already have -- DiffviewOpen, :Gdiffsplit, your own
  -- diffthis pair. The plugin ships none of that: it hands over the file and the two refs
  -- its scope is between and stops caring. `path` is absolute and is the post-image path,
  -- so for a rename the pre-image lives elsewhere in `before`. `after` is nil whenever the
  -- post-image is the working tree -- that is most scopes, and it is not an error: nil
  -- means the file on disk. `line` is nil when the file was named from the file tree,
  -- which knows a file and no position in it.
  open_diff = function(spec)
    local rev = spec.after and (spec.before .. ".." .. spec.after) or spec.before
    vim.cmd(("DiffviewOpen %s -- %s"):format(rev, vim.fn.fnameescape(spec.path)))
  end,

  -- Choose which checkout `:CodeReviewSwitch` moves the review to. Without it you get the
  -- picker the plugin ships, which implements this same contract -- wiring one replaces
  -- that picker rather than upgrading a lesser one. `checkouts` is every checkout of the
  -- current repository the plugin can open: each carries `path` (absolute and resolved),
  -- `branch` (nil when detached) and `current`. Bare repositories and checkouts whose
  -- directory is gone are already out of it.
  --
  -- Answer with a *path*, not with a row. The list is a convenience, not a restriction: an
  -- adapter is free to offer a checkout that was never in it, which is what reviewing a
  -- checkout of a different repository needs. Call back with nil for "none of them", which
  -- is not an error and is not reported.
  pick_checkout = function(checkouts, cb)
    vim.ui.select(checkouts, {
      prompt = "Switch the review to:",
      format_item = function(c) return c.branch or c.path end,
    }, function(chosen) cb(chosen and chosen.path) end)
  end,

  -- Give a file the icon its filetype has in your config, drawn on every surface that
  -- names it: its header row, the sticky header, and its row in the file tree. The plugin
  -- ships no filetype glyphs and depends on no icon plugin, so without this a file simply
  -- has none -- and nothing is called per file, because there is no shipped glyph behind
  -- this to reach through a function.
  --
  -- `path` is repository-relative and is the post-image path, which is the name all three
  -- surfaces draw. Answer with one glyph, or with nil for a file you have no icon for. One
  -- rule decides what your answer becomes, so a file cannot carry one glyph on the diff and
  -- another in the tree.
  --
  -- It is a second thing about the file and never a replacement for the first: the
  -- reviewed, annotated and unreviewed marks keep their column and their meaning.
  --
  -- Answer with the highlight group beside the glyph and the glyph keeps its own colour;
  -- both icon plugins hand you that pair already, so passing their answer straight through
  -- is the whole of it. A group your theme does not define costs the glyph its colour and
  -- never its glyph, one Neovim would refuse as a group name is dropped the same way -- as is
  -- an empty string, which Neovim would take and discard and this plugin refuses on its own
  -- account -- and a glyph alone is a complete answer.
  --
  -- Called once per file per paint by the diff and by the tree, and the tree is rebuilt on
  -- every file crossing too -- so an adapter that raises, or that answers with anything but
  -- a string, is survived rather than reported: that file draws without a glyph and the
  -- review goes on.
  file_icon = function(path)
    return require("nvim-web-devicons").get_icon(path, nil, { default = true })
  end,

  -- The glyph a **directory** carries on its row in the file tree, and the group that
  -- colours it. The same contract as `file_icon` and the same rule reads your answer, so a
  -- glyph alone is complete and a group your theme does not define costs a colour rather
  -- than a glyph.
  --
  -- A second adapter rather than a wider first one: a directory names no file, so there is
  -- nothing `file_icon` could be asked about it. You wire one function per kind of thing and
  -- neither has to guess which kind it was handed -- this one is never asked about a file,
  -- and `file_icon` is never asked about a directory.
  --
  -- You are handed the row's own path. The tree compacts a chain of single-child
  -- directories onto one row, so a row reading `apps/api/src` hands you `apps/api/src` and
  -- never `apps`.
  --
  -- Called once per *drawn* directory row per paint -- a collapsed directory hides its
  -- children, so they are not asked about -- and the tree is rebuilt on every file crossing
  -- too, so an adapter that raises is survived rather than reported.
  dir_icon = function(path)
    return MiniIcons.get("directory", vim.fs.basename(path))
  end,
}
```

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
decides whether refs survive. [`docs/herdr.md`](docs/herdr.md) explains why, and spells out
which queue is which.

</details>

## Persistence

The plugin stores reviewed marks, the queue and the batches already dispatched per
**checkout** — the main clone and each worktree of a repository keep their own, and share
none of it — under `stdpath("state")/codereview/`. It keys them by scope and diff base, and
they survive a restart. Each entry records the git blob it was captured against.

On reload:

- A **reviewed mark** whose blob moved is silently un-marked. The file changed, so you have
  not reviewed what is there now.
- An **annotation** whose blob moved is kept and flagged `⚠ stale`. The prose is still worth
  sending, and only its line anchor is untrustworthy. A stale entry never travels as an
  `@ref`, and the plugin inlines its code instead.

Two things deliberately do **not** persist: the delivery target, and the layout `gl` last
chose. Both last for the session and no longer.

[Where a bare note lives, what a dispatched batch leaves behind, and what staleness is judged against](docs/rationale.md#persistence)

## Documentation

| Where | What is in it |
| --- | --- |
| `:help codereview` | The full reference — every command, mapping, option and Lua API |
| [`docs/rationale.md`](docs/rationale.md) | Why the behavior is what it is |
| [`docs/adr/`](docs/adr/) | The decisions behind the architecture, and why |
| [`CONTEXT.md`](CONTEXT.md) | The project's vocabulary — *scope*, *pane*, *filler*, *dispatch*, … |
| [`docs/design-notes.md`](docs/design-notes.md) | Every non-obvious constraint that cost real debugging time |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Setup, tests, the commit convention, PR shape |

## Development

```sh
make deps    # clone plenary into .tests/
make all     # lint and the whole suite, ~5s. Run this before every commit
make test    # the suite alone: one Neovim per spec file
make lint    # stylua --check
make perf    # the timing report. Never part of `make test`
```

Tests are plenary/busted specs under `tests/codereview/`, and each one builds its own
throwaway git fixture. CI runs them on Neovim stable and nightly, with plenary as the only
dependency. There is no nvim-treesitter and no compiler, because the fixtures are Lua and
Markdown and those parsers ship with Neovim.

See [`tests/README.md`](tests/README.md) for the layout, what is deliberately not covered,
and the traps worth knowing before you change a fixture.

`make perf` is a report you read, not a gate: it opens a review on three generated
repositories — 60 files, 300 files, and 300 files of two changed lines each — and prints what
opening, scrolling, a keystroke and a repaint cost on each. Only the 60-file open is
budgeted, because wall-clock numbers belong to the machine that produced them. The third tier
is a different *shape* rather than a smaller size: it is the one where a file is twenty rows
instead of three hundred, so a screenful holds a dozen files, which is the only place work
done per file can be told apart from work done for every file in view at once.

## Contributing

Issues and pull requests are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md). Setup
is `make hooks && make deps && make all`, and it takes about five seconds to know whether the
suite is green.

Open an issue first for anything with a design decision behind it. Typo fixes and
obviously-correct one-liners can go straight to a PR. Participation is under the
[Code of Conduct](CODE_OF_CONDUCT.md). Security reports go through
[`SECURITY.md`](SECURITY.md), and not through the issue tracker.

### Built with Claude Code

This plugin was written with [Claude Code](https://claude.com/claude-code), and it is set up
so that anyone can keep working on it that way. We say this plainly for two reasons. The
first is so that you know what you are reading. The second is so that you know that
agent-assisted contributions are welcome here, rather than merely tolerated.

The repo carries what an agent needs to be useful in it rather than merely fast.
[`CLAUDE.md`](CLAUDE.md) holds the workflow in imperative form. [`docs/agents/`](docs/agents/)
records where issues live and how they are labeled. [`docs/design-notes.md`](docs/design-notes.md)
exists because several obvious-looking approaches here are wrong, for reasons that no amount
of reading the code reveals. Point an agent at `CLAUDE.md` and it follows the same branch,
commit and PR conventions a human contributor does.

The bar is the same either way: the tests pass, the design notes were read, and you can
answer questions about the change in review. There is no requirement to disclose tool use,
and no penalty for it.

## License

[MIT](LICENSE) © Felipe Valencia
