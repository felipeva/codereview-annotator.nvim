# Design notes

Things that are non-obvious and cost real debugging time. Several obvious-looking
approaches here are wrong for reasons no amount of reading the code reveals — this file is
where those reasons live. Read it before changing rendering, diff parsing, or anything
touching windows and modes.

For vocabulary (*scope*, *pane*, *filler*, *anchor*, *dispatch*, …) see
[`CONTEXT.md`](../CONTEXT.md). For the decisions behind the architecture, see
[`docs/adr/`](adr/).

## Rendering and syntax highlighting

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

**Extmark columns are byte offsets, not display columns.** The change bar and the `│`
separator are multibyte, so each rendered row records where its code text actually begins;
assuming a fixed prefix width shifts every highlight on every changed line.

**The queue float's bar is buffer text, not an extmark**, and that is what makes the
cursor-to-entry mapping exact. Every row an entry owns carries the bar, so the float can
record which entry *every* row belongs to instead of recording headings and guessing the
rest by nearest-above — which is how dropping used to act on an entry whose extent was
invisible. The blank row *inside* a note carries the bar and the row *between* two entries
does not: a blank-line separator stopped being able to hold the boundary the moment notes
kept their own line structure, because a note can contain one. Its highlight columns are
byte offsets for the same reason the diff's change bar's are, and the glyph is the
configured `icons.change_bar`, so a host that sets a wider one moves those offsets too.

**That float wraps its own rows and turns `wrap` off in the window.** Letting the window
wrap folds a long line back to column zero, where there is no gutter and no bar, and the
entry appears to end mid-note. Notes go through the renderer's own `wrap`, by display
width — the same helper, not a copy, because splitting by byte passes every ASCII assertion
and breaks the first CJK or emoji note.

**Collapsing is done at render time, not with folds.** A collapsed file's body is never
emitted, so the buffer and the anchor map stay small on a large review, and there is one
mechanism instead of two.

**The intra-line span groups set a background and no foreground.** They sit at a priority
band above the line's own diff colour and below the treesitter replay, so a foreground there
would lose to the replay wherever a parser had painted and win wherever one had not —
emphasis that changes colour depending on which languages the reader has installed. A
background alone composes with the replay, which is what keeps code readable inside a span.
It is also why the two groups copy `DiffText`'s background instead of linking to it: a link
would carry the foreground along.

## Parsing git's output

**Hunk bodies are consumed by their declared line counts**, not by scanning for the next
`@@` or `diff --git`. A diff of a patch file contains those markers as ordinary content.

**`\ No newline at end of file` arrives after the counters have run out.** When the last
line of a hunk carries it, a counter-only loop condition drops the marker and the file
silently gains a trailing newline it does not have.

**Untracked files are synthesised, not diffed.** `git diff --no-index` exits 1 when the
files differ — the normal case — and labels the pre-image `a/dev/null`. Building the entry
directly avoids both quirks.

**Intra-line spans come from a character diff, never a byte diff.** `vim.diff` is handed
each line as a sequence of *characters*. The obvious implementation — splitting a Lua string
with a pattern — splits by byte, passes every ASCII test in the suite, and corrupts the first
accented, CJK or emoji line it meets: `é` and `è` share their leading byte, so a byte-wise
diff emphasises a trailing byte alone, which is a boundary inside a character and a
rendering error rather than a cosmetic one. Correctness costs about 6 ms across 6,000 line
pairs, so there is no performance argument for the other one. `src/nonl.md` in `mkfixture`
is the only fixture line that can fail this, and it is there on purpose.

## Performance

**Blob hashes are resolved in two batched calls**, `git hash-object` for working-tree
files and `git cat-file --batch-check` for everything behind a ref. One process per file
was, measurably, more expensive than all the treesitter work combined — on a 60-file diff
it was over half the open time.

**Progress is written on mutation, not on paint.** `paint` also runs on window resize, and
persisting there turns dragging a split into a stream of file writes.

**The anchor map's inversion is cached on the view, and everything that redraws drops it.**
The treesitter replay needs the anchor map inside out: per file, which source line is drawn
on which row and at what byte column, plus the rows that file occupies. Derived per call it
is a walk of the whole render, and `syntax.apply` is wired to `WinScrolled` *and*
`CursorMoved` — on a 90,000-row review that walk alone is most of the 19 ms a reviewer paid
per keystroke, while the parse behind it was already memoised twice over. It is a pure
function of the render and, in the split layout, of the before render, so only a repaint can
change it: it sits on the view as `syntax_rows`, beside `syntax_cache` and `syntax_painted`,
and follows their rule exactly — dropped when the diff is re-read and when the scope
changes, dropped by every paint, rebuilt by the first pass after one. What it caches is the
*inversion*; a file is still parsed whole the first time any of its rows come near the
window, for the reason above. Held, it is about 11 MB on a 90,000-row review — the same
tables that were previously built and thrown away on every keystroke.

