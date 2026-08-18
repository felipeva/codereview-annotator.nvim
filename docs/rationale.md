# Rationale

Why the behavior is what it is.

The [README](../README.md) says what the plugin does. This file says why, for the choices
that are not obvious from the behavior alone. Several of them look arbitrary until you read
the reason. `:help codereview` is the full reference for every command, mapping and option.

Three other documents cover different ground. [`CONTEXT.md`](../CONTEXT.md) holds the
vocabulary. [`docs/adr/`](adr/) holds the architectural decisions. [`docs/design-notes.md`](design-notes.md)
holds the constraints that cost real debugging time, and it is written for contributors.

---

## Trim

**A trim is checked before it is used.** A rebase, an amend or a force-push leaves a trim
that names a commit the branch no longer holds. The plugin then drops the trim, opens the
full branch, and says in one sentence that the trim was lost.

**Reviewed marks survive a trim.** A file that the dropped commits never changed keeps its
mark. A file that moved since you marked it loses the mark, whether you trimmed or not. The
mark is judged against the git blob, and a trim does not change any blob.

**A detached `HEAD` has no branch name to key the trim under.** The trim works for the
session, and one message says that the plugin does not keep it.

**A trim is a modifier on the branch scope, not a scope of its own.** A sixth scope must
answer what it means with no commit picked. `gs` is a key you hold down, and it must
not get a new stop.

**The word is subtractive**, because that is what the reviewer does. They remove commits
from a whole that is there by default. "Trimmed to four commits" and "reset the trim" both
read correctly, and the verb and the noun are one word.

**The commit list is `--first-parent` from the merge base.** A merge is one row, and the
commits that arrived through it are not listed beside your own. There is no limit on the
rows, so a long branch keeps its oldest commits at the bottom of the list.

The list does not show the author, because it is your own branch.

**Every row shows the size of its commit**: the files it touched, and the lines it added and
deleted. A box on every row asks *is this one worth reading*, and a subject cannot answer
that — a formatter run over three hundred files and a one-line fix read alike. Those counts
do cost a second pass over the whole branch, which is why the list never waits for them: it
opens on the commits and fills the columns in when git answers. A merge row reports its
first-parent diff, which is the one change the review reads for it.

**Every row carries a box, and no row carries a mark.** What is in the review is stated on
each row rather than inferred from one mark on one row, because a set with a hole in it is a
set no single mark can state. The box column takes its columns from the subject, and from
neither the sha nor the date: a cut sha is a sha you cannot match against `git log`.

**The row that takes the whole branch in or out sits above the commits.** It is the state a
review opens in, and widening a narrowed review back out must not cost a walk to the bottom
of a long branch. It works both ways from that one row: checked is the whole branch, and
unchecked is a review of your uncommitted work alone.

**A pick that cannot be built is refused while the list is still open.** That is the one
moment the refusal is worth anything, because unchecking the commit it named is your next
keystroke. Nothing is stored, so a refused pick leaves the review reading exactly what it
was reading.

**Two cases open nothing, and say why in one sentence.** The first is `gc` outside a branch
review, where there is no branch behind the diff to list. The second is `gc` on a branch
whose `HEAD` is the merge base, which has no commits of its own.

A third case opens and works. On a detached `HEAD` the list is there and the trim applies,
and one message says that the plugin does not keep the trim.

---

## since-batch

`since-batch` is the one scope to reach for while an agent is working. It diffs against the
snapshot the last batch went out with.

It behaves like every other scope in every other respect. It is highlighted, navigable,
collapsible and annotatable, and it draws in both layouts.

`gs` reaches it only after a batch has gone from the repository. Before that there is
nothing to diff against.

---

## The split layout

**Buffer rows mean nothing across layouts.** The same line of the same hunk sits at a
different row in each layout. What `gl` carries across is the anchor: the same line, of the
same hunk, of the same file. The plugin finds the row that carries the anchor afterwards.

The cursor lands in the pane its line belongs to, so switching back is unambiguous. A cursor
on a filler row falls back to that file's header. The plugin centers the landing line,
because an exact scroll offset across a structural move preserves nothing meaningful.

**Chrome is split too.** A hunk header shows its pre-image range on the left. It shows its
post-image range plus git's section heading on the right. A renamed file shows its old path
on the left and its new path on the right. This holds on the winbar as well as in the buffer,
so the left pane's sticky header names the pre-image path beside the revision it draws.

**Horizontal scrolling is not synchronized.** Synchronizing it means changing `scrollopt`, a
global option this plugin does not own.

