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

**The same trap is on the file header row, and it needs no unusual path to spring.** A path is
colored there in two ranges — its directories quiet, its own name bright — and it starts after
`"○ ▾ "`, which is **eight bytes and four display columns**. A mark placed at the display
column lands four bytes early and colors the chevron instead of the first directory, on every
header row in every review.

**That prefix is no longer a fixed string, and it is not the plugin's to predict.** A host
that wires the `file_icon` adapter puts a glyph of its own between the chevron and the path,
so the prefix is `"○ ▾  "` — however many bytes that host's glyph is. `file_label` therefore
spells the prefix itself and hands it over as `prefix`, and the header row paints the path at
`#label.prefix`: the string a row is built from and the offset a mark lands at are the same
expression, so neither can be updated without the other. The **sticky header** puts that same
string in one literal, which is what makes one file carry one icon on both surfaces and what
escapes a glyph the plugin did not choose.

**The file tree is the third surface and it reads none of that.** A tree row is an indent, a
state mark, a glyph and a basename — it has no chevron of its own on a file row and no path to
paint in two ranges — so it takes the glyph and not the prefix, through `render.file_icon`,
which is the rule `file_label` reaches for as well. That is the whole of what the two share:
one `pcall`, one type test, and an empty string that is not a glyph. A second copy of it in
`panel.lua` would be two places for the tree and the diff to answer differently about the same
file, and the answer they disagreed on would be a glyph a reviewer chose. The tree's own
offsets are unaffected either way, because the glyph goes *after* the state mark: the mark
keeps its column, so the range that colors it keeps its bytes. The before pane's indent is measured off it with
`strdisplaywidth` for the same reason — counted from the parts, a renamed file's two paths
would sit apart by the width of the glyph. No fixture in this suite has a non-ASCII *path* — `mkfixture.sh`'s
`src/nonl.md` is non-ASCII content on an ASCII path — so a case built on the fixture alone
proves the prefix and nothing about the path itself; `path_spec` builds a file list with an
accented path by hand for the other half, which `render.build` allows because it is pure data.
Adding such a path to the fixture would move counts and row assertions in nine specs, and the
split itself cannot be got wrong: `/` is ASCII and UTF-8 is self-synchronising, so a cut at the
last separator always lands on a character boundary.

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
where both mechanisms are proven at once, and one on the file's added count, which is where a
group of the plugin's own reaching the screen at all is proven.

**A cell inside the path answers about two groups, because a `%#Group#` names only a
foreground.** The first character of a path carries `CodeReviewFileDir` over the bar's own
background, so that cell's *foreground* says whether a group of the plugin's is in the muted
set and its *background* says whether `WinBar` and `WinBarNC` are. Both halves are
mutation-checked in `split_spec`: taking `WinBarNC` out of `EDITOR_GROUPS` reds the
background, and taking `CodeReviewFileDir` out of `LINKS` reds the foreground. The path used
to carry no group at all, and that reading proved only the second half — a fact worth knowing
if the styling is ever taken off the bar again.

**Everything on the bar carries the group the surface saying the same thing on the diff
carries.** The stat, the note count and the untouched tally are the diff's own groups, and the
path is the file header row's own pair: its directories quiet, its own name bright, both from
`file_label`'s segments rather than from a split made a second time out here. The icon and the
chevron in front of it are quiet, the separators quieter still. One color, one meaning,
wherever a reviewer meets it — which is what the path being styled on both surfaces buys, and
what it cost is that the path is no longer the one thing on the bar drawing in `WinBar`
itself.

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

**Wrap is window options, and it must not be set in the shared window helper.** That helper
gives every review window its options — the two panes *and* the file tree — and a tree row is
truncated to the panel width rather than folded, so a folded path would put one file on two
rows. Wrap is applied to the after pane after a paint instead, which is also when the gutter
width is known and what re-applies it on a resize. The options are `wrap`, `breakindent`,
`breakindentopt` and `showbreak`, all window-local; `showbreak` is global-local and
`vim.wo[win]` does set only the window's copy.

**`breakindentopt=shift:N,sbr` is what puts the marker in the change bar's column.** A diff
row begins with the change bar, which is not whitespace, so Neovim computes a natural indent
of zero for every row and `breakindent` alone folds a continuation back to column zero — under
no bar at all, which is the same failure the queue float turns `wrap` off to avoid. The
`shift` supplies the whole gutter, and `sbr` draws `showbreak` at the *start* of that indent
rather than in front of it, so the code goes on starting where it starts. Both measured in a
prototype.

**A `line_hl_group` background reaches every screen row a folded line occupies**, so an added
line stays visibly added past the fold with nothing emitted for the continuation rows.
Measured. **`virt_lines` still clip at the window edge under `wrap`**, also measured, which is
why the renderer goes on breaking a **note** to the pane's width itself: turning wrap on does
not make that pre-breaking redundant.

**`file_rows` is sparse under solo, and that is the design rather than a bug.** The render
is *told which file to draw* -- an index in `render.build`'s options -- and walks the same
file list it always walked, emitting rows for that one file. So the map holds one entry, at
that file's own true index, and the file index in every anchor and in the header row it
points at is still the true index into the review's file list. The obvious alternative is for
the view to filter its file list to one entry and call the render as it always did; that
collapses the index space, and every anchor then says file 1 while the file tree, the file
picker and the reviewed marks go on speaking the real index. Nothing would notice, because
the two surfaces never compare notes. One index space is the decision (ADR-0009).