**Invalidating it is the careful half, not caching it.** A map that outlives the render it
was inverted from still produces well-formed extmarks in the right groups — on rows that now
hold unrelated code, which is worse than highlighting that is merely missing. That is why
the paint drops it whether or not highlighting is switched on: a map left behind by a paint
made with `syntax = false` would otherwise be replayed the moment it was switched back on.
It is also why `syntax_spec` asserts the map against the render on screen, and asserts that
the marks still cover their own tokens after a repaint that moved rows, rather than merely
asserting that a map exists.

**Extmark emission is bounded by the viewport, and the render is not.** A 300-file review
produces 271,000 marks, and writing all of them into a buffer is 141 ms of a 384 ms
repaint — paid on every resize, expansion, reviewed toggle, scope change and queued
annotation, which are the operations that have to feel immediate. Only the rows near the
window are emitted; the rest arrive when a reviewer scrolls to them, through the
autocommand that already tops up highlighting. `render.build` still returns the complete
`marks` array for both panes: that is the seam that makes this cheap, because the split,
the spans and the anchor totality are all asserted against returned data rather than
against a buffer, and bounding what is *written* leaves every one of those assertions
valid. It is also why `bounded_spec` has a case asserting the render still produces the
marks the buffer never receives — "bounded" must never be satisfiable by the render having
stopped producing them.

**The bound is the harvest's own, and rows are tracked in bands.** One margin decides how
far past the window both the emission and the parse reach; two figures would drift, and a
harvest reaching further than the emission is highlighting on a row with no diff background
under it, so `syntax.viewport` is what the view asks rather than arithmetic of its own.
What has been emitted is remembered in bands of that same margin, quantised so the record
stays a handful of lookups rather than a set the size of the review, and so a band is
either wholly emitted or wholly not — which is what lets both panes share one record and
stay comparable row for row. The record is dropped where the namespace is cleared, exactly
as `syntax_painted` is: what a band means is decided by the render it was emitted from.
Marks are *found* rather than filtered — `render.build` appends each as it draws the row it
belongs to, so a pane's marks are in row order and a band is a slice of them; filtering
would be a walk of the whole review on every scroll, which is the cost this removes.

**Intra-line spans are computed when the diff is parsed, never when it is drawn.** On a
12,000-line diff they cost about as much again as a whole repaint. Paid once per git read
that lengthens opening by roughly a third; paid per repaint it would be a ~50% regression on
the operation that runs on every resize, expansion, reviewed toggle and scope change — the
one that has to feel immediate. Invalidation is free, because a re-read produces new lines
carrying new spans. `make perf` reports the figure on its own line, so a change that moves
the work back into the render is visible rather than merely slow.

## References and paths

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

## The archive

**The state document's `VERSION` must not be bumped to add a key.** A mismatched version
is discarded on load, deliberately — restoring marks that mean something different than
they did when written costs more than losing them. So a bump made to make room for
`archive` would throw away every reviewed mark in every existing file, to add a key those
files simply lack. New keys are defaulted on load instead, exactly as `scopes` and `queue`
already are.

**The queue's id counter does not survive a process, and archived entries do.** It is
module-level and starts at 1, which was harmless while everything carrying an id was in the
queue: the restore seeds it past whatever came back. An archived entry has left the queue
but not the screen, so a session that dispatched ids 1..n and then restarted hands its next
annotation an id already drawn on the diff — and dropping an annotation resolves by anchor
key and then by id, so `x` removes the wrong one. The restore therefore seeds from the
archive as well, *after* both stores have been read, because entries are split between them
and an id is unique across the pair.

**`git stash create` mints a commit and does nothing else.** No ref moves, the index is not
touched and the working tree is not reverted, which is the only reason it is safe to run
behind a submit. Two consequences worth knowing before reading a snapshot back: a clean
tree mints *nothing* and prints nothing, so the snapshot falls back to `HEAD` — that is a
case, not an edge — and untracked files are not in the commit at all, so a file untracked
at dispatch is covered by the same synthesis the branch and worktree scopes already apply
to untracked files, not by the snapshot.

## The file tree

**The tree's parent directory is found by depth, not by proximity.** `h` on a file folds
the directory containing it — but the nearest directory row *above* a file is often a
sibling directory the cursor already scrolled past, not its parent. Each row records its
tree depth, and the parent is the nearest directory row above with a smaller one.

**The panel repaints only when the cursor crosses into a different file.** Following the
diff cursor runs on every `CursorMoved`; rebuilding the tree on each keystroke is real work
on a large review.

## Windows, modes and focus

**`nvim_win_call` propagates only the first return value.** Returning `line("w0"), line("w$")`
from it silently loses the end of the range.

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