**One behavior differs between the layouts, and only one.** A visual range cannot span both
images, because the two runs live in different windows and cannot be in one selection.
Pure-addition and pure-deletion ranges work. Annotating the hunk header captures both images
inlined, so what a split range cannot express is still one keystroke away.

A layout is a rendering choice and nothing else. Which layout was on screen never reaches the
receiving agent ([ADR-0002](adr/0002-one-queue-one-entry-shape.md)).

---

## Spans

**Which lines pair.** The i-th deletion of a contiguous run pairs with the i-th addition of
the run that follows it. This is the pairing the split layout already uses to put a deletion
and its replacement on one row. Both layouts use it, which is why the same characters are
emphasized either side of a `gl`.

Where the runs are unequal, the surplus lines carry no emphasis. Neither does a pure
addition, a pure deletion, or a file that exists on only one side. There is nothing to
compare them against.

**When it says nothing.** Above 60% of the longer line inside spans, the plugin leaves the
pair alone. That is a replacement, not an edit.

The figure was read off real diffs rather than derived. At 70%, a quarter of the unrelated
pairs inside a long run were still emphasized. Every genuine one-line edit above 60% turned
out to be a replacement wearing an edit's clothes. A re-indentation is nowhere near the
threshold: every reformatted pair measured came in under 10%.

**When the work happens.** At parse time, once per git read. It never happens during a
repaint. On a 12,000-line diff the spans cost about as much again as a whole repaint. A
repaint runs on every resize, expansion, reviewed toggle and scope change. `make perf`
reports the figure on its own line, so a change that moves the work back into the repaint is
visible.

**Two highlight groups**, `CodeReviewAddSpan` and `CodeReviewDelSpan`, both take `DiffText`'s
background and nothing else. A foreground there sits beneath the treesitter replay. It loses
wherever a parser painted and wins wherever one did not, which is emphasis that changes color
with the languages you have installed.

The emphasis is a rendering refinement and nothing else. What you capture, what reaches the
queue and what the payload says are all untouched
([ADR-0002](adr/0002-one-queue-one-entry-shape.md)).

---

## Focus and fade

Three mechanisms pull colors toward the background. They are separate on purpose, and
[`CONTEXT.md`](../CONTEXT.md) keeps their names apart.

### Muting

**A muted pane still lights the row its cursor is on.** The muted pane lights a counterpart
row: the same row, in a group of its own, blended more gently than the muting. It is bright
enough to find and it never competes with the pane you are in.

The panes are cursorbound, so the counterpart row sits opposite the line you are reading. On
a pure addition it is the filler. A lit blank row says that nothing was here before. That is
the fact you wanted, and the one you cannot otherwise get without counting rows.

**The file tree is never muted.** It is the map of the review: the paths, the icons, the
per-directory tallies and the `+N -M` counts. It draws in your colorscheme's own colors under
every focus. Move into the tree and the panes mute instead, so you can see that your keys now
act on the tree.

**A float changes nothing.** The bright window is the review window you were last in, not the
window that holds the cursor. This covers the composer, the queue float and the last-batch
float.

### Fading

**The unit is the file, never the hunk.** Move from one hunk to the next inside one file and
nothing changes on screen.

**A faded file keeps its header row bright**, with its path, its `+N -M` and its annotation
count. The review then reads as bright headers over quiet bodies, with one file at full
strength. Its hunk headers fade with its body.

**A faded file keeps its syntax structure** rather than flattening to one tone. What changes
is which group each mark carries. The order the marks are drawn in never changes.

The fade is drawn by changing which group a mark carries, never by a foreground laid over the
file. A foreground above the syntax replay wins where a parser painted and loses where none
did.

`faded.strength` is gentler than `muted.strength` by default, because fading covers every
file but one.

---

## The sticky header

**It names the file the cursor is in**, not the file at the top of the window. That is the
file an annotation attaches to, which is what you reach for when you annotate twenty lines
into a hunk.

**The summary counts in glyphs rather than words** — `✓2/7` reviewed, `●2` annotations, `↺2`
untouched. Three numbers side by side then cannot be read as one another. Every glyph comes
from the `icons` table, so you can change any of them. Every glyph is plain Unicode, so
nothing here needs a Nerd Font.

The bar does not name the review itself. A bar inside a review does not need to.

**It is colored.** Added counts are green and removed counts are red. The annotation count
takes the color that annotations carry everywhere else. The delivery target is accented. The
separators are quieter than the facts between them. The path is the brightest thing on the
left, which is the thing you scrolled there to keep.

