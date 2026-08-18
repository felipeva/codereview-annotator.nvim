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

**The commit list's size columns are a column only while every row spends the same width on
them.** Each row is fitted to a width it knows, and the date used to take whatever width its
own words needed — which is invisible until something is drawn *left* of it, and then the
size column beside a `5 days ago` sits two columns off the one beside a `60 minutes ago` and
comparing two commits' sizes is arithmetic. Both the size and the date are therefore padded
to the widest the listing carries, which is also what leaves every row the same number of
columns wide. Dropping the date's padding alone reds one case in `trim_float_spec`, and it
reds on the row *widths* rather than on the size's own offset: the size is pinned on its left
by the subject's own fixed width either way.

**That float's counts arrive after it is drawn, and the float can be gone by then.** The
listing is a metadata query and near-instant; the sizes are a diff of every commit on the
branch, which is what was refused when the counts were first left off a row. So the float
opens on the listing and `git.branch_sizes` answers on a later tick — and `q` closing the
window wipes its buffer, so the callback is written to ask both before it paints anything.
An error thrown there lands in the messages rather than in any caller's `pcall`, which is
where the spec reads for it.

**A window-local highlight namespace reaches extmark highlights.** Attaching one with
`nvim_win_set_hl_ns` changes what a group resolves to *in that window*, and that reaches a
line background set by `line_hl_group`, the treesitter replay's extmarks at their higher
priority band, and the winbar alike — which is what lets a **muted** window recede without
the render knowing anything about it. Extending a namespace a window is already showing
works too, and takes effect on the next redraw: measured in a prototype, not assumed. A
group the namespace does not define falls back to its global definition, so what is not in
it stays bright.

**The winbar draws in `WinBar`/`WinBarNC` and in the plugin's own groups on top of them.**
A segment carrying a `%#Group#` takes that group's foreground and leaves the bar's own
background showing through, and both halves of that resolve through the window's highlight
namespace — measured, not assumed: in a **muted** pane the same cell comes back as the
group's *twin* over the muted `WinBarNC`'s background. So the sticky header mutes with its
window on two mechanisms at once, and each needs the other to be right. The built-in pair is
in `EDITOR_GROUPS`; every group the bar asks for is in `LINKS`, which is what `hl.groups()`
derives the muted set from, so a bar group added anywhere else is one a muted pane leaves
bright. `split_spec` reads two cells of one bar for exactly this reason: one inside the path,
which carries no group of the plugin's own and is where the muting is proven, and one on the
file's added count, which carries one and is where the color is.

**The path is the one thing on the bar left in the bar's own group**, and that is what makes
it the brightest thing on the left rather than any group being brighter: the icon and the
chevron in front of it are quiet, the separators quieter still, and everything else carries
the group the surface saying the same thing on the diff carries — the stat, the note count
and the untouched tally are the diff's own groups, not a second set for the bar. One color,
one meaning, wherever a reviewer meets it.

**Every name on the winbar is escaped, per segment, and the bar is padded by hand in display
columns.** A bar is built from typed segments — chrome, which the plugin wrote, or a literal,
which is a name the plugin did not choose — and `render.bar` doubles every `%` in a literal.
The rule is the same one the wholesale escape held: the bar carries a path a reviewer's
repository chose, and a `%f` in one would be read as a statusline item and expanded into
something else. What moved is where it is applied, so that a caller cannot pass a path
unescaped by accident: a segment has to say which kind it is, and the kind that takes a name
is the kind that escapes it. **Escaping is by kind and coloring is not** — either kind may
carry a highlight group, because most of what is worth coloring on this bar is a name: the
**target**, the base revision, a count carrying a glyph a host configured. The alternative is
a caller writing the markers around a name by hand, which is markup arriving from outside the
one seam that decides what markup is. The statusline's `%=` would now be possible, and would
still buy nothing — see below.