**So a file that is not in `file_rows` is not a failure -- it is the file to draw next.**
Four surfaces go to a file *by index* and used to give up when the map had no row for it: the
file jump, the unreviewed jump, the file picker's landing and the tree's open action. All
four now say the same thing, `view.lua`'s `goto_file` -- set the soloed file, repaint through
the paint that already parks the cursor on a file's header row, and land. The queue float's
jump is the fifth site and the one exception: it takes the drawing without the landing,
because it has an arrival of its own -- the annotated row, centered, in the pane the entry's
key names -- and it has to draw *before* its anchor scan, since the rows that key is looked
for on are the rows of the render it draws.

**The sharpest failure that sparseness causes is a sentence, not a crash.** The unreviewed
jump built its candidates by iterating `file_rows` **as an array**. Over a dense map that
visits every index and is correct; over a map whose one entry is not at index 1, `ipairs`
yields nothing, the candidate list is empty, and `]F` reports *"Everything in this scope is
reviewed"* with five files still unreviewed. Nothing is drawn wrong and nothing raises. The
candidates are the review's *files*, which are dense whatever the render does, and a file is
reached by being drawn rather than by already having a row. `solo_spec` pins it with more
than one file left unreviewed and the drawn file deliberately not at index 1 -- both are
needed, or an empty answer and the right answer are the same length.

**A file motion is an index, not a row, for the same reason.** `]f` and `[f` had always meant
"the nearest file header row in that direction", which cannot answer when the file being
looked for has no row. The rule restated: the file the cursor is in is the file whose header
is nearest above it, so forward looks past that file and backward looks *at* it -- which is
why `[f` from inside a file has always gone to the top of that file rather than past it --
unless the cursor is already on that header, when backward looks before it. Equivalent to the
row rule wherever the row rule can answer, checked over every row of a real render in both
layouts and with files collapsed rather than argued. The half that is easy to drop in the
rewrite is the `[f`-from-inside-a-file one: both rules agree from a header row, so a case that
presses `[f` only from headers passes with it wrong.

**The hunk keys and the annotation keys stop at the drawn file for free, so no `if solo`
decides what they reach.** `hunk_rows` and the anchor map are both built inside the render's
file walk, which solo gates one file up, so a soloed render can only describe the file it
drew: `]h` at that file's last hunk finds no next row and reports it, and `]a` reaches that
file's notes and no other's. A reader looking for the branch that makes *that* happen will
not find one, and adding one would be a second mechanism saying what the first already says.
The **queue** is untouched by it — notes on files that are not drawn are still in it and
still submit, so what these keys reach is a question about rows rather than about what a
reviewer has written.

