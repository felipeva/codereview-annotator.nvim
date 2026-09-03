# Code Review Annotator

Reviewing a diff inside Neovim and handing the result to a coding agent as one message.
The plugin owns capture, the queue and the rendered message; it owns nothing about who
receives it.

## Language

### Reviewing

**Checkout**:
One working directory of a repository — the main clone or any git worktree of it. It is the
unit everything is scoped to: a **queue**, an **archive**, the **trims** and the reviewed
marks belong to one checkout, and two checkouts of one repository share none of them.
_Avoid_: session (a session is an agent's, see **Target**), worktree (a **scope** name),
repository, root, project

**Switch**:
Move the review from one **checkout** to another, in place. Said of checkouts only — changing
what a review covers is a change of **scope** and is never a switch.
_Avoid_: jump, cd, change directory, move, retarget

**Orphaned**:
Said of a **checkout** whose stored review state is still on disk after its directory is gone,
so nothing can reach the queue, archive or marks inside it. Removed by a *sweep*, which is
the plugin's word for discarding aged stored state — not git's *prune*.
_Avoid_: stale (an annotation's line anchors, see **Stale**), pruned, dead, abandoned, expired

**Scope**:
What a review covers — a branch, the staged or unstaged changes, the whole worktree,
whatever changed since the last **batch** went out, or any git revspec.
_Avoid_: mode, filter, range (a range is a span of lines, see **Range**)

**Trim**:
The commits taken out of a **branch** scope, however many and wherever they sit. The default
is none, and they do not have to be next to each other: a trim can take one commit out of the
middle and leave the commits older than it in the review. The word is subtractive, which is
what the reviewer does: they remove commits from a whole that is there by default. "Trimmed
to four commits" and "reset the trim" both read correctly, and the verb and the noun are one
word. Uncommitted and untracked work stay in the review under every trim, because the
post-image of a branch review is the working tree and no trim of any shape reaches it. Kept
per branch, and dropped whole when any commit in it leaves the branch: a trim belongs to one
reading of one branch, and a rewritten commit is not that reading. Said of a **branch**
scope only: the working-tree scopes have no commits to take. A modifier on that scope and
never a scope of its own, because a sixth name would have to answer what it means with
nothing taken out, and because `gs` is a key held down and must not get a new stop. Not
_filter_ and not _mode_: both are on **Scope**'s avoid list. Not _range_, which is the lines
an annotation covers, and not _span_, which is the changed characters inside a paired line.
Not _selection_ either: that is on **Range**'s avoid list, and reusing it invites the
collision that list exists to prevent.
_Avoid_: filter, mode, range, span, selection, cutoff

**Review view**:
The syntax-highlighted diff of a scope, with annotations projected onto its lines. Means
the whole surface in either **layout**.
_Avoid_: diff view, buffer

**Layout**:
How the review view arranges a diff: **unified**, deleted and added lines stacked in one
column, or **split**, the before- and after-images as two **panes** side by side.
_Avoid_: mode, diff view

**Pane**:
One of the two windows in a split layout, holding the before- or the after-image. Not
_side_: a diff line's side is already add/del/ctx, and one word must not do two jobs.
_Avoid_: side, column, window

**Muted**:
Said of a **pane** that does not have focus: its colors pulled toward the background through
a highlight namespace of its own, so the pane with focus is the bright one and a reviewer
never has to press a key to find out where they are. A muted pane still lights the row its
cursor is on — see **counterpart row**, the one color in it that the muting does not answer
for. Said of a pane and never of the file
tree: the tree is never muted, it draws in the active colorscheme's own colors under every
focus, and focus landing in it mutes the panes instead. Never said of a file, and never of
anything drawn *on* the diff. Not _dimmed_: an archived **entry** is already drawn dimmed on
the diff, and one word must not do two jobs — the same collision that kept _side_ reserved
for a diff line's add/del/ctx when the split layout needed a word for its windows. Not
_faded_ either: that is the file the cursor is not in. The three are different mechanisms as
well as different statements: dimming is a highlight group the render chooses per entry,
fading is the group a mark carries, muting is every group at once in one window.
_Avoid_: dimmed, grayed, faded, inactive

**Faded**:
Said of a file the cursor is not in: the colors of its rows pulled toward the background, so
the file being read has a visible boundary and the file just left stops competing with it.
Said of a *file* and never of a window or of an **entry**, and the unit is the file and never
the **hunk** — a cursor crossing from one hunk to the next inside one file changes nothing on
screen. A faded file keeps its header row bright and its hunk headers fade with its body.
Drawn by changing which group a mark carries, never by a foreground laid over the file: a
foreground above the syntax replay would win where a parser painted and lose where none did.
Not _muted_, which is a **pane** without focus, and not _dimmed_, which is an archived entry.
The blend is the muting's, at a strength of its own.
_Avoid_: muted, dimmed, grayed, inactive, unfocused

**Solo**:
Said of a **review view** that draws one file — the file being read — and none of the others.
A rendering choice and never a **scope**: the review goes on covering everything its scope
covers, so the file tree, the reviewed marks, the **queue** and the **payload** are what they
were, and which file was on screen never reaches the receiving agent (ADR-0002, ADR-0009).
Makes the same statement **faded** makes — the file being read is the one that matters —
through a different mechanism: faded pulls the other files' colors toward the background,
solo does not emit their rows at all. Orthogonal to **layout**, because a **split** diff can
be soloed and a third layout value could never say so. Moving between files repaints, so `R`
marks the file reviewed and advances to the next unreviewed one rather than collapsing what
it has just drawn — the one key whose meaning solo changes. Not _focus_, which is already
which window the cursor is in, and which **muted** is written against.
_Avoid_: focus, isolate, single-file mode, only, zen

**Frame**:
What marks a file out in the **review view**, so a file has a visible beginning and a visible
end. Drawn as highlight groups on rows that are there anyway, and never as a row of its own: a
row would need an **anchor**, and a reviewer could then put a cursor on a thing that is not
part of the diff. The header row is a **band** — filled in a background one step off `Normal`,
which is computed from the reviewer's own theme rather than taken from a palette this plugin
holds, and far enough off it to clear that theme's cursor line. The band carries no foreground,
so the path's two halves, the `+N -M` stat, the note count and a host's file glyph all keep
their own colour on it, and a file already **reviewed** goes on taking the colour a comment
takes, which is the mark under the band and not the band itself.
The **pad** after the last hunk carries no rule: a band is a beginning nobody can scroll past,
so the second hairline had nothing left to close, and a header between two rules two rows apart
read as text in a box rather than as a title. A terminal with no true colour has no background
to compute at a strength, so there the band is an underline on the header row and the pad keeps
its own — never an overline, which Neovim accepts and many emulators ignore, so an edge drawn
with one is invisible on some terminals and nothing reports it. A collapsed file gets the band
alone, because it has no body to bound. Fades with its file, the way that file's hunk headers
do and its header row does not (see **Faded**).
Not _separator_: a frame says where one file ends *and* where it began, which a thing between
two files cannot.
_Avoid_: border, box, card, rule, divider, separator

**Band**:
The filled row a file's header is drawn as: a background one step off `Normal`, reaching the
window's edge because a line-wide highlight is painted past the end of the text. Computed from
the reviewer's own theme — `Normal`'s background pulled toward `Normal`'s own foreground — so it
belongs to a colorscheme this plugin has never seen, and pulled far enough to clear that theme's
`CursorLine`, or a header row would read as permanently selected and the cursor would disappear
on the row a reviewer lands on after a jump. Carries a background and never a foreground: a
line-wide group replaces every attribute it sets on the marks beneath it, so a foreground would
flatten the whole row, and a background is the one attribute that row does not already own.
Blends with its **pane** when the pane loses focus and stays bright on a **faded** file, like
the header row it fills. Said of the header row alone: no other row in a **review view** is
banded, and the fill on a changed line is that line's own diff colour.
Not the *priority band*, which is where a mark sits in the emission's priority order, and not
the row bands the syntax emission tracks what it has painted in — both are internal to the
render and neither is a colour.
_Avoid_: bar, fill, highlight, stripe, background

**Wrap**:
Said of a **review view** that folds a line too wide for its window onto further rows, rather
than making the reviewer scroll sideways to read it. The rows are the window's and never the
diff's: nothing is added to the buffer, so every **anchor**, every row an annotation hangs on
and every count stay what they were. A continuation row carries a marker where the change bar
would be, because neither the bar nor the line number repeats and their absence is worth
explaining rather than merely noticing. Said of the **unified** layout only: a **split** layout
stays unwrapped, because two **panes** that fold by different amounts stop being row-aligned,
and row alignment is what split is for. Not the wrapping a **note** goes through, which the
renderer does itself because a **virtual line** clips where a window would fold; and not the
wrapping `]F` does, which is a navigation key returning to the first file.
_Avoid_: soft wrap, fold, reflow, line break

**Filler**:
A blank row emitted in one pane where the other has no counterpart — a pure addition, a
pure deletion, a file that exists on only one side — so the two stay row-aligned. Distinct
from a **pad**, the blank row after a hunk, which both panes draw.
_Avoid_: padding, spacer

**Counterpart row**:
The row in a **muted** pane opposite the one the cursor is on, lit with a group of its own so
it reads as secondary to the focused pane's. The panes are cursorbound, so which row it is
stays Neovim's business and only which color it is lit in is the plugin's — nothing is
emitted onto the diff for it and no mark is added. Where the opposite row is a **filler**,
the lit blank row is what says *nothing existed here before*, which is the case it exists
for. Said of a row in a pane and never of the file tree's lit row: the tree is not
cursorbound, so its row names the file being read rather than sitting opposite anything. Not
_twin_: a blended highlight group is already the twin of the group it blends, and one word
must not do two jobs — the same collision that kept _side_ reserved for a diff line's
add/del/ctx.
_Avoid_: mirror, twin, shadow, ghost

**Sticky header**:
The current file named on a **pane**'s winbar, so the file survives reading past its own
header row in the diff. The file the *cursor* is in, not the one at the top of the viewport,
and always shown rather than only once the real header has gone — it names the file an
annotation would attach to. Carries what the in-buffer file header carries: the icon, the
chevron, the path, the `+N -M` and the note count, with the review summary right-aligned
beside it.
_Avoid_: breadcrumb, pinned header, floating header

**Span**:
The run of characters within a paired line that differs from its counterpart, emphasized so
the eye lands on the change rather than on the line. Not _range_: a **range** is already a
span of *lines* an annotation covers, and one word must not do two jobs — the same collision
that kept _side_ reserved for a diff line's add/del/ctx when the split layout needed a word
for its windows. A span is a rendering concern and never part of an **entry**.
_Avoid_: range, region, chunk

**Review path**:
Annotating from inside the review view, where the diff and its anchors decide what an
annotation is attached to.

**Capture path**:
Annotating from an ordinary buffer with no review view open, where the buffer itself decides
what an annotation is attached to. Produces the same **entry** as the review path.
_Avoid_: viewless path, buffer path

### Annotating

**Annotation**:
A typed remark bound to a place in the code. The unit a reviewer creates.
_Avoid_: comment, remark, note (a note is the prose inside an annotation)

**Entry**:
An annotation as it sits in the queue. An entry never records which path captured it.
_Avoid_: item, record

**Annotation type**:
The category an annotation carries — bug, fix, suggestion, nitpick, issue. Configurable; a
type is not decoration, because it changes what the receiving agent is told to do.
_Avoid_: category, severity, label (a label is a type's group heading)

**Directive**:
The instruction attached to an annotation type, telling the receiving agent what to do with
that group. Optional — a type without one still groups.

**Untyped annotation**:
An annotation carrying no annotation type. Says something is worth reading without saying
what should be done about it.

**Kind**:
The shape of what an annotation covers — a line, a range, a hunk, a whole file, or nothing
at all. Determines how the annotation is rendered and whether it has a place to anchor to.
_Avoid_: scope (a scope is what a review covers), granularity

**Bare note**:
The kind for an annotation with no file behind it — a thought sent on its own.
_Avoid_: orphan, standalone annotation

**Note**:
The prose a reviewer writes inside an annotation.
_Avoid_: comment, message, body

**Range**:
A span of lines an annotation covers.
_Avoid_: selection, scope

**Anchor**:
The place an annotation is bound to, and the key that identifies it. What lets the same
annotation be found again in a repainted diff.

### Composing

**Composer**:
The buffer a reviewer writes a note in.
_Avoid_: prompt, input, editor

**Draft**:
Note text kept from a composer that was abandoned rather than submitted, restored the next
time the same thing is annotated.
_Avoid_: autosave, unsaved note

**Reference**:
A pointer to another file, written into a note while composing, that reaches the receiving
agent as an `@ref`.
_Avoid_: mention, link, attachment

### Delivering

**Queue**:
The annotations accumulated so far, awaiting submission. Survives restarts and is shared by
both paths.
_Avoid_: list, buffer, inbox

**Batch**:
The queue as a single unit of delivery — what one submission sends.

**Payload**:
The rendered text of a batch: the message the receiving agent actually reads.
_Avoid_: output, body, prompt

**Preamble**:
The prose a reviewer writes above a **batch**, addressed to the receiving agent, that is not
an **annotation**. It says what the batch is about as a whole — which part matters most,
what to ignore, how the pieces relate — and the payload renders it above the header, where
it is read before the findings. Composed at **submit** time and never held in the **queue**,
which keeps **entries** and nothing else. A **draft** of one is kept per **checkout**, because
a preamble is about a batch and not about a file. An **immediate send** carries none
(ADR-0004), and a copied payload carries none either: only a **dispatch** carries one — and
a dispatch keeps it, in the **archive**, because it is part of what was sent. It belongs to
the dispatch and not to either half of a batch the archive split, so both halves carry it,
as both carry the same stamp and the same **target**.
_Avoid_: prologue, cover note, header, message, prompt

**`@ref`**:
A file or line reference inside a payload, written relative to the **target**'s working
directory so the agent can resolve it.

**Target**:
The agent session a batch is delivered to.
_Avoid_: destination, recipient, agent (an agent is the software; a target is the session)

**Submit**:
Render the batch and hand it to the host's delivery adapter, clearing the queue if the
adapter reports a **dispatch**.
_Avoid_: send (reserved for the adapter), flush, publish

**Dispatch**:
A payload handed off to the send adapter, said of the handoff and not of its arrival — the
adapter cannot know synchronously that an agent took it. A dispatch is the one thing that
empties the queue.
_Avoid_: delivered, sent, accepted

**Immediate send**:
Delivering a single annotation on its own, without it joining the queue.
_Avoid_: quick note, one-off, direct send

**Archive**:
The batches already dispatched from a **checkout**, kept after the queue that held them was
cleared — the **entries** as they went and the **preamble** they went under. Only a
**dispatch** writes it, so a payload copied to a register is not in it. Read-only, which is
a claim about the record and not a feature left unwritten.
_Avoid_: history, sent queue, outbox

**Snapshot**:
The commit object recording the working tree at the moment a batch was **dispatched**.
Minted without touching refs, the index or the working tree, and on a clean tree it is
`HEAD`.
_Avoid_: stash (a stash is a thing git keeps; this one is never on the stash list),
checkpoint

### Embedding

**Host**:
The Neovim configuration the plugin is installed into, which supplies everything the plugin
declines to have an opinion about.
_Avoid_: consumer, client, user config

**Adapter**:
A function the host injects to supply a capability the plugin deliberately lacks — choosing
a target, picking a file, delivering a batch, composing a note, reading a file in a diff
tool of its own, choosing which **checkout** to switch to, giving a file the icon its filetype
has in that host's configuration, and giving a directory one of its own.
_Avoid_: hook, callback, plugin, provider

### Staleness

**Blob**:
The hash of a file's contents at a moment worth comparing against — when an annotation was
captured, or when a batch was **dispatched**. The key both **stale** and **touched** are
judged with.

**Stale**:
Said of an annotation whose file has changed since it was captured, so its line numbers may
no longer mean what they did.
_Avoid_: dirty, outdated, invalid

**Touched**:
Said of an archived annotation whose file has changed since its batch was **dispatched** —
per file, never per **range**. Distinct from **stale**, which is the same comparison against
a different blob and means something else entirely: stale says *my note may be wrong*,
touched says *the agent has been here*. The two are reported separately and must never
become one flag. Deliberately not _addressed_: the plugin knows the file moved, not that
anyone read the note, agreed with it or acted on it.
_Avoid_: addressed, handled, resolved, done