**The ruler for that bar is `render.bar_width`, and it measures what is drawn.** Two things
separate a bar's string from its columns, and they pull opposite ways. Almost everything on
the bar is multibyte — the file icons, the chevron, the `·` separators, a rename's `→` — so
a bar padded by `#` lands a dozen columns short of the pane while every ASCII assertion in
the suite still passes; the renamed file is what catches it. The mirror of that is a
highlight marker: `%#Group#` is characters in the string and no columns at all on the
screen, so a bar measured with its markers in drifts the other way, by the width of every
one of them. That half stopped being hypothetical the moment the bar was colored: a
hundred-column bar is now some two hundred and fifty characters, so a ruler counting the
string overshoots by more than the pane is wide. Both are why the padding is arithmetic
rather than `%=` — the fitting rule has to know how many columns the path may keep, which is
the same measurement either way, and a bar that padded itself would take its own width out of
reach of every assertion that reads it. The same trap reaches the *tests*: a needle spanning
two segments is not in the option's string at all, so `h.winbar` reads the bar as Neovim
draws it and every assertion about what a bar says goes through it.

**What the sticky header sheds on a narrow pane is decided by what it now says twice.** The
summary drops the review's line totals and the queue's note count first — the file segment
beside them carries that file's own `+N -M` and that file's own note count — and only then
does the path give up its head, down to the file's own name. Below that the summary keeps
shedding, from its head, so the target it ends on is the last thing to go. Shedding the
summary's *tail* was the first attempt and is wrong: the tail is where everything nothing
else on screen says has accumulated. The review's own name used to head that list, and it is
gone from the bar entirely: it was the first thing dropped on a narrow pane, and a bar inside
a review does not need to say it is one. That, with the words the glyphs replaced, is about
thirty columns handed to the path — enough that a 45-column pane keeps the directory above
the file as well as the file.

**Collapsing is done at render time, not with folds.** A collapsed file's body is never
emitted, so the buffer and the anchor map stay small on a large review, and there is one
mechanism instead of two.

**The intra-line span groups set a background and no foreground.** They sit at a priority
band above the line's own diff color and below the treesitter replay, so a foreground there
would lose to the replay wherever a parser had painted and win wherever one had not —
emphasis that changes color depending on which languages the reader has installed. A
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
diff emphasizes a trailing byte alone, which is a boundary inside a character and a
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

**That map exists only when highlighting is on, so nothing outside `syntax.lua` may depend
on it.** It holds a span per file — `first` and `last` — which is exactly what anything
wanting to know where a file is drawn reaches for first, and it is the wrong answer twice
over. It is nil for a reviewer with `syntax = false`, so a rule built on it silently does
nothing for them while every case that runs with highlighting on still passes. And its span
covers a file's *line* rows only: the header row above them and the hunk header before the
first of them are outside it. What records where a file is drawn is the render —
`file_rows`, the header row of every file, so a file runs from its own header to the row
before the next one. The **faded** file rule takes its spans from there, and
`faded_spec` runs one case with `syntax = false` for this reason alone: gate the fade on
`syntax_rows` and that case is the only one in the suite that goes red.

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

**A nested closure inside `note_virt` costs a third of `render.build`.** That function runs
once per annotatable row — ninety thousand times on a 300-file review, and almost always to
answer "nothing is attached here" — so anything that makes the *empty* answer more expensive
is paid ninety thousand times. Folding the per-entry work into an inner `local function` so
that queued and archived entries could share it read better and measured 17 ms → 23 ms on 60
files, before either kind of entry existed in the fixture: the early return happens first, so
the closure is never even created, and it is still the difference. Hoisted to a sibling of
`note_virt`, taking the accumulator as an argument, it is back under the original. Measure
this one with repeated `render.build` calls rather than `make perf`, whose repaint line is a
single sample and hid the regression inside its own spread.

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