The groups are the plugin's own: `CodeReviewBarIcon`, `CodeReviewBarSep`,
`CodeReviewBarTarget` and `CodeReviewBarRev`, beside the stat and annotation-count groups the
diff already uses. Every one is a `default = true` link into your colorscheme. A theme you
have never used supplies the colors, and a theme change mid-review follows.

**In the split layout each pane names its own side**, so a rename reads correctly on the side
that holds the old name. The unified layout spells it `old → new`, exactly as the file header
does.

**On a pane too narrow for both halves the summary gives way first**. It starts with what the file
beside it now says twice. The path keeps its tail.

The before pane's bar names the base revision, and it never gives that up for the path. Half
a revision is worse than none of a path that the other pane names anyway.

The bar is chrome of the review window it sits on, so it mutes with that window.

---

## The preamble

**A preamble is never queued.** You write it at the moment the batch goes, and the plugin
forgets it afterwards. The queue holds annotations and nothing else.

**An abandoned composer sends nothing.** The queue is whole and nothing is archived. What you
wrote is kept as a draft, so the next `<C-a>` offers it back rather than making you write it
twice.

**That draft is kept per repository**, not per file, because a preamble is about a batch and
not about a line of code.

**An empty composer still submits** and draws nothing at all. The payload is then exactly
what `<C-s>` sends.

