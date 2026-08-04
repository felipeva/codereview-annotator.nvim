# Code Review Annotator

Reviewing a diff inside Neovim and handing the result to a coding agent as one message.
The plugin owns capture, the queue and the rendered message; it owns nothing about who
receives it.

## Language

### Reviewing

**Scope**:
What a review covers — a branch, the staged or unstaged changes, the whole worktree, or any
git revspec.
_Avoid_: mode, filter, range (a range is a span of lines, see **Range**)

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

**Filler**:
A blank row emitted in one pane where the other has no counterpart — a pure addition, a
pure deletion, a file that exists on only one side — so the two stay row-aligned. Distinct
from a **pad**, the blank row after a hunk, which both panes draw.
_Avoid_: padding, spacer

**Span**:
The run of characters within a paired line that differs from its counterpart, emphasised so
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
The batches already dispatched from a repository, kept after the queue that held them was
cleared. Only a **dispatch** writes it, so a payload copied to a register is not in it.
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
tool of its own.
_Avoid_: hook, callback, plugin, provider

### Staleness

**Blob**:
The hash of a file's contents at the moment an annotation was captured. The key staleness is
judged against.

**Stale**:
Said of an annotation whose file has changed since it was captured, so its line numbers may
no longer mean what they did.
_Avoid_: dirty, outdated, invalid