**A scope's identity and its pre-image are two refs, and only one of them may be re-derived.**
A **trim** moves a `branch` scope's `before` off the merge base — up the branch, or onto a
commit no ref names at all — and leaves `identity` where it is. Anything asking *where does
this branch start* — the commit list, the progress key —
has to read the identity: the pre-image is what a trim narrows, so a commit list built from
it shortens every time a reviewer trims and takes away the rows they need to widen it again.
Anything asking *what is this review reading* has to read the pre-image. Neither may be
recomputed from `origin/HEAD` a second time: a `git fetch` in another window moves the default
branch, and a surface that re-derives the base then draws against a base the review is not
using. That is why `git.branch_commits` takes the base and no longer resolves one.

**A stored trim is checked on every read, and dropping it is what keeps the sentence to one.**
The two tempting shortcuts are one shortcut: memoise the branch's trim for the session, and
latch the sentence beside it. The memo is wrong because a reviewer can rebase in another
window with the review open — the trim then holds a commit that was rewritten, and resolution
reads it from memory without ever asking `HEAD` about it again, which is the exact failure the
check exists to refuse. The latch is unnecessary once the failing trim is removed from the
document as well as from the answer: the next read finds nothing to fail, so the sentence
cannot repeat, and there is no key to invalidate when the reviewer moves to another branch.
What it costs is a `symbolic-ref`, a document read and one `rev-list` per branch resolve — one
process for the whole set and not one per commit, which is what keeps the check affordable on
a trim that took a long branch's worth of commits out. `state.restore` already spends the
document read on every scope change.

**Any commit failing that check drops the whole set.** A trim is the commits taken out, and a
rebase rewrote the reading rather than one row of it: keeping the commits that still resolve
would leave the review narrowed by a selection the reviewer never made, and which parts of a
rewritten history are still the same reading is a claim nothing here can make. It is also what
keeps the sentence one sentence — a set that survives in part fails again on the next read,
one commit at a time.

**The one thing memoised is the built tree, and the key is why that is not the trap above.**
A trim with a hole in it reads from a tree that never existed as a commit, so it is built —
and without a cache every scope cycle, every reopen and every pick pays the whole accumulation
again. The memo the note above refuses is a stored *sha* going stale against a rewritten
`HEAD`: it answers from memory without ever asking `HEAD` again, which is the exact failure
the ancestry check exists to refuse. A key that *contains* the `HEAD` sha cannot do that —
either key changing is a new key — so the cache holds the built tree under the whole of what
built it: the repository, the base, `HEAD` and the set. Nothing else is cached. Not the trim,
not its ancestry answer, not the resolved scope: each of those is an answer about a history
that can be rewritten while the review is open, and only the first of them is checked on
every read.

**The anchor is the whole of the pre-image rule, and removing it looks like a simplification.**
Building from the merge base and applying every skipped commit — including the ones the trim
takes off the *start* — is the obvious rule and the one the spec was first written with. It
refuses two ordinary cases, both measured against a real repository rather than reasoned
about: a plain prefix trim reaching past a merge, which is the shipped `gc` flow on any
branch with a merge in it, and taking every commit out. Both collide because a merge's
first-parent diff *adds* everything the side branch brought while the merge base already
holds it. Anchoring on the newest commit of the leading run fixes both, and it is also what
keeps the git 2.38 floor off the trim that already ships: a trim with no hole reaches no
merge at all. Deleting the anchor reds 29 cases in `trim_spec`, and two of them —
`a trim reaching past the merge` and `every commit taken out` — are the ones that exist for
this and nothing else.

**A conflicting merge is decided on the exit status, and never on the word `CONFLICT`.**
`merge-tree` prints an informational trailer that says `CONFLICT (add/add): …`, and it is
tempting to search for it: the paths are right there in a sentence. It is a message written
for a human, it is not guaranteed across the versions above the floor, and a search that
finds nothing reports a conflicting merge as **clean** — which ships a review built from a
tree that could not be assembled, silently, in the one direction that matters. The exit code
is the whole answer, exactly as it is for `all_ancestors` behind a stored trim, and the paths
come from `--name-only`, which prints the tree object and then one path per line. Making the
merge ignore its exit status reds six cases in `trim_spec`.