**The one `soloed()` branch in `jump_annotation` chooses the sentence, not the rows.** There
is now a branch to find, and this is all it does. Nothing found is a fact about the drawn
file, while *No annotations yet* is a claim about the review, so a reviewer with six
annotations in files that are not drawn read it as their work being gone (#215). The message
narrows and names `Q`; the key goes on collecting from the anchors. Do not read that branch
as permission to add a second one — the moment `if soloed()` decides what `]a` can *reach*,
the paragraph above stops being true. Two things it leans on, neither of them visible from
the branch itself: `soloed()` answers nil on an empty **scope**, which is what keeps an empty
review on the wide sentence with no case of its own; and the queue is read through `V.notes`,
the same snapshot the absence was judged against, so the two halves of the sentence cannot
disagree about what was searched.

**`R` still collapses the file it marks under solo; the advance was added beside the collapse
rather than in place of it.** Reviewed means collapsed is one rule, it is persisted, and solo
lasts a session rather than a review — so a file marked while soloing has to come back
collapsed when the drawing stops, like every other reviewed file. Under solo nobody sees the
collapse at the time, because the file gives way immediately: it is what `]f` back onto that
file finds. The unreviewed jump it advances through is told where to start from rather than
asking the cursor, because the tree's `R` marks a row the diff need not be drawing.

**Whether a file is left to go to is a question for the review; where a motion starts is a
question for the cursor, and they must be asked in that order.** A review with no files has
no cursor in one, so asking the cursor first leaves an empty scope silent where `]F` used to
say the review was done. Cost one commit to put back.

**Collapsing is done at render time, not with folds.** A collapsed file's body is never
emitted, so the buffer and the anchor map stay small on a large review, and there is one
mechanism instead of two.

**A line-wide highlight is painted across the full window width past the end of the text,
and it carries an underline out there with it.** On a **blank** row it is uniform from the
first column to the last, which is what makes the **frame**'s bottom rule possible at all:
the rule is a `line_hl_group` on the **pad** row, and no row is emitted for it. Measured on
0.12, and `frame_child.lua` reads the pane's *last* column rather than its first, because a
reading taken at the first column passes over a rule one cell wide. A row with no mark on it
is visibly distinct from a marked blank row, so the pad row's rule is something a spec can
read rather than something a reviewer has to be trusted about.

**A `line_hl_group` replaces every attribute it sets on every inline highlight the row
carries, and priority does not arbitrate between the two.** This is the rule the **frame**
was built wrong against once, and the shape of it is not what either guess said. Measured on
0.12, in a plain buffer with one column mark and one line mark and nothing else:

- A line group setting `fg` takes the foreground of every `hl_group` range on the row. A line
  group setting only `bg`, only `underline`, only `sp` or only `bold` leaves those ranges'
  foregrounds alone and applies its own attribute over them. It is a per-attribute
  replacement and not a wholesale one -- which is why the diff's `CodeReviewAdd` background
  has always let the treesitter replay's foreground through.
- **Priority does not enter into it.** The line group's foreground wins at priority 1 against
  a column mark at 4096, and it still wins at priority 1000. Priority orders inline
  highlights among themselves; it does not put one above a line group.
- **Among line groups, though, priority does decide, and the winner is applied alone.** Two
  `line_hl_group` marks on one row do not merge: the higher-priority one is used and the
  other's attributes are gone entirely. So "emit the rule beside the header's own group"
  looks like it works and silently costs that row its colour and its bold everywhere the
  column marks do not reach.

The consequence for this plugin was invisible and predates the frame: the file header row
carried `CodeReviewFileHeader` as a `line_hl_group`, and `Title`'s foreground flattened every
column mark on that row -- the `+N -M` stat and the note count were emitted, correct, and
drawn in the header's colour. Nothing reported it, because every assertion about them was
about which mark carried which group. So the frame's four groups carry **no foreground and no
background**: an underline and `sp`, which is the underline's own colour. What the row is
coloured in is a column mark of its own, below the band the stat and the path use, so the
marks that own a run of the row win it by priority -- which is the thing priority does decide.

`sp` has no `cterm` counterpart, because a terminal palette has no underline colour. On cterm
the rule draws in whatever foreground the cell already had, which is that terminal's best
rendering rather than a wrong one. `hl.lua` blends `sp` beside `fg` and `bg`, and a group
whose only colour is `sp` gets a twin like any other -- without that, the rule a file is
framed with is the one bright line in a pane that has lost focus.

**`overline` is accepted by the highlight API and comes back in the `cterm` table**, so the
temptation to draw the frame's bottom edge with one is real. It is the terminal and not
Neovim that is the risk: many emulators ignore the sequence, so that edge would be invisible
on some terminals with nothing reporting it. Both edges are underlines, and the pad row's
draws at the bottom of a blank row, which is visually just above the next file's header.

**A computed group has to write its `cterm` attributes by hand.** `nvim_set_hl` lets cterm
follow the true-color attributes only when the `cterm` table is *absent*, and
`nvim_get_hl` hands one over for any source group carrying a cterm attribute of its own --
`Title` is bold in Neovim's own default theme, so it arrives as `cterm = { bold = true }`.
Copy that table along with the colors and the frame is underlined on a true-color terminal
and on no other: the exact failure the whole family of computed groups exists to avoid, and
one no assertion over group names can see.

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

**Styling a path cost the render walk about 1.3 ms at three hundred files, and the marks
cost seven times what the allocation did.** The prediction was the other way round: the label
returns a table of segments where it returned a string, it runs once per file per paint, and
that was the thing to watch. Measured in one process with both implementations loaded side by
side — `render.lua` is pure at load and pure at call with no notes in the options, so the two
trees' copies duel each other with the allocator taken out of the answer — `file_label` went
from **0.022 µs to 0.51 µs a call**, a factor of twenty-three on a number so small that three
hundred of them are **0.15 ms**. The whole walk went from 44.2 ms to 45.9 ms, so the other
**1.1 ms** is the two extmarks a header row gained: 211,200 marks to 211,800, `+0.28%`. Twice
a hundredth of the marks for four hundredths of the milliseconds, which is what an extmark
costs relative to a table with three strings in it.

**An injected file icon costs 0.3 µs a file on the diff and 0.2 µs a file in the tree, and
with nothing wired it costs a nil test.** The `file_icon` adapter is asked **601 times on a
three-hundred-file paint** — once per file the render draws, once more for the **sticky
header**'s own file, which is a second winbar's worth more in the split layout, and once per
file again for the **file tree**, which is built from the same file list one surface over. A
**file crossing** asks it **301 times**: the diff is not re-rendered there, so the winbar's own
file is the single call the diff makes, and the tree is rebuilt whole. That is the count that
moved when #217 landed — a crossing asked *once* before it — and it is why the tree's guard
matters more than the render's. Counted rather than argued, and with nothing wired every one
of those counts is **0**: there is no shipped glyph behind that adapter and therefore no
default implementation of it to call, which is the whole of the guarantee. It is a rule a
later edit cannot break by accident, where "we remembered not to call it" is one that can.

**The tree's build resolves what a paint cannot, and it is where #217's numbers were taken.**
`panel.build` at three hundred files is 0.48 to 0.51 ms and it is pure, so two arms duel inside
one process with the heap collected before every timing and the order reversed each round —
twelve rounds of twenty builds an arm, medians. A wired adapter reads **+0.05 to +0.06 ms**,
0.16 to 0.21 µs a file, against a null of ±0.005: ten times the floor, and resolved. One that
*raises* on every file reads **+6.6 to +6.9 ms**, 22 to 23 µs a file — the same figure the
render's own walk gave above, arrived at independently, which is the best evidence either
number is real. Three campaigns in three processes.

**Nothing wired pays what it paid, and the first draft of #217 did not.** Both versions of
`panel.lua` load into one process and duel each other, the way the label walk was resolved
above. The row as first written measured the glyph's width with `strdisplaywidth` whether or
not there was a glyph, and read **+0.04 ms, 0.14 µs a file**, against a null of ±0.002 — one
call across the vimscript bridge per file row, on the one surface that is rebuilt on every file
crossing as well as on every paint. Guarded behind the glyph, the same duel reads −0.002,
+0.003 and −0.013 ms across three campaigns against nulls of −0.002, +0.005 and −0.014: the
same number twice. A width of zero needs no call to reach.

**A crossing cannot resolve any of that, so the count is what is watched there.** `]f` at three
hundred files is 21 to 23 ms a press, and its own null — two unwired arms, twenty presses each
over files neither arm has drawn — reads −0.02, −0.12 and −0.57 ms across the same three
campaigns. The three hundred adapter calls a crossing gained are 0.06 ms of that, an order of
magnitude under the noise. Two duels over one range of files cannot be compared either: the
second one replays captures the first one paid to build, which read 9.5 ms against 22.4 ms
before each duel was given files of its own.

**The paint cannot resolve those calls, and the label walk can.** Same method as everything
else here — collect before every timing, alternate the arms, even rounds, medians. A paint at
three hundred files × three hundred lines is 112 to 188 ms across one run, and its own null
(two arms with nothing wired in either) read −0.1 ms once and −6.6 ms the next time, so
anything under about 7 ms there is drift wearing a number's clothes. Walking the three hundred
labels alone resolves it: **0.28 ms to 0.38 ms**, `+0.09` and `+0.10 ms` in two runs, against a
null of ±0.04. An adapter that *raises* on every file is the one figure worth remembering —
**+6.7 ms a paint**, twice, or about 22 µs a file for building an error object and unwinding a
`pcall`. That is a broken host configuration, it is under six percent of a paint, and it is
what buying "the review survives" costs.

**Nothing downstream of that separates from the machine.** A repaint at three hundred files is
about 81 ms and swings 73 to 128 between runs; `]f` is 12 ms a press warm and 21 ms cold, and
the crossing gains **one** `file_label` call in the unified layout and **two** in the split
one — half a microsecond and one microsecond, four to eight parts in a hundred thousand of a
press. Eight alternated processes an arm found no difference in either that a second campaign
reproduced: `perf.lua`'s own repaint line read `+17%` at sixty files in one campaign and
`−30%` at three hundred in the same one, which is what a single untimed shot is worth. Read
the counts, and read a duel run in one process; do not read one tier line twice and believe
the difference.

**Blob hashes are resolved in two batched calls**, `git hash-object` for working-tree
files and `git cat-file --batch-check` for everything behind a ref. One process per file
was, measurably, more expensive than all the treesitter work combined — on a 60-file diff
it was over half the open time.

**Whole-file content is fetched for everything one pass brings into view, in one
`cat-file --batch`.** The syntax pass needs the file behind a diff, and it needs it only as
that file comes near the window, so the fetch cannot be hoisted to open the way the blob
hashing is. What it can be is *widened*: `apply` decides which files are due before it paints
any of them, and the sides all of those need go out together. Measured on 300 files with two
changed lines each — the shape of a wide change, and the one `mkbig` grew a fourth argument
to build — opening the review fetched seventeen sides in one process instead of seventeen,
and reading it through cost seventy-one processes instead of two hundred and eighty-three.
Wall clock: open 316 ms → 198 ms, read-through 2.0 s → 0.9 s.

**The same change does nothing on a review of tall diffs, and that is not a bug in it.** A
file whose diff is three hundred rows is the only file near the window, so the batch holds
one spec and buys one process’s worth of nothing — measured, and a batch of one is not
slower than the `git show` it replaced. This is why `perf.lua` has a third tier: on the two
deep tiers the `file content` line reads the same whether content is fetched per file or for
all of them at once, so a regression that put the work back would be invisible there.

**`cat-file` runs no textconv filter and has no option to**, so a path with one attached
cannot be answered out of the batch — it would come back as exactly the bytes the filter
exists to hide. Such paths are left out and fetched by `git show --textconv` as before. The
rule is per path rather than per repository because one `*.png diff=exif` line in
`.gitattributes` should not cost a repository the batch for its source files. Finding them
starts from config, not from attributes: `textconv` is a config key (`diff.<driver>.textconv`)
while the driver is attached by `.gitattributes`, so a repository configuring none can have
no such path — which is nearly every repository, and it is what lets the common case skip
`check-attr` entirely. Both answers are memoised per checkout, because this is the scroll
path and a process per pass to learn "no filters here" costs more than the batch saves.

**The batch is a pre-warm, not a substitution, and that is what bounds its failure mode.**
Three kinds of side are simply absent from its answer — a working-tree side, a textconv
path, and anything a batch that died never reached — and the caller fetches those one at a
time exactly as it always did. So a batch that dies costs a pass its head start, not its
content: with every batch stubbed to return nothing, a 300-file review renders a
byte-identical set of syntax extmarks, from 300 single-file processes. That is what answers
the objection the change was raised with, that one process failing would take every file’s
content with it.

**Absent and `false` are different answers and the caller must keep them apart.** `false` is
git saying there is no blob on that side — an added or deleted file, or a rename read at its
post-image name — which is a real answer the single-file fetch spells `nil`; asking again
would buy the same nothing for a whole process. Absent is the batch not having covered the
side at all. Collapsing the two costs a process per added file per review, which is most of
what the batch was for on a change that adds a lot of files.

**The batch reads bytes, never text.** `vim.system`’s `text = true` replaces CRLF with LF,
and every `cat-file --batch` record declares its length in *bytes* with the next record
starting right after them — so that flag shortens a body mid-stream and hands every
following file the wrong content. Silently: the output still parses, and the highlighting is
still well-formed, on the wrong code. The translation is done per body afterwards instead,
where it cannot move a boundary, which is also what keeps the answer identical to the one
`git show` gives through `run`. For the same reason a record header it cannot measure stops
the walk rather than guessing a length — everything after it is left absent and fetched the
old way.

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

**The queued count resolves its own checkout, and the resolution is memoised on the
directory string.** A statusline asks `codereview.count()` on every redraw, and since the
queue became per checkout the number has to say which checkout it is about. Resolving that
with `git rev-parse` per redraw is not an option, and taking it from the pointer the queue
holds is what left the count reporting whichever checkout something else had last resolved —
right again only at the next capture, submit, copy or queue float. The count asks
`state.current_checkout` instead, and adds `count_in` to `loose_count`.

**Only the fall-through of that question costs anything, and it is the only half a memo can
help.** With a review open `current_checkout` answers from `V.root` and touches git not at
all, so the count is a field read and two table lengths — cheaper than any memo, and the
memo is not consulted at all on that path. Say that plainly rather than claiming the memo
covers the review case: what makes the count cheap with a review open is the review already
holding the answer. With no review open the working directory goes through
`git.root_cached`, one git process per checkout ever seen.

**Memoising on `DirChanged` is unsound, and this is verified rather than argued.** A tab
whose own local directory is deleted falls back to the global one, and Neovim fires no such
event when it does — see ADR-0008, which is the same finding a review's root rests on. A
cache keyed on that event is therefore stale in exactly the case it exists to handle. Keying
on the directory *string* survives it for nothing: the read returns the new directory and
memoises to the right checkout. What the string does not survive on its own is the window
before the tab is re-entered, when `getcwd()` answers `""` and `vim.uv.cwd()` answers nil —
`vim.system` raises on an empty cwd rather than reporting a failure, and the empty string
then reads as *outside every checkout* everywhere, which costs the count its number and
files every owned entry as an entry about somewhere else. `state.current_checkout` reads
`getcwd(-1, -1)` there, which is the global directory Neovim itself adopts a moment later.
The tab-local read is no help: `getcwd(0, 0)` still answers the directory that is gone.

**That memo never remembers an answer of "no checkout", and the shape is what enforces it.**
`roots[dir] = git.root(dir)` stores nothing when the answer is nil, so a directory inside no
checkout is asked again on every redraw. That is a deliberate price: the alternative is a
`git init` in the directory the reviewer is sitting in staying invisible until Neovim
restarts, which is a plugin that refuses to open a review of a repository that exists.
`git.root` itself is left uncached for the same reason — opening a review and capturing an
annotation both ask it, and both have to see a repository the moment there is one.
`count_spec` holds both halves: two counts outside a checkout must spawn two processes, and
the count must be about the new checkout the moment `git init` makes one.

**The count and the switch imply a behaviour neither of them tests alone.** After a
**switch** the review is on one checkout and the reviewer's own tab is still standing in
another, so the number beside the diff has to be the review's — it counts the queue a submit
from that review would send. Inside the review tab the `:tcd` holds the same answer, so a
count reading the working directory passes every case written from in there; one tab over it
does not. `count_spec`'s last block asks from the tab the reviewer never left, and guards
that the two checkouts have different numbers to report, or a working-directory read would
pass while being about the wrong queue.

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

## The scope a checkout was last reviewed in

**What is recorded is the spec that resolved the scope, and neither of the two things that
look like it.** A progress key is `name:identity`, and an identity is a resolved sha for
three of the five scopes, so nothing can resolve one again. A scope's own `name` is the spec
for four of them and the literal `"revspec"` for the fifth — so a record spelled that way is
right until a reviewer leaves a checkout on `HEAD~1`, which is one of the two cases the
feature exists for. What a return needs is the string `git.resolve_scope` was handed, and
both places that record it are already holding it. The pair of revspec cases in
`last_scope_spec` is what stops the name passing: one says the return is not the default, the
other says *which* revspec came back.

**It is written when a scope is entered, because there is no leaving to hang it on.**
`view.close` writes nothing, `state.persist` runs only from a mutation, and quitting runs
neither. A reviewer who cycles `gs` onto another scope, reads it, marks nothing and switches
away has still last reviewed that checkout in that scope — and a record hung on a mutation
gives them back wherever they last happened to toggle something. That is not a hypothetical:
it is the headline story of the ticket, and it is the only case in the spec that separates
the two moments.

**The consequence, which nothing else about opening a review ever had: an open now writes.**
A checkout that has been reviewed and never annotated now has a document, where before it had
none. It costs one file per checkout ever opened, and it moves the stamp the orphan sweep
ages against — a checkout whose review was merely opened looks recently written. The sweep
skips a checkout this session has read back anyway, so this makes it more conservative rather
than less. Its window is stated as *without a write or an open* for this reason; it said
*without a write* when it landed, and this is the slice that made that untrue.

**A remembered scope is a default, and a default must never turn an open into a refusal.**
A revspec whose branch has gone stops resolving; a `staged` scope emptied by a commit resolves
perfectly and holds nothing. Each of those hits one of `open`'s two early returns, and the
reviewer who asked to move to a checkout is left with no review at all — where the same
gesture, before any of this existed, always opened. Both fall back to the branch scope,
silently, and what actually opened is what gets recorded, so a return never reopens a scope
the reviewer was declined.

**That is not the rule an empty scope is otherwise declined under, and the two look
identical.** A switch to a checkout with nothing in its branch scope still says so and leaves
the review where it was (`switch_spec` owns that). There the reviewer named the scope and the
honest answer is to say so; here nobody named it in this session at all. The difference is
where the spec came from and not what it found, which is why it is decided at the point the
remembered spec is chosen rather than at the point the diff comes back empty. Deleting the
fall-back reds `last_scope_spec` and leaves `switch_spec` green, which is the shape of the
distinction.

**Only a switch consults it, and a restart is therefore not a return.** `:CodeReview` with
no argument still means the branch review. Reading the memory on every argument-less open is
one rule instead of two and was rejected: the front door's answer would drift with whatever
was read through it days ago, and a reviewer who looked at `HEAD~1` once would get it every
morning until they said `branch` out loud. It is held by a test rather than by this
paragraph — consulting the memory with no checkout named reds `trim_float_spec`, where a
review opened on `HEAD~1` is followed by argument-less opens whose `gc` then has no branch
review to list.

**A trim needs nothing here, and the reason is worth keeping.** A branch review's identity is
the merge base and does not move when a **trim** moves the pre-image, so a remembered
`"branch"` reads the same marks back under every trim — including one applied while the
reviewer was in another checkout.

## The queue and its checkout

**One id counter for every checkout, and seeding it per checkout is not the same thing.**
The counter is seeded from a checkout's **archive** as that checkout is read back, and it
only ever rises, so an id issued anywhere in the process is unique everywhere in it. A
counter *per* checkout is the obvious reading of "the queue is per checkout" and it is
wrong: a **loose** entry rides along in every checkout, so a fresh checkout issuing 1 puts
that id beside a loose entry restored as 1 — in one queue, on one screen. `remove` matches
the first entry carrying the id it is given, dropping an annotation resolves by anchor key
and then by id, and `archive.last` rejoins the two halves of one dispatched **batch** by
sorting on it. All three go quietly wrong, and the one a reviewer sees is `x` deleting the
other annotation. `checkout_spec`'s last block is that case: an empty archive beside a
loose entry holding id 1.

**The checkout an entry is about is derived from the entry, and the derivation has to be
resolved.** Its absolute path with its repository-relative path removed — no git call, for
an answer the entry has carried since it was captured. Two checkouts of one repository hold
the same repository-relative path, which is why the *absolute* one is what decides, and it
is also why a fixture for this needs one file at one path in both. `git rev-parse
--show-toplevel` answers with symlinks resolved and buffer capture realpaths to match, so
the two agree wherever the plugin built both — but an absolute path that arrived any other
way is about a checkout no root can equal, and the entry is then filed nowhere at all. It
is resolved through a memo keyed on the directory, which is the shape the **target**'s
working directory already uses and for the same macOS reason.

**The queue you are in is decided when an entry is added, not when it is written.** An
entry about another checkout — annotate a file that is not in the checkout you are in — is
kept in the queue you are in and filed under nothing: not here, because it is not about
here, and not there, because a queue nothing has read back must not be written over. It
goes out with the batch and it does not survive a restart, so it is said once, in the
queue's own wording. Silence there would be the failure this whole scoping exists to
remove. What stops producing such an entry is a review whose checkout is its own root
(ADR-0008), not this rule.

**The checkout everything resolves against is one question, and the review wins it.**
`state.current_checkout` is the only place that answers it: the open review's root when
there is one, and the working directory's checkout otherwise. The two agreed until a
**switch** existed, because a review could only be opened where the reviewer was standing —
so every working-directory read in the plugin was correct by accident, and four of them
became wrong on the same day. The queue's read-back is the loud one; `gb` reading the last
**batch**, a submit deciding which archive to write, and the composer relativizing an `@ref`
are the quiet three. Reading the *review tab's* directory instead looks equivalent and is
worse than reading the global one, because it is right until it silently is not — see
ADR-0008. A second copy of this question is a second chance to answer it differently, which
is why `ambient_root` was replaced rather than joined.

**A checkout's store is read back once per session, and re-opening a review is not a second
read.** The latch is per checkout, and once it is set that checkout's entries are in memory
and memory is the truth — leaving a checkout is lossless, so returning to one costs nothing
but pointing the queue back at it. `state.restore` used to re-read the store on every open
whenever the in-memory queue for that checkout happened to be empty, which was a second
read-back with a looser rule beside the real one. It cannot fire in ordinary use — the only
thing that empties the queue is a **dispatch**, which writes the emptied queue to the disk
in the same breath — but a spec that clears the queue by hand and re-opens is relying on it,
and `split_spec`'s note-count case was. A review opening now goes through
`state.ensure_queue_for`, the same read-back the resolved path uses, for the checkout it is
opening.

**Every path in the checkout listing is realpathed, and that is correctness rather than
tidiness.** A store's file name is a base name plus a hash of the *full path*, and
`git.root` answers with symlinks resolved. A listed path differing by one symlink therefore
gives that checkout a **second store**: the queue left in the first is not misfiled, it is
invisible, and nothing says so. git resolves these itself on the platforms this was written
against, which is exactly why the call has to be there — the alternative is a correctness
property held up by a platform's behaviour.

**The count a reviewer is shown is both lists, and the guard that reads one of them is a
different question.** `queue.count_in` answers "does this checkout already hold entries, so
do not restore over them", which the whole queue's count cannot answer — a bare note in hand
would block every checkout visited from ever reading its own store. `queue.count_for` is the
number, and it adds the **loose** entries back: asked of the owned half alone it reads 0 for
that same reviewer, with that same note still unsent. Two functions, one letter apart, and
the wrong one is silent.

**The store that needs no root is guarded by its own emptiness, not by the visited
checkout's latch.** There is one such store and every checkout shows what is in it. Read it
under the checkout's guard and moving to a second checkout queues every loose entry a
second time; read it under the session's latch alone and a checkout visited later never
gets them at all. Both halves of a restore therefore ask their own question, and the answer
is safe because every `queue.add` is followed by a write: a loose entry is on the disk
before anything can read that store again.

## Sweeping orphaned state

**The seven-day window is seven days WITHOUT A WRITE OR AN OPEN, not seven days missing.**
The stamp the age test reads is rewritten on every save. This said "only a mutation saves —
opening a review does not", which was true when the sweep landed and stopped being true one
slice later: recording the **scope** a checkout was last reviewed in writes the document when
a review opens, so an open now refreshes the stamp and closing one still does not. The
direction is safe — it makes a document harder to sweep, never easier, and a checkout this
session has read back is skipped anyway — but the sentence has to name it, because the window
is what a reviewer is being promised. So a checkout last written to *and last opened* nine
days ago and deleted a minute ago has **no protection at all**: the next **switch** sweeps
it, and whatever was unsent in it goes. The protection is proportional to how recently the
document was touched, which is not what a grace period against a directory that may come back
would give you.
This is a deliberate deviation from "kept for a while after its checkout disappears". The
alternative — a stamp written the first time a sweep finds the directory gone, swept only
once *that* is a week old — needs two sweeps seven days apart, and sweeps happen only on a
switch, so a store could easily never shrink at all. The precedent settles it: the store
that needs no root already deletes seven-day-old unsent annotations outright, with no
directory test whatsoever, so this rule is strictly less aggressive than one the plugin has
shipped for a long time.

**The parent test buys less than "an unmounted volume is unsweepable at any age" claims.**
It holds when the directory *above* the checkout was on the volume too, which is the
motivating case: macOS removes `/Volumes/<name>` when a volume ejects, so a checkout under
it has no parent and is never swept. It does not hold where a mount point survives as an
empty directory, which is usual on Linux: a checkout at `/mnt/disk/repo` is gone, `/mnt/disk`
is still there, and the sweep may take it. Keep the test — it is the only thing that
separates an absent volume from a removed checkout, and no grace period of any length can —
but do not read it as a guarantee.

**A sweep can never reach the state anyone already has.** A document written before the
checkout and the stamp existed carries neither, and the only way to gain them is to be saved
again — which cannot happen once the directory is gone. Every orphan that exists today is
therefore permanent. This is forced by the file name, which is a base name plus a hash of the
full path and cannot be read backwards. It also means the sweep removes nothing on the day it
ships, and can remove its first document no earlier than seven days later.

**The commonest way checkouts disappear is the one shape the sweep cannot touch.** Deleting a
whole project directory takes the repository and every checkout inside it, so every parent
goes too and nothing qualifies. Worktrees kept at `.worktrees/agent-a` are the same case. What
the sweep does reach is a checkout removed from *beside* a repository that stays — which is
what `git worktree add ../agent-a` produces, and it is the shape agent tooling actually
creates.

**The age is the document's, not its entries'.** A document can hold nothing but reviewed
marks and trims, and there is no entry in it to take an age from. The entries are stamped too,
but for a different reason and read by nobody here: an entry with no repository behind it has
carried a stamp since that store began ageing entries out, an owned one carried none, and
which store an entry came from was therefore readable off the entry — which is ADR-0002's
argument one field further along.

**The stored checkout is checked against the file name, not trusted.** It is a second copy of
what the file name already hashes, so a state directory carried between machines, or a file
written half way, names a path that means nothing here. Sweeping on a path that does not hash
back to its own file would remove a document belonging to something else entirely. What that
check refuses is a document filed under one checkout and naming another, and that is all it
refuses.

**What keeps the neighbouring stores out of a sweep is the shape test, not the file-name
check.** The store that needs no root and the drafts beside it share the directory and are not
checkout documents. Both are turned away for carrying neither the checkout nor the stamp,
before the file-name check has seen them — so the sweep needs no list of files to leave alone,
and the credit belongs to the shape test. The file-name check *would* refuse them, because
`M.path(nil)` does not raise but answers `v:null-<hash>.json`, which no document is ever filed
under; it simply never gets the chance. That was measured, after a comment here claimed
otherwise. The shape test is load-bearing in a stronger way too: delete it and a document
carrying a checkout with no stamp reaches the age test, where `now - nil` raises — an error on
every switch, not a document wrongly swept. `sweep_spec` keeps a document of that shape
because it is the only thing that holds the stamp half on its own; without it, reading a
missing stamp as age zero passes the whole file.

**A checkout this session has read back is never swept, and that is not an optimisation.**
Its entries are in memory whether its directory is there or not, and the next write about it
puts the document straight back. Sweeping it would report unsent work as destroyed while that
work sits in the queue and in the number a statusline shows — a figure wrong in both
directions at once. It is also what keeps a sweep away from the checkout under an open review,
whose behaviour when its directory disappears belongs somewhere else entirely.

## The checkout trail

A section of its own, because `docs/design-notes.md` has conflicted on every merge in this
stack.

**Only a successful open is a journey.** `view.open` declines an empty scope, an
unresolvable one and a failed diff, and it declines each of them *before* it closes
anything — the review the reviewer was reading is still on screen. A push made on the switch
rather than on the open therefore records a departure that never happened, and the checkout
it records is the one the reviewer is standing in. The picker then offers the row marked
`(current)` first and going back goes nowhere, which is two of this feature's rules broken
by a keystroke that told the reviewer only "No changes in scope".

**Arriving removes; leaving pushes. De-duplicating the push is not the same rule.** The
parent spec's wording — "pushing a checkout removes any earlier occurrence of it first" —
holds each checkout once and still leaves the checkout the reviewer is *standing in* on the
trail, ranked above one they have never opened. Removing the checkout being arrived at is
what makes the trail "where I have been" rather than "where I have been, plus here". It also
makes a duplicate push impossible without a second rule: a checkout can only be pushed by
being left, and can only be left after being entered, which removed it. Two checkouts cannot
tell the two rules apart at any step — `trail_spec` needs the fixture's third for it, and
deleting the removal reds the ordering case with `agent-a` ranked above `main`.

**A checkout that is gone and a checkout that refuses are opposite cases.** Gone: walk over
it, name it, carry on — consuming the entry is the point. There and refusing: consume
nothing. An agent worktree whose branch has been merged has an empty branch scope, so
refusing is the *ordinary* end state rather than an exotic one, and a trail entry once spent
cannot be got back — there is no forward, by design. An implementation that pops before it
opens loses that checkout permanently and says nothing about it.

**Skipping terminates because the trail is finite, not because anything is protected.** The
parent spec said it terminates because the checkout Neovim started in is never switched away
from and stays reachable. The first half is true — the global working directory never moves.
The second does not follow: that checkout reaches the trail by being left, like any other,
and its directory can be deleted, like any other. Every skip takes one entry off a finite
list, which is the real reason, and it means the bottom of the trail is reachable and has to
say so rather than be a press that does nothing.

**The trail is never persisted, and the only way to test that is a process that did not
build it.** `trail_child.lua` is inverted from every other child in the suite: it builds a
trail so the parent can find one absent, and it shares the parent's state directory so the
parent looks for one with that session's stores on the disk in front of it.

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
and an id is unique across the pair. It is seeded once per **checkout**, from that
checkout's archive, and the counter itself is still one counter — see "The queue and its
checkout" for what a counter per checkout costs.

**`since-batch` resolves through the same function every other scope does, and must.** The
temptation is a marker — a scope that says "the archive" and is special-cased downstream —
and it fails in three places at once: the diff parser is handed `git diff <before>`, the
blob hashing resolves `<before>:<path>` through `cat-file`, and the syntax highlighter
fetches whole-file content for the same spec — through `cat-file` too, and through
`git show <before>:<path>` for a path a batch cannot take. Every one of them needs
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

**A tab spawned from a tab that has a local directory inherits it; one spawned from a tab
that has none inherits nothing.** Measured, because a review's `:tcd` and the tab `<CR>`
opens out of it both ride on it:

```
tab with no local dir  -> :tabnew  haslocaldir=0, follows the global
tab with :tcd <B>      -> :tabnew  haslocaldir=1, cwd=<B>
```

So a file opened out of a review is already rooted in the review's **checkout** without
anything being set. It is set anyway, from `V.root`. An inherited value is a *copy* taken at
the moment the tab opened, from a source Neovim resets to the global directory with no event
when it is deleted (ADR-0008) — so the inheritance is right until the review's checkout goes
away, which is the one case any of this exists for. The same measurement is what says the
reviewer's own tab is unaffected: it never had a local directory, so nothing a switch does
reaches it, and `:tcd` rather than `:cd` is what keeps that true.

**A key bound in visual mode has to leave visual mode itself, and on a float whose `<Esc>`
closes it that is not free.** A Lua callback runs without leaving visual mode — which is what
lets it read `line("v")`, the end the reviewer began on, while the selection is still live —
so the mode is still there when the callback returns. Feeding a key back is what ends it, and
which key matters: the commit list binds `<Esc>` to close, so it leaves visual mode with
`<C-\><C-n>` and feeds it *unmapped* — the key that leaves a mode must not be a key the
surface has taken for something else. Measured on that float: with nothing fed the mode stays
`V` after the press; fed unmapped, the mode is `n` and the float is still open.

**A float's title and footer are clipped from the left when they outgrow its border**, with a
`<` in place of what was cut and no error anywhere. So a footer is a width budget and not a
sentence: the commit list is fifty columns at its narrowest, and its footer is exactly fifty
columns wide including the space at each end. A key added to it is paid for by a word taken
off another.

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

## A checkout deleted underneath a review

This section is #177's and stands on its own; the **orphan** sweep's rules are elsewhere,
because that is about *stored state* and this is about the *live review*.

**A relative path handed to any library is a working-directory read.** ADR-0008 says every
working-directory read inside a review is a bug, and this is the shape of it that no grep
for `getcwd` finds. `vim.filetype.match({ filename = path })` absolutises a relative name
through `vim.fs.abspath`, which is an `assert(vim.uv.cwd())` — so the syntax pass asking for
a language by a repository-relative path *raised*, on every paint and every cursor move,
once the review's checkout was deleted and the tab had no working directory left. The review
became unreadable with no git call anywhere near it. It joins from `V.root` now. Anything
else handing a path to a Neovim library owes the same join.

**`vim.uv.cwd()` is nil only while the reviewer stays in the tab.** Leave it and come back
and Neovim adopts the global directory, so the crash above heals itself and the wrongness
that replaces it is silent. That is why the two are asserted in different acts of
`frozen_spec` and why one measurement of "what does `getcwd()` say" answers neither
question on its own.

**Reconciling under a gone checkout does not fail — it lies.** `git.hash_worktree` stats
each path before it runs git, so with the checkout gone `present` is empty and it returns
`{}` *without spawning git at all*. Every working-tree annotation then compares "no hash"
against its capture blob, is flagged **stale**, and is written to the store that way; the
reviewer is told a count that is false about work they still have to send. This is why the
operations needing the checkout are refused rather than run with a warning in front of
them: the obscure failure was not an error message, it was a plausible number.

**The verdict is never latched, and that is a rule rather than laziness.** A stat says
"gone" for a directory that is briefly absent — an unmounted volume, an agent rebuilding a
worktree at the same path. Stored state needs a grace period because nothing re-asks it; a
live review is re-asked every time a key is pressed, so re-testing is both cheaper and more
correct than remembering. The announcement latch clears with it, or a reviewer who gets the
worktree back is never told it is usable again.

**A switch is the only way out, so its listing cannot be built the obvious way.**
`git.checkouts` is asked from the checkout the plugin is acting on, which is exactly the
directory that went — `vim.system` raises on a cwd that is not there, the list comes back
empty, and the reviewer is told no checkout can be opened. It is asked again from the global
working directory, which is never moved. Strictly that lists the repository the reviewer is
standing in rather than the one the dead review was of; nothing can list the latter, because
a linked checkout's git directory is reached *through* the directory that is gone. The
fallback is gated on the checkout being absent, not on the list being empty — an empty list
from a checkout that exists means git named nothing openable in *that* repository, and
answering it with another repository's checkouts is the cross-repository listing #171 rules
out.

**`open` resolving its own checkout was the other half of the stranding.** It read `getcwd()`
raw, which answers `""` in such a tab, and `vim.system` raises on an empty cwd rather than
reporting a failure — so `:CodeReview` said "not inside a git repository" to a reviewer
sitting inside one. It resolves through `state.current_checkout` now, which already carried
that fall-through. Note what this does *not* buy: with a review open, `current_checkout`
answers that review's root, so reopening cannot rescue a review whose own checkout is the
one that went. The switch is the gesture for that; this is for the tab afterwards.
