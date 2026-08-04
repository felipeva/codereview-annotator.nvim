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