**A merge cannot start a hole, and the rule is about where the merge sits rather than about
the row.** Taking a merge out with a commit older than it left in always collides, by the
same arithmetic that made the anchor necessary: the merge's first-parent diff *adds*
everything the side branch brought, and the anchor already holds it. The collision also means
nothing to the reviewer — merging the default branch moves the merge base forward, so what
the merge brought is already outside the review, and the files `merge-tree` would name are
files they did not write and cannot act on. So such a set is refused **before any merge is
attempted**, with a sentence about merges and no file in it. Attempting it first and
rewording what git said is the same answer with better prose.
The rule is therefore **dynamic**: the same merge taken off the *start* of the branch, with
every commit older than it taken off too, is inside the leading run — it assembles nothing,
and it is the shipped `gc` flow on any branch with a merge in it. A skipped merge above the
run is exactly a merge with a kept commit older than it, which is why no surface can grey the
row out ahead of time. Measured, in `trim_spec`: asking the question of the whole skipped set
rather than the part above the run reds the three cases written for a hole above a merge the
trim takes off the start; asking it before a plain prefix has returned reds 32, the shipped
prefix trim among them; and not asking it at all reds the two that are the sentence.

**Keying progress on the pre-image fails silently rather than loudly.** The per-scope progress
key is `name .. ":" .. identity`. Spelled with `before` it agrees with the plugin for every
scope that carries no trim, so it reads correctly everywhere until a trimmed branch review is
opened — and then it names a key nothing was ever written under, and an assertion over it
compares two empty tables and passes. `tests/codereview/state_spec.lua` built its key by hand
and had exactly this shape before #140.

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

**`since-batch` resolves through the same function every other scope does, and must.** The
temptation is a marker — a scope that says "the archive" and is special-cased downstream —
and it fails in three places at once: the diff parser is handed `git diff <before>`, the
blob hashing resolves `<before>:<path>` through `cat-file`, and the syntax highlighter
fetches whole-file content with `git show <before>:<path>`. Every one of them needs
`before` to be something git can resolve, which is why the archive stores a commit object
rather than a set of blobs, and why resolution reads that sha and returns an ordinary
scope. If a new scope ever appears to need a case in the render or the view, it is not
resolving like the others.

**The scope is offered by name and in the cycle under two different rules.** Completion
lists it unconditionally, because a reviewer who asks for it by name with an empty archive
should be told why — that is what the `nil, err` pair is for, and `branch` already answers
that way with no merge base. `gs` is the opposite: a cycle is walked blind, so a repository
that has never dispatched must not have a scope in its cycle that can only report an error.
One rule reads as two until you notice that one of them is a question and the other is a
key held down.

**Two things ask which batch went last, and they must never get different answers.** The
`since-batch` scope diffs the working tree against the newest batch's snapshot; the surface
that reads a batch back lists the newest batch's entries. A reviewer reads one beside the
other — that is the whole point of keeping a batch — so a disagreement would put the
response to one dispatch on screen with the annotations of another next to it, and nothing
anywhere would say so. Both go through `state.last_batch`, which exists for that reason and
not for brevity: the two arrived independently, each reaching for the head of the archive,
and two copies of `[1]` are what that drift looks like before it happens. It lives on
`state` rather than on either caller because `git` already requires `state` and does not
require `archive` — routing it through the surface would turn the two-module cycle into a
three-module one. Re-inlining either call is the regression, and the case that catches it is
in `archive_float_spec`, because neither slice's own spec archives more than one batch.

**One dispatch is two records, and reading it back means rejoining them.** A batch is split
across the two stores on the rule that already routes the queue — an entry with a
repository-relative path to that repository's document, a bare note or a file outside a
checkout to the store that needs no root — and the two halves are stamped from a single
`os.time()` call. That stamp is the *only* thing tying them together. Anything reading a
batch back through one accessor alone therefore drops exactly the entries with nowhere else
to live, silently and in the direction that looks fine: the file annotations are all there,
and a bare note becomes the one thing that vanishes — which is the failure the split was
meant to avoid. Matching on the stamp is load-bearing, and it resolves to one second: two
dispatches inside the same second read back as one batch. That is beyond any human dispatch
cadence and well within a loop's, which is why `archive_float_spec` clears both stores
between blocks rather than trusting the clock.