**`gy` copies no preamble**, because copying is not submitting. An
[immediate send](../README.md#send-one-annotation-now) carries none either: a batch of one
has no batch to cover ([ADR-0004](adr/0004-an-immediate-send-is-a-batch-of-one.md)).

**A preamble that went is part of the record.** The plugin keeps it with its batch and reads
it back with it. A float that listed the findings and not the covering note describes a
message nobody received.

---

## The last-batch float

**It is read-only, and that is a statement about the record rather than a feature left out.**
An archived entry says that something happened. A surface that let you drop, edit or resubmit
one claims that the plugin can revise what an agent already received. To raise a point again,
annotate again. That is an ordinary capture, and it joins the next batch.

`x` and `<C-s>` are bound only to say why they do nothing here. They are bound rather than
left off, so that the queue float's muscle memory gets a sentence instead of `E21`. Nothing
else is bound: the batch has gone, and there is nothing left to route, drop or send.

---

## Archived entries

**They draw in every scope**, not only `since-batch`. Knowing what you already said is worth
as much wherever you are.

**Consider a reviewer who continues while the agent works.** Without archived entries, that
reviewer reads a diff with no memory of what it already sent. They report the same finding
twice.

An anchor that carries both a queued and an archived entry draws both, the queued one first.
What is still to send outranks what has already gone. `x` there drops the queued entry and
never the archived one. Nothing on the diff can revise a batch that already went, for the
same reason the last-batch float is read-only.

**`gA` overrides the configured value instead of writing it**, so your `setup()` call goes on
saying what you wrote. The override holds for every review you open afterwards, so you press
the key once and not once per review. It dies with the Neovim process, so a display
preference never becomes durable state you forgot you set.

Off is off entirely, exactly as the flag is. The `untouched` tally leaves the winbar with the
entries, and no git is spent judging them.

`CodeReviewArchived` colors the marker and `CodeReviewArchivedNote` colors the prose. Both are
`default = true` links, so a colorscheme can say how dim "already sent" looks.

---

## Untouched files

**The word is *touched*, not *addressed*.** The plugin knows that the file moved. It does not
know that anyone read your annotation, agreed with it, or acted on it, and it will not imply
otherwise.

**Touched is not staleness.** Staleness is the same kind of comparison against a different
blob. It is about entries still in the queue, and it means *this annotation can now be wrong*
rather than *something happened here*. The two are never merged, and an archived entry never
shows a stale flag.

**Three things are left unjudged rather than guessed at:**

- a file the current scope does not cover,
- a file that was untracked when the batch went, because a snapshot does not record those,
- a bare note, which is about no file at all.

A file deleted since the dispatch counts as touched. Nothing judged means no segment at all,
rather than a zero to misread.

**The tally reads `0 untouched` inside `since-batch`.** That scope shows you exactly the files
that moved, so every entry it covers is touched by definition. The files you are looking for
are the ones it is not showing. `branch` and `worktree` are where the number earns its keep.

---

## Highlight groups

Every highlight is a `default = true` link to a group your colorscheme already defines, such
as `DiffAdd`, `Added` or `DiagnosticError`. Overriding any `CodeReview*` group works without
the plugin fighting back.

`CodeReviewAddSpan` and `CodeReviewDelSpan` are the two exceptions. They take `DiffText`'s
background and set no foreground. They are still `default = true`, so overriding them works
the same way.

**Three families of groups are computed rather than linked, and none is yours to set.**

| Family | Name | Strength |
| --- | --- | --- |
| Muted pane | `CodeReviewMuted.` plus the group it blends | `muted.strength` |
| Faded file | `CodeReviewFaded.` plus the group it blends | `faded.strength` |
| Counterpart row | `CodeReviewCounterpart.CursorLine`, one member only | `counterpart.strength` |

Each holds that group's own colors pulled that far toward the background. Examples are
`CodeReviewMuted.CodeReviewAdd` and `CodeReviewMuted.@keyword`. The plugin writes each family
again on every colorscheme change, so a group you set yourself is overwritten. Set the
strength, or set the group the twin is named for.

**A group your theme gives no color of its own gets no twin in any of the three families.**
The plugin draws it at full brightness. Muted, faded or lit, that is the same rule. An
unfamiliar theme therefore degrades to *less muted*, and never to *wrong*.

---

## Persistence

### Annotations with no repository behind them

A bare note, or a file outside any checkout, has nowhere repository-shaped to live. It goes
to a single global store beside the others.

Nothing ever reconciles that store against a diff, so nothing ever clears it. The plugin
drops entries older than seven days when it reads the store. That bounds the growth of the
store but not its staleness, which is the accepted cost of not making those annotations
second-class.

### What a dispatched batch leaves behind

A dispatched batch is kept rather than forgotten. The plugin records five things:

- the annotations as they went,
- the preamble they went out under,
- where they went,
- when they went,
- a snapshot of the working tree at that moment.

The snapshot is a commit object minted with `git stash create`. It moves no ref, it leaves the
index alone, and it never touches your files. On a clean tree there is nothing to record that
`HEAD` does not already say, so `HEAD` is what the plugin stores.

**A dispatch writes the archive and nothing else does.** Four things leave the archive
exactly as they leave the queue:

- an adapter that declined,
- an adapter that raised,
- the `+` register the default send copies to,
- the register `gy` copies to.

A payload that sits in a register is not something an agent received.

An immediate send is a batch of one, and the plugin keeps it as one. The most recent twenty
batches are kept per store, and the oldest is dropped on write.

A batch that holds both kinds of annotation is written to both stores. The plugin rejoins the
two halves by the moment they were dispatched. That stops a bare note being the one thing
missing from what you read back.

Both halves carry the same preamble, for the reason they carry the same stamp and the same
target. A preamble belongs to the dispatch, and not to either half of it. A record written before
batches carried a preamble lacks the field and reads back with none. A record written
before the archive existed lacks the archive.

### What staleness is judged against

Each kind of annotation is judged against whatever its blob was taken from.

A review annotation is judged against the diff on screen. A file the current scope does not
include is not evidence that anything changed, so the plugin leaves it alone.

An annotation captured from a buffer has no scope behind it. The plugin judges it against the
file on disk, at any scope and with no review open.

That distinction matters in a `staged` review. There the diff shows the index and a buffer
capture holds the working tree. Judging one by the other flags an annotation about a file
nobody has touched.

### What does not persist

Two things deliberately do not persist. The delivery target names a live destination that a
restart makes dead. The layout `gl` last chose is a preference rather than review progress.
The store is per repository and neither of those is. Both last for the session and no longer.

---

## Adapters

[ADR-0005](adr/0005-a-send-reports-dispatch-not-arrival.md) records why "dispatched" is the
narrow promise. The adapter most hosts wire is asynchronous. Holding the queue until an agent
confirmed keeps a sent batch queued for the length of that agent's work.

**You cannot annotate in whatever `open_diff` opens.** Nothing there has an anchor map, so it
is a one-way trip. Read the file closely, then come back to the review to say anything about
it.

`open_diff` is for the rewrite that Neovim's own diff mode reads better than a unified diff
does. Examples are a reformat, a re-indent, and a file moved wholesale. It is not a second
review surface.

`gd` is bound only while `open_diff` is wired, in the diff and in the tree. A key that
silently did nothing is worse than no key.

---

## Annotation keys

Annotation keys carry an `a` prefix rather than being bound bare. Bare `b`, `f`, `n` and `s`
shadow back-word, find-char, next-search and flash.nvim inside the buffer. `a` is append,
which is dead in a `nomodifiable` buffer, so the prefix costs a keystroke and no motion.

`]F` is the motion that matters once a review is underway. The point of marking files
reviewed is to stop looking at them. The useful motion is "the next thing I have not done",
not "the next file", which walks back through everything already finished.

Pluralization of a type's label is naive: the plugin adds `s` unless the name already ends in
one. A name that English declines irregularly wants an explicit `label`.