**A preamble belongs to the dispatch, so both halves of a split batch carry it.** It is not
about the entries with a repository behind them, nor about the ones without — it is about
the batch, exactly as the stamp and the target are, and those are already written to both.
Storing it on one half alone reads as correct and fails in the direction that looks fine: a
batch whose annotations all had files still shows its covering note, and the moment one is a
**bare note** the rejoin has to decide which half to believe. Both carry it, and the rejoin
takes either.

**What is archived is what the payload rendered, through the payload's own rule.** An empty
composer is a submit that sends no covering note, so the record must hold none — and a
preamble is trimmed before it is rendered, so an untrimmed one in the archive would be a
record that differs from the message by whitespace nobody can see. `payload.preamble` is
that one rule, and it is exported for this second reader rather than copied: trimming in two
places is how two things that agree today come to differ. A second trim inside `state` is
the regression, and it is invisible until the day the two disagree.

**The projection onto the diff is memoised on a write count, not rebuilt per repaint.** An
archived entry is drawn from a table keyed by anchor, exactly as a queued one is — but the
queue is in memory and an archive is a file, and a repaint runs on every resize, expansion,
reviewed toggle and scope change. Decoding the state document there would put the cost of
the whole archive back onto the operation extmark bounding exists to keep cheap, and it
would scale with what is *stored* rather than with what is *drawn*, which is the property
this feature had to hold. So `state.archive_writes` counts what can change an archive and
`archive.by_key` compares against it: the ordinary repaint pays two comparisons, and a
dispatch is what makes it read. Recomputing at the two moments the view knows about instead
— opening, and its own submit — looks equivalent and is not: an **immediate send** archives
a batch of one without emptying anything and without a repaint of its own, so the view would
go on drawing an archive it had already been overtaken by.

**Only the repository's own archive is projected.** An entry with no repository-relative path
is in the store that needs no root, and its key is built from an absolute path or from
nothing at all — so it can never name an anchor in this repository's diff. Reading that store
per view would be a second file read that could only ever return nothing.

**A queued and an archived entry on one anchor ride in the same virtual-line block.** Not two
extmarks on one row: the split layout holds the opposite pane's place by *counting* virtual
lines, so two blocks would need that mirroring to learn about the second — and getting it
wrong knocks the panes out of alignment for every row below, which reads as the two images
showing different code. One block, live entries first, keeps the count exactly what it was.

**An archived entry's `stale` flag must not be drawn.** It is persisted with the entry, so
it is there to read, and it means "this file had moved since the annotation was captured" —
a fact about a queue that no longer exists. Printed on a surface listing what already went,
it reads as a claim about the code *now*, which nothing has checked. Whether an archived
entry's file has moved since its batch was dispatched is a different question, judged
against a different blob, and it has a word of its own.

**Touchedness and staleness share a primitive and must not share a rule.** Both are blob
comparisons, and that is the whole of what they have in common. Staleness judges a *queued*
entry against the blob it was **captured** with and means *my note may be wrong*;
touchedness judges an *archived* entry against the working tree as it stood when its batch
was **dispatched**, and means *the agent has been here*. One flag would say both and
neither — an entry captured on Monday, edited by the reviewer on Tuesday and dispatched on
Wednesday is stale and untouched at the same time. That is also why touchedness is judged
against the **snapshot** rather than against the entry's own `blob`: reusing that field
makes the comparison arithmetically identical to the staleness one, which is how two rules
become one by accident instead of by decision, and it counts the reviewer's own edits
between annotating and submitting as the agent's work. Separate functions on `state`,
separate highlight groups, reported separately — a sentence for staleness, a winbar segment
for touchedness — and an archived entry's persisted `stale` flag is not drawn at all.

**It is judged per file, and against the snapshot the scope already diffs against.** Mapping
an entry's line range through the diff since the snapshot was considered and settled against:
considerably more machinery, and the case it improves stays fuzzy either way. *The agent
never opened this file* is exact under the per-file rule, and it is the question a reviewer
actually has after submitting. Reading the dispatch-time blobs out of the snapshot rather
than stamping a second copy onto each entry is what keeps `since-batch` and the untouched
tally describing one dispatch by construction: a file the tally calls touched is exactly a
file that scope shows.

**Three things are left unjudged rather than guessed at**, and each absence is silence rather
than a verdict: a file the current scope does not cover (absence from a scope is not evidence
that anything changed — the rule the reviewed-mark reconciliation already holds), a path the
snapshot does not carry (a file untracked at dispatch, which `git stash create` never
recorded), and a **bare note**, which is about no file and lives in the store that needs no
root. Only the *newest* batch is judged: an older one went out against an older snapshot, and
"has this moved since the last dispatch" is not a question about it.

**The scope rule is why the tally reads `0 untouched` in `since-batch`, and that is not a
bug to special-case away.** That scope shows exactly the files that moved since the snapshot,
so every archived entry it covers is touched by definition and the ones a reviewer is looking
for are the ones it is not showing. Suppressing the segment there would be a case in the view
for one scope, which is the thing `since-batch` was built to avoid — it resolves like every
other scope and nothing downstream knows its name. The number earns its keep in `branch` and
`worktree`, where the whole review is on screen.

**The tally is computed where the diff is read, never where the winbar is built.** That bar
is rebuilt by every paint, and a paint runs on every resize — two `git` invocations there
would be a resize handler shelling out. It is judged on opening, refreshing, changing scope
and the view's own submit, and the number is read off the view. The view also records the
`archive_writes` count it judged at: an **immediate send** archives a batch of one with no
repaint of its own, so a paint that finds the count moved drops the verdicts and the segment
with them, rather than reporting a number about a batch that has been overtaken.

**The switch a key overrides is read through an accessor, and the key writes no
configuration.** `gA` is a runtime override of `archived`. It sits beside the configured
value in `config`, is unset until the key is pressed, and unset means the configured value.
Writing that value instead would leave a host's own `setup()` call describing something that
is no longer true, and it would make a keystroke indistinguishable from a decision the host
made. It is module state rather than view state because the choice has to outlive a review —
a reviewer presses the key once, not once per review — and it is deliberately not persisted,
for the reason the chosen **layout** is not: a display preference must never become durable
state a reviewer has forgotten they set. What this costs is that every reader of the flag has
to go through `config.archived()`. A `config.get().archived` left behind anywhere is a
surface the key silently does not reach.

**Toggling it has to judge before it paints, and a paint alone will not drop the tally.**
The `untouched` segment is read off the view rather than computed by the winbar, and a paint
only drops it when the archive has been *written* since the last verdict — which turning the
switch off is not. So a toggle that merely repaints leaves the number on the bar while
nothing it counts is on the diff, which is the one state this feature's coarseness exists to
refuse. `view.toggle_archived` runs the judgment itself, and that is also where the two
`git` invocations behind the number are skipped when the answer is "nothing drawn".

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
on a large review. The crossing is judged on the view rather than inside the tree's sync,
and judged whether or not there is a tree — a latch that stopped with the window would sit
on the file being read at the moment the tree was dismissed, and reading that same file
again once it was back would repaint nothing. The **sticky header** hangs off the same
crossing, which is the other half of why: a winbar hung off the tree's own repaint would
name the right file with the tree open and freeze the moment it was dismissed — the one
case the header exists for.

## Windows, modes and focus

**`nvim_win_call` propagates only the first return value.** Returning `line("w0"), line("w$")`
from it silently loses the end of the range.

**One terminal resize fires `VimResized` *and* `WinResized`, so a callback on both runs
twice.** Measured by driving a real Neovim over a pty and resizing the pty three times:

```
3 real terminal resizes -> WinResized=3 VimResized=3
```

The view's resize autocommand listens to both, so every terminal resize used to cost two
complete repaints: both panes re-rendered, both buffers rewritten, the whole file tree
rebuilt, twice. Confirmed in ordinary use as well — 6 and 6, against 14 full paints, which
is the 12 those callbacks caused plus the 2 from opening the review.

The two arrive in a fixed order and agree about what they see, which is what makes one
comparison enough. `VimResized` is first, and the windows already report their new
dimensions when it lands, so `WinResized` reads exactly the same numbers a moment later:

```
resize to 100x36   VimResized  after 22x33  before 42x33  tree 34x33
                   WinResized  after 22x33  before 42x33  tree 34x33
```

That order was the trap worth measuring rather than assuming. Had `VimResized` arrived
before the windows moved, a record written at the first callback would have been stale, the
second would have seen a change, and the review would have repainted twice anyway — with a
guard that reads as correct and halves nothing. It does not, so the record is written by the
**paint**, which is also what keeps every other repainting path in step: the layout toggle
and the file tree's arrival both change a pane's width and repaint for themselves, and the
event the main loop lands afterwards then finds nothing to do.

**That autocommand has no pattern and no buffer, so a window resized anywhere runs it.**
Including in another tab page, where the review is not even on screen. Measured over the
same pty: `:tabnew` followed by `:split` fired `WinResized` twice with every review window
the size it already was — two full repaints of a review nobody was looking at. The same
comparison answers it, because none of the review's windows moved.

**`winhighlight` with `NormalNC` cannot mute a pane.** It is the obvious way to make an
unfocused window recede and it is the wrong one here: it changes only a window's *default*
foreground and background, and in the panes almost nothing uses those. A changed row carries
its own line background, and code foregrounds come from the treesitter replay's extmarks at a
higher priority band — so `NormalNC` leaves every changed line and every highlighted token at
full brightness and dims little but the empty space, which reads as broken rather than as
muted. Measured with a background group standing in for a changed line and a higher-priority
foreground group standing in for the replay:

```
bright                      { background = 0x003300, foreground = 0xff0000 }
muted (both defined)        { background = 0x001100, foreground = 0x550000 }
muted (background only)     { background = 0x001100, foreground = 0xff0000 }
```

The first two lines are a window-local highlight namespace doing what `NormalNC` cannot; the
third is the graceful failure that namespace keeps — a group with no variant in it stays
bright rather than going wrong. `NormalNC` is adequate only on the file tree, which has
almost no highlights of its own — and the tree is never muted now, so there is nothing left
there for it to do.

**That namespace holds links, and the link is what makes the blend reachable.** Each entry
names the group that holds the blended color — `CodeReviewMuted.` plus the group it blends,
so `@keyword` becomes `CodeReviewMuted.@keyword`. A group name with `@` and dots in it is
legal, and only a name that *starts* with `@` gets the treesitter fallback chain. Three
facts here were measured, not assumed:

- A link inside a namespace resolves through to an extmark highlight and to a line
  background, exactly as a definition in the namespace does.
- `:colorscheme` clears every global group, the blended ones with the rest, but it leaves
  the namespace's links alone. So a theme change is the groups' problem and the namespace
  needs no part of it. What the window rule does on `ColorScheme` is one more pass, for a
  group the new theme gives a color to at last.
- **A link that reaches no definition draws nothing at all.** It does not fall back to the
  global group, which is what a namespace with no entry does. So a group with no blend must
  have *no* entry in the namespace, and a blend the new theme cannot compute keeps its
  group as a link back to the group it blends. Either way that group draws bright. An entry
  that points at a group the theme wiped draws a hole.

**A highlight namespace colors a whole window, so it cannot color one part of one.** That
is the whole reason the two quiet states are two mechanisms rather than one. A **muted**
window's unit *is* the window, so it is a namespace: attach it and every group the window
draws is answered at once, including the groups the plugin cannot enumerate. A **faded**
file's unit is a file inside a pane, which no namespace can express, so the fade changes
which group each *mark* carries — the blended twin of the group the row would have carried
anyway, emitted in its place.

**A paint never calls `mute`, so a repaint driven by anything else leaves the arrangement
alone.** The muting is reasserted from the `WinEnter`/`WinLeave` pair and from nowhere else;
what a paint reaches is `mute_extend`, which adds links to the namespace and touches no window
option and attaches no namespace to anything. That is why `gA` — `toggle_archived` →
`judge_archive` → `paint`, a path with no idea the muting exists — leaves both the namespace
and the **counterpart row** exactly as they were, in both directions of the toggle. Measured,
because it is a claim about what a *different* subsystem's repaint does not do, and neither
the archive key nor the muting owns it: `muted_spec` presses the key with an archived entry
really on the diff, and injecting a namespace reset or a `cursorline` clear onto that path is
what gives the case its teeth.

**A muted pane still lights a row, and the namespace is what makes it another color.** The
panes are cursorbound, so Neovim already lights the row opposite the one being read; what was
missing was a color of its own for it. `cursorline` therefore stays set in every pane, and
the namespace links `CursorLine` to the **counterpart row**'s blend rather than to the
muting's — a third family, holding that one member, because the alternative is a second copy
of the blend arithmetic written where the row is lit. Nothing is emitted onto the diff, and a
namespace could not have done it any other way: it colors a whole window, so *one row,
differently* has to be a group that window already draws that row in.

**`line_hl_group` wins over `CursorLine`.** Measured, with `CursorLine` set to a color
nothing else on screen holds: the cell on the cursor's own row printed the line background
instead. So a row carrying one of its own — every added and deleted line, every file and hunk
header — prints it whether or not the cursor is on that row, and a lit row can only be seen on
a context line, a **pad** or a **filler**. That is as true of the focused pane's row as of a
counterpart row, and it has been since the plugin drew its first diff. It costs the
counterpart row nothing in the case it exists for, because the row opposite a pure addition is
a filler and a filler is blank. It is also why the painted cell proving the counterpart row is
read on a context line: a reading taken on an added row prints the same color lit or unlit,
and says nothing about either.

**The fade renames a mark. It does not add one, and it does not change the priority order.**
One gray foreground laid over a faded file at a priority above the syntax replay is the
obvious shape and the wrong one: it wins where a parser painted and loses where none did, so
the result changes with the parsers a reader happens to have installed. This project already
refused that shape once, for the intra-line **span** emphasis, which is why those groups set
a background and no foreground. Renaming leaves every composition rule above this one true.

**What a crossing re-emits is keyed to the file the emission drew, not to the crossing
latch.** They are the same answer almost always, and the exceptions are what a fade built on
the latch fails on. The latch (`V.current_file`) starts nil and moves only on a crossing; a
*paint* asks the live question and can park the cursor in a third file without the latch
hearing anything — a layout toggle whose anchor round trip lands elsewhere does exactly
that. So the rows on screen can already be drawn bright for a file the latch has never
named, and re-emitting "the file left" against the latch leaves that file bright for good.
The view therefore records which file the painted bands were emitted bright, beside the
bands themselves and dropped with them, for the same reason: what a mark means is decided by
the emission it came from. Both traps in `faded_spec` caught this, and neither was written
for it.

**Which review window is bright is the review's last-focused one, not the current one.** The
composer, the queue float and the archive float all take focus out of every review window, so
a rule written against the current window mutes the whole review the moment a reviewer starts
typing a note. The latch on the view moves only when focus lands on a review window, and
`view_layout` reasserts the whole arrangement wherever focus is decided — window options set
where a window is *created* are overwritten afterwards by the code that puts the panes back
in step, so creation is not where this can live.

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
