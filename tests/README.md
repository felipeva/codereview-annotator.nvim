# Tests

```sh
make deps                                             # clone plenary into .tests/
make test                                             # the whole suite
make test-file FILE=tests/codereview/diff_spec.lua    # one spec, in-process
make lint                                             # stylua --check
make perf                                             # timing report at two sizes, not a gate
```

`make test` runs `PlenaryBustedDirectory` over `tests/codereview/`, which starts **one
Neovim per spec file**. Each process builds its own fixture repository and gets its own
throwaway state directory, so files neither share state nor need resetting between them.
The whole suite is about 1,115 cases in ~6 seconds.

Use `make test-file`, not `:PlenaryBustedFile` — that command spawns a child *without*
`-u`, which loads your real config instead of `tests/minimal_init.lua`.

## Layout

| Path | What |
| --- | --- |
| `minimal_init.lua` | The only runtimepath is this plugin plus plenary. Also redirects `XDG_STATE_HOME` and neutralises git config. |
| `helpers.lua` | Fixture builders, notification capture, extmark filters, highlight-group sets, anchor lookups. |
| `fixtures/*.sh` | Build a fixture repository from scratch at a given path. Take a target path; safe to run by hand. |
| `codereview/*_spec.lua` | The suite. Only `*_spec.lua` is collected. |
| `codereview/state_child.lua` | Spawned by `state_spec` — deliberately not a spec. |
| `codereview/layout_child.lua` | Spawned by `layout_spec` — deliberately not a spec. |
| `codereview/viewless_child.lua` | Spawned by `viewless_spec` — deliberately not a spec. |
| `codereview/capture_child.lua` | Spawned twice by `capture_spec` — deliberately not a spec. |
| `codereview/archive_child.lua` | Spawned by `archive_spec` to dispatch a batch and exit — deliberately not a spec. |
| `codereview/norepo_child.lua` | Spawned twice by `norepo_spec` (write, then read) — deliberately not a spec. |
| `codereview/muted_child.lua` | Spawned four times by `muted_spec`, one painted cell each — deliberately not a spec. |
| `codereview/interactive_init.lua` | The config `interactive_spec` drives, picker stub included — deliberately not a spec. |
| `perf.lua` | Timing report at two sizes, 60 files and 300: what opening, scrolling, one `CursorMoved` and a repaint cost, plus the parse-time cost of intra-line spans reported on its own so a change moving that work into the render is visible. Not part of `make test`. |

| Spec | Covers |
| --- | --- |
| `types_spec` | Configuring annotation types: defaulting, validation, grouping, a custom type end to end |
| `diff_spec` | Scope resolution, unified-diff parsing, rename/binary/untracked, blob hashing |
| `render_spec` | Anchor map, byte columns, navigation, collapse, panel, scope cycling, and archived entries on the diff: where they draw, the groups they draw in, what they cost a file they say nothing about, and the flag that removes them |
| `split_spec` | The split layout: pane parity, anchor totality, filler, per-pane chrome and note mirroring — queued and archived alike — with no windows; then the binding, annotation parity against the unified layout, and the two intersections nobody else owns |
| `layout_spec` | Switching layout: the anchor round trip, which pane receives the cursor, the filler fallback, centring, what a toggle leaves alone, and how long the choice lasts — including across a real restart |
| `spans_spec` | What is emphasised inside a changed line and how it is drawn: pairing, unequal runs, suppression and character boundaries at the parser; the priority band, background-only groups, byte offsets and both panes at the render; then the switch, the repaint and the entry that must not move |
| `syntax_spec` | Treesitter harvest/replay, caching, the row map the replay looks rows up in and everything that drops it, guardrails |
| `bounded_spec` | Emission bounded by the viewport: what a paint writes and what it leaves out, the bound it shares with the harvest, what a scroll adds and what scrolling back does not, both panes at once — on a diff taller than the window, guarded |
| `annotate_spec` | Targeting, cross-file clamp, deleted-line rule, types, drop, grouping |
| `payload_spec` | Grouping, `@ref` vs inline, out-of-tree fallback, staleness, submit |
| `state_spec` | Persistence across a real restart, blob invalidation, corrupt files, scopes a view never opened |
| `archive_spec` | A dispatched batch kept across a real restart: both stores, the snapshot and what minting it must not disturb, the bound, the id a new annotation takes, what dropping does on the anchor that holds both, and a document written before the archive existed |
| `archive_float_spec` | The surface over that record: which batch it decides went last, the two stores rejoined into one listing, how it draws an entry, and the four things it refuses |
| `touched_spec` | Whether an archived entry's file has moved since its batch went: the reconciliation, the marker on the diff, the winbar tally, the three things left unjudged, which of three candidate blobs it is judged against, and that the queue's own staleness rule is untouched by any of it |
| `since_batch_spec` | The scope that diffs against the newest snapshot, inside a view: what it leaves out, syntax, navigation, collapse, reviewed marks, both layouts, the entry annotating in it produces, and where `gs` reaches it |
| `viewless_spec` | The queue with no review view open: persist, restore, submit, immediate send |
| `open_diff_spec` | The `open_diff` adapter: what it is handed across a scope whose post-image is a ref and one whose post-image is the working tree, from both panes and from the tree, and the key that exists only while it is wired |
| `delivery_spec` | What a send adapter may report — nothing, true, false, a raise — the clipboard default, the one condition that empties the queue, the draft an undispatched immediate send leaves behind, and the deliberate copy that is not a dispatch |
| `capture_spec` | Annotating from an ordinary buffer: scope, types, declining one, blob, composer, diagnostics, restart, one queue, the immediate send |
| `staleness_spec` | Buffer annotations going stale: judged against disk at any scope, on restore, and in view |
| `norepo_spec` | Bare notes and files outside a checkout: the new kind, the global store, the age sweep |
| `muted_spec` | The review window without focus: which window is bright, the namespace and the `cursorline` that follow focus, a float changing nothing, a rebuilt pane and a re-summoned tree, the group left bright on purpose, the colorscheme change, the switch — and the cells four child processes read |
| `panel_spec` | Tree build, chain compaction, folding, subtree review, navigation, picker, dismissing and summoning the tree |
| `queue_float_spec` | How the float draws an entry: the bar down every row it owns, the boundary between two, notes kept and wrapped by display width, dropping from anywhere inside one, and the two keys that act on the whole batch — one closing the float, one leaving it open |
| `focus_spec` | Queue-float focus across the async picker, submit closing the float |
| `queue_jump_spec` | Jumping from the queue float: where it lands, what it expands, and the three ways it cannot go |
| `queue_jump_panel_spec` | That jump with the tree dismissed, summoned, and never there — the one surface neither slice could test alone |
| `interactive_spec` | The insert-mode leak, and where a completed or cancelled `@` leaves you, in a real pty-backed Neovim |
| `map_spec` | That `lua/codereview/CLAUDE.md` lists exactly the modules that exist — the only part of the map a machine can check |

## Fixtures

Three repositories, each rebuilt from scratch by its script. They are not
interchangeable, and the assertions know which one they are looking at.

- **`mkfixture.sh`** — flat `src/`-only repo covering every file status at once:
  modified, deleted, added, renamed-and-edited, staged, unstaged, untracked, untracked
  binary, gitignored, and a file with no trailing newline on either side. Used by
  `diff_spec`, `render_spec`, `syntax_spec`, `annotate_spec`, `payload_spec`, `state_spec`,
  `viewless_spec`, `capture_spec`, `delivery_spec`, `queue_jump_spec`, `queue_float_spec`,
  `split_spec`, `layout_spec`, `open_diff_spec`, `archive_spec`, `touched_spec` and
  `interactive_spec`. Its
  dirty working tree is what makes a snapshot worth minting, so `archive_spec` builds a
  second copy and resets it to get a clean one. It already covers everything the split layout has
  to render, including the files that exist on only one side and the additions between
  context lines that produce filler — so that slice needed no fixture of its own. The
  layout toggle needed none either: `src/main.lua`'s deletion and its replacement collapse
  onto one row in the split layout, which is what makes every row below them move.
  `src/nonl.md`'s changed line is the fixture's only non-ASCII content, and it is the only
  line in the suite that can fail the byte-splitting bug — see "Things that bite".
- **`mktree.sh`** — nested repo whose *shape* is the point: `apps/api/src` and
  `packages/shared/src` are single-child chains that must compact, `apps` has two children
  so it must not. Used by `panel_spec`, `focus_spec` and `queue_jump_panel_spec`.
- **`mkbig.sh`** — files of a given size, half of every file rewritten. It takes counts as
  well as a path (`mkbig.sh <path> <files> <lines>`, defaulting to 60 and 200), so a caller
  asks for the height it needs rather than for a second script. `perf.lua` builds a 60-file,
  12k-line repository and a 300-file, 60k-line one per run; `bounded_spec` builds a 6-file
  one, about 1,800 rendered rows, which is the only fixture in the suite taller than a
  window and the margin around it. Nothing built from it is committed. It costs about a
  third of a second, which is why it is no longer kept out of `make test` — what is slow is
  opening a review on it at the sizes the report uses, not building it.

The sources are Lua and Markdown rather than TypeScript because Neovim core ships both
parsers **and** their `highlights` queries. `syntax_spec` therefore exercises the real
parse → capture → anchor → byte-column path on a bare Neovim, with no nvim-treesitter and
no compiler in CI. One typescript case marks itself `pending` when the parser is absent,
so the out-of-core language path is still checked locally without ever failing CI.

## Things that bite

- **Never reuse a state directory.** `minimal_init.lua` mints a fresh `XDG_STATE_HOME` per
  process, unconditionally. Reusing one makes assertions pass because a *previous run's*
  state was restored, and inheriting the real one writes into
  `~/.local/state/nvim/codereview/`, where you have genuine review state. Nothing in the
  suite writes outside a temporary directory.
- **`state_spec` is two processes on purpose.** Persistence is only meaningfully tested
  across a genuine restart; calling `state.load()` twice in one process proves nothing
  about what reached the disk. `state_child.lua` writes, the spec restarts and reads. Do
  not collapse it into one process.
- **So is `layout_spec`, and for the opposite reason.** "The chosen layout resets when
  Neovim exits" is a claim about what a *new* process starts with, which no assertion made
  in the choosing one can settle. `layout_child.lua` chooses the split layout and exits;
  the spec, which has not toggled anything yet, then opens a review and finds the
  configured layout. It also marks a file reviewed, because "nothing about the layout came
  back" would otherwise be satisfied by nothing coming back at all — the reviewed mark is
  what proves the store the two share is live. Its cases therefore have to run *first*,
  before this process has chosen a layout of its own.
- **`norepo_spec` needs a directory that is genuinely outside a checkout**, and asserts it
  rather than assuming it. If the temp directory ever sits inside a repository, every case
  about a "loose" file silently becomes a test of the ordinary in-repository path.
- **A filter test needs a fixture only that filter can reject.** `capture_spec` asserts
  that hints and info never ride along with an annotation. Those diagnostics originally sat
  on a line *outside* the captured range, so the range filter rejected them and the
  assertion passed with the severity filter deleted — it was measuring the wrong thing.
  They now sit inside the selection. Where two filters could reject the same fixture, place
  it so only the one under test can.
- **Visual-mode capture has to be driven through a mapping.** `capture` reads `mode()` and
  `line("v")` while the selection is still live, because `'<`/`'>` are only rewritten once
  visual mode exits. Calling the entry point directly after a selection therefore captures
  the whole file instead. Feed the keys and the mapping together (`h.feed("1GVj<F5>")`), as
  `annotate_spec` does for the review path.
- **The queue is restored once per session, so a second session means a second process.**
  `state.ensure_queue()` latches after the first read, which is what stops a statusline
  calling `count()` from hitting the disk on every redraw. Clearing the queue in-process
  therefore does *not* simulate a restart — the latch is still set, nothing reloads, and an
  assertion about restoring is measuring nothing. `capture_spec` spawns
  `capture_child.lua` twice for this reason.
- **The id an archived entry holds only collides across a restart *plus* a dispatch.** The
  queue's counter is module-level and starts at 1, so a one-process test of "a new
  annotation does not take an id the archive already holds" passes whether or not the
  counter is seeded — the process that dispatched is the process still counting.
  `archive_spec` therefore dispatches in `archive_child.lua`, restarts, and queues one
  through the ordinary capture path. It also asserts that the archive really does hold id
  1, or the case is satisfied by an archive with nothing low enough to collide with.
- **A dispatch no longer leaves the diff empty.** "No virtual lines are left" was the natural
  proxy for "the queue emptied and the view repainted", and it stopped being true the moment
  archived entries were drawn: the same remarks are still on screen, dimmed, which is the
  whole feature. `payload_spec` and `delivery_spec` now assert the view's projection of the
  *queue* is empty and that the rows below the code carry the archive's groups rather than an
  annotation type's — `helpers.virt_groups` is what reads them.
- **"With the flag off the diff renders exactly as today" needs the render from before
  anything was archived.** Asserting that no archived group appears passes with the flag
  ignored entirely and the projection merely empty, which is not the claim. `render_spec`
  keeps a deep copy of `V.render.marks` taken before the first `archive_batch` and compares
  the flag-off render against it, mark for mark. The same copy is what "a file carrying no
  archived entries costs nothing extra" is asserted against, filtered to the other files —
  and that comparison is guarded as non-empty, because an anchor lookup that stopped
  resolving would empty both sides at once.
- **The projection is memoised on a write count, so reaching past the accessors goes stale.**
  `archive.by_key` rebuilds only when `state.archive_writes` has moved, which `archive_batch`,
  `clear` and `clear_global` are what move. Deleting a state file directly — or writing one by
  hand — leaves a view drawing entries that no longer exist until the next dispatch.
- **A touchedness test needs a file the agent changed *and* one it did not.** With every
  file touched, every assertion passes with the blob comparison deleted — the same trap as
  "a filter test needs a fixture only that filter can reject". `touched_spec` dispatches a
  batch naming `src/main.lua` and `src/nonl.md`, edits only the first, and asserts against
  git that exactly one of the two moved before asserting anything about either. Neither is
  the renamed file: `git diff -M` names a rename by its *pre-image* path once the
  post-image is gone, so deleting `src/newname.lua` takes it out of scope instead of
  marking it touched, and the deletion case would then be measuring the scope rule.
- **Touchedness has three plausible reference points, and a clean fixture cannot tell them
  apart.** The blob an entry was *captured* with, the blob its batch was *dispatched* with
  and the blob at `HEAD` are one object for any file that is clean when the batch goes — so
  a spec whose only write happens *after* the dispatch passes whichever of the three the
  implementation reaches for, and nothing catches a refactor that swaps the dispatch blob
  for the capture blob. That swap is the exact merge this feature exists to refuse, and it
  reports a file the agent never opened as touched. `touched_spec`'s last block gives
  `src/fresh.lua` three distinct contents — committed, edited before annotating, edited
  again before submitting — leaves it alone afterwards, and guards that the three really are
  three shas before asserting it is untouched. Both mutations (specs built from `HEAD`, and
  `was` taken from the entry's own `blob`) must red four cases each, applied separately:
  applied together they mask each other.
- **`git stash create` on a clean tree returns nothing**, which is a case rather than an
  edge to assume away: the snapshot falls back to `HEAD`. `archive_spec` builds a second
  fixture and resets it hard, because the shared one is dirty by design and can never
  reach that branch.
- **"`since-batch` leaves out the work in flight" needs work to have been in flight.** The
  scope excludes what the snapshot already holds, so a fixture dispatched from a *clean*
  tree makes that assertion pass with the snapshot replaced by `HEAD` — there is nothing
  either one could differ about. `diff_spec` and `since_batch_spec` both assert that
  `src/routes.lua` is dirty against `HEAD` before asserting it is absent from the scope,
  and both edit a file only *after* the dispatch, so what is on screen is the response to
  the batch. Same trap as "a filter test needs a fixture only that filter can reject".
- **A scope that behaves like the others cannot be tested by reading the diff.** Nothing
  special-cases `since-batch`, so every claim about it is a claim about code no line of
  which mentions it — which is exactly why `since_batch_spec` drives syntax, navigation,
  collapse, reviewed marks and both layouts through it rather than trusting that. Its
  capture case compares the entry captured in `since-batch` against the one the *same line*
  produces in `worktree`, field for field bar the id: an entry that recorded which scope
  caught it would differ, and nothing weaker than a comparison would notice.
- **The two halves of one dispatch are rejoined by a stamp with one-second resolution.** A
  batch holding a bare note is written to both stores and matched back up by the `os.time()`
  both were stamped from, so a spec that submits in a loop can leave one batch's loose
  entries within reach of the next batch's stamp — and the surface then lists entries from
  two dispatches as one. `archive_float_spec` clears *both* stores between blocks
  (`state.clear` and `state.clear_global`) rather than trusting the clock to separate them.
- **Neither the scope's spec nor the float's archives more than one batch.** `since-batch`
  and the last-batch float both resolve "which batch went last", and with a single batch
  archived the head and the tail of the archive are the same record — so an accessor that
  returned the *oldest* leaves `since_batch_spec` and `diff_spec` entirely green. The case
  that catches it is in `archive_float_spec`: two dispatches, a file edited between them so
  the two snapshots are genuinely different shas, and the batch the scope resolved against
  looked up *by its snapshot* rather than by taking the head a third time.
- **A rejoin test needs the loose entry queued first.** Concatenating one store after the
  other happens to produce the right order whenever the repository entries were queued
  first, so a fixture in that order passes with the ordering deleted. `archive_float_spec`
  queues the bare note before the file annotation, gives both the *same* annotation type so
  the grouping cannot hide the order, and guards that their ids really are in that order.
- **A send adapter that raises takes the whole `describe` with it.** Plenary runs a
  describe body immediately, so an adapter that propagates its error aborts the block
  instead of failing one case — the `it`s below it never run. `delivery_spec` asserts on
  the queue and the notification *after* the submit returns, which is only meaningful
  because delivery catches the raise; remove that catch and the case reports as an error
  rather than a failure.
- **`nvim -l` sends `print` to stderr, not stdout.** A child spawned with `-l` that reports
  its result through `print` has to be read from `stderr`, or from both streams. Asserting
  against `stdout` alone silently never matches.
- **An empty environment variable does not reach a child.** `vim.system` drops an env entry
  whose value is `""`, so a child cannot tell "set to empty" from "never set". A flag a
  child branches on has to be absent or carry a real value — `capture_child.lua` declines a
  type when `CAPTURE_TYPE` is absent, not when it is blank.
- **git config is neutralised.** Both the fixture scripts and `minimal_init.lua` set
  `GIT_CONFIG_GLOBAL=/dev/null`. Inherited settings quietly change what a fixture means:
  `diff.renames = false` turns the rename case into an unrelated add plus delete, and
  `commit.gpgsign` makes building a fixture depend on a gpg agent.
- **Counts are derived from git, not hardcoded.** `diff_spec` cross-checks every file
  against `git diff --numstat` at runtime. Hardcoded totals went stale three times while
  this was being written. Keep them derived.
- **A dismissed panel is a wiped buffer.** Panel buffers are `bufhidden = "wipe"`, so
  closing the window destroys the buffer and every keymap bound to it. Nothing that drives
  the view's exported actions can notice: `panel_spec` therefore asserts that the tree
  comes back in a *different* buffer carrying the same mappings, and drives one of them
  through the keys. Without that, a panel that comes back with no keymaps at all passes.
- **A window option is reasserted downstream, so deleting the line that sets it proves
  nothing.** `cursorline` is set in `view_layout.window_opts` where a review window is built
  and then set again, as a function of focus, everywhere focus is decided — so a teeth check
  that removes it from the helper reds nothing that matters. Break the muting where focus is
  decided instead: mute against the *current* window rather than the view's latch, and the
  float cases go red; stop recomputing on `WinEnter`/`WinLeave`, and everything about which
  window is bright does.
- **No fixture is both tall and multilingual, so one line of the muting has no spec.**
  `view.lua` widens the muted namespace at two moments, and only one of them can be
  measured here. A paint that parses a file is reached by `muted_spec`'s scope change;
  a *scroll* that parses one can only differ from it when the newly parsed file's language
  has never been parsed before, and that needs a diff taller than the viewport margin
  holding two languages. `mkbig` is Lua only, `mkfixture` is short enough that everything
  parses on open, and `mktree` is neither. Deleting the call in `cursor_moved` therefore
  reds nothing — which is a gap in the fixtures, not a line to remove. Anyone giving `mkbig`
  a second language should take this bullet out and assert it.
- **The set of capture groups only ever grows, and it is module-level.** `syntax.lua`'s
  capture → group memo lives for the process, so once any block has opened a review over a
  scope holding Markdown, no later block in that file can be the first to resolve a Markdown
  group. `muted_spec`'s claim that a file parsed *after* its pane lost focus is muted too
  therefore has to run first, and it starts in a scope holding one Lua file before widening
  to one that holds both. Same shape as `layout_spec`'s restart cases having to run first.
- **`nvim__inspect_cell` is honest only on the first call a process makes.** Read the same
  cell twice in a row, with a forced `redraw!` before each, and the second answer differs
  from the first and is wrong — attributes belonging to something else on screen entirely.
  Measured, and it is why `muted_spec` spawns `muted_child.lua` once per cell instead of
  reading four cells in one process. Two more traps ride with it: the screen grid a headless
  Neovim keeps is **80x24 whatever `columns` and `lines` say**, so a window drawn past
  column 80 is drawn into cells nothing can read; and the cell has to be located with
  `screenpos`, because the change bar and the `│` separator are multibyte and a buffer
  column is not a screen column.
- **`WinResized` is no use to a test.** It is fired from the main loop, so it lands after
  whatever changed the width has returned — and in a headless spec, which never pumps the
  loop, it does not land at all. Anything that changes a window's width has to repaint for
  itself; the resize autocmd is for the reviewer dragging a border, nothing else.
- **Moving the cursor from a script does not fire `CursorMoved`.** Neither
  `nvim_win_set_cursor` nor a `normal! j` inside `nvim_win_call` raises it under `nvim -l` —
  measured rather than assumed, the same way `scrollbind` was. So anything claiming to cost
  what a keystroke costs has to dispatch the event itself: `perf.lua` moves the cursor and
  then calls `nvim_exec_autocmds("CursorMoved", { buffer = … })`, which runs the review
  buffer's own autocommand. Timing the move alone reports microseconds and misses every
  millisecond the reviewer actually pays.
- **A cached map only misbehaves once something has moved the rows.** The row map
  `syntax.apply` looks up is dropped by every paint, and an assertion made after a repaint
  that changed nothing passes with that drop deleted — every row still holds exactly what the
  old map claimed. `syntax_spec` collapses a file *above* the one it checks, guards that the
  rows below really did move, and only then asserts that every syntax mark still covers its
  own token. Same trap as "a filter test needs a fixture only that filter can reject".
- **A bounded paint is invisible on a diff that fits on screen.** Only the rows near the
  window are written into a pane's buffer, so every extmark assertion elsewhere in the suite
  runs on a fixture small enough to sit inside that band and passes whether or not anything
  is bounded — the same trap as "centring is unobservable in a window taller than its
  buffer". `bounded_spec` is the one spec that builds `mkbig`, and its first case guards
  that the render really is taller than one paint can reach. Two of its cases judge against
  figures the implementation cannot move — how many of the render's marks reached the buffer
  at all, and whether the last file's marks did — because the rest derive their expectations
  from `syntax.viewport`, and a case that asks the bound where the bound is goes quiet when
  the bound goes away.
- **The tree fixture is structural.** `panel_spec` asserts on compaction and per-directory
  tallies, so adding or omitting one file changes what it expects. Regenerate with
  `mktree.sh` rather than hand-editing a fixture repo.
- **"The tree followed" needs the tree to have been somewhere else first.** It repaints only
  when the diff cursor crosses into a *different* file than the one it last painted for, so
  an assertion that it points at a file it was already pointing at passes with nothing
  syncing it. `queue_jump_panel_spec` puts the highlight on another file, and asserts that
  guard, before every case that claims a jump moved it.
- **An immediate send asks for its target before the composer exists.** Nothing is
  floating between the two, so a picker stub that answers inline collapses the whole
  interaction into one tick and no test can observe the order. `composer_spec` holds the
  picker's callback and fires it by hand, which is also the only way to assert that the
  composer had not opened yet.
- **A picker stub that answers inline cannot test insert mode.** The composer's `@` is an
  insert-mode mapping, so a stub that calls back before returning never left insert — and
  an assertion that insert mode *comes back* then passes with nothing restoring it.
  `interactive_init.lua`'s file picker opens a window, takes focus, `stopinsert`s and
  answers a tick later, which is the shape a real picker has and the only one that
  reproduces the defect. `composer_spec`'s file picker still answers inline on purpose: it
  is asserting text and cursor, not mode.
- **`scrollbind` and `cursorbind` follow motions, not the API.** They *do* work in a
  headless Neovim, which was measured rather than assumed: a `normal!` motion, a `<C-e>`
  and fed keys all propagate to the bound window, and `nvim_win_set_cursor` does not.
  Driving a binding assertion through the API therefore passes whether or not the binding
  exists — the failure mode `interactive_spec` exists to avoid — so `split_spec` drives
  `normal!` and asserts the *other* pane followed. The cut that bites is in
  `view_layout.lua`'s `place`: turning its closing `bind_panes(true)` into
  `bind_panes(false)` must fail three cases in `split_spec` and one in `layout_spec`.
  `show_before_pane`'s own two `vim.wo` lines are belt and braces, and deleting them fails
  nothing — `M.open` ends in `place(1)` and every jump goes through `place`, so the binding
  is established there regardless of what built the pane. The same asymmetry is why the view
  sets both panes' cursors explicitly instead of trusting the binding to carry one across.
- **Two panes that were never moved apart cannot be seen coming back together.** The first
  version of "both panes hold their alignment across every repaint" passed with `resync()`
  deleted, because nothing had knocked them out of step: both sat at line 1 throughout. It
  now lifts the binding, moves one pane, puts the binding back — which is the state a
  repaint that changed the line count leaves behind — and only then repaints. A guard case
  asserts the panes really did diverge, so the assertion cannot quietly stop measuring.
  Note that `zt` in one pane propagates through `scrollbind`, so it is no use for pulling
  them apart; that was the first attempt and the guard caught it.
- **A toggle from a row both layouts agree about proves nothing.** Most of the fixture
  renders at the *same* row in both layouts, because only files below a collapsed
  deletion-and-replacement pair move at all — `src/main.lua`'s deleted line is row 12 in
  each. A round trip started there passes with the anchor scan replaced by "keep the row",
  which is the bug. `layout_spec` starts in `src/newname.lua` and `src/routes.lua`, both
  below that collapse, and guards every round trip by asserting the row really did change.
- **Centring is unobservable in a window taller than its buffer.** `split_spec` runs at 45
  lines, where the whole fixture diff fits on screen and nothing can scroll, so a `zz`
  assertion there passes with the `zz` deleted. `layout_spec` runs at 24 for that reason,
  and asserts centring as "a second `zz` here changes nothing" plus a guard that the window
  had scrolled at all.
- **Two bound panes given the same view command land somewhere neither was asked for.**
  `scrollbind` tracks deltas, so running `zz` in the after pane scrolls the before pane
  before the before pane has been placed, and its own `zz` then scrolls the after pane
  back — nine rows apart, neither centred. `place` lifts both bindings while it works and
  puts them back, which does not scroll anything. `zt` happens to be self-correcting from
  an aligned start, which is why no file-jump assertion caught this first.
- **Reviewed marks and expansion are per scope, so setting them before a scope change
  loses them.** `set_scope` swaps `V.reviewed` and `V.expanded` for the new scope's tables.
  A fixture built and *then* switched to another scope arrives empty, and a "nothing
  changed" assertion over it compares two empty tables and passes regardless.
- **An ASCII fixture cannot fail the byte-splitting bug.** Intra-line spans are computed
  over *characters*; the obvious implementation splits a Lua string with a pattern, which
  splits by byte, and it passes every assertion an ASCII line can make. `src/nonl.md`'s
  changed line therefore carries `café 🎉` against `cafè 🎈`: `é`/`è` share a leading byte,
  as do `🎉`/`🎈`, so a byte-wise diff emphasises a trailing byte alone — a boundary inside
  a character. Replacing `diff.lua`'s `characters()` with a byte loop must red five cases,
  two of which come through the fixture. It rides on a line that file already changed, so
  no count anywhere moved. This is the same trap as "a filter test needs a fixture only that
  filter can reject".
- **The rename fixture cannot carry it.** `src/oldname.lua` was the obvious host and is the
  wrong one: lengthening its one changed line pushes the similarity index back under git's
  50% default, and the rename silently degrades into an add plus a delete. Three cases go
  green-to-red for reasons that have nothing to do with what was being tested. Keep that
  file ASCII.
- **A "both panes" assertion needs a pair that emphasises both sides.** `src/main.lua`'s
  edit is a pure insertion, so its *deletion* carries no spans at all — asserting emphasis
  in both panes on its row passes with the before pane never drawing anything, because the
  case is then reading the after pane twice. `spans_spec` uses `src/nonl.md`, the fixture's
  only pair that changes something on each side.
- **Two entries of different types are separated by a group, not by a row.** The queue
  float's boundary between entries is one blank row carrying no bar, and an assertion about
  it needs two entries of the *same* annotation type — give them different ones and what
  sits between them is a blank row plus a group heading, so the assertion is measuring the
  gap between groups instead. `queue_float_spec` keeps a third entry of another type for
  the claim that actually is about types.
- **`interactive_spec` must keep its teeth.** To confirm it still reproduces the bug,
  remove the `BufEnter`/`WinEnter`/`InsertEnter` autocmd in `view_layout.lua` and the
  `stopinsert` in `annotate.lua`'s `collect`: it must fail with `mode='i'`. A headless
  version of that test passes whether or not the fix exists, which is why it drives a pty.
- **A set comparison passes when one set was never read.** `map_spec` matches the module
  map's rows with a pattern over the table's first column, so reformatting that column —
  dropping the backticks, say — silently yields no rows, and "no row names a module that is
  gone" then holds over nothing. It asserts both sides are non-empty before comparing them,
  which is the only reason that reformatting reds two cases instead of one.

## Deliberately not covered

- **Rendering as pixels.** Assertions are against the buffer, the anchor map and extmark
  metadata — never a screenshot. Highlight *groups* are checked; the colours a colorscheme
  resolves them to are not.
- **The `git diff` long tail.** Submodules, mode-only changes and combined (merge) diffs
  are not handled by the plugin and are not tested either way. They should degrade to a
  visible "unsupported entry" row rather than a stack trace; today neither behaviour is
  pinned down.
- **Real adapters.** `send`, `pick_target` and `compose` are injected stubs throughout.
  That is the point of the seam — the plugin carries no opinion about the transport — but
  it means no test exercises a real agent handoff.
- **Horizontal scroll synchronisation between panes.** There is nothing to cover: it is
  `scrollopt` that decides whether a bound window keeps its horizontal position in step,
  `scrollopt` is global, and the plugin deliberately does not set it. What *is* covered is
  that it stays untouched.
- **Timing and wall clock.** `perf.lua` reports numbers and fails only past a deliberately
  loose ceiling, and only at 60 files: the 300-file tier reports and cannot fail the
  command, because a second ceiling would be a second figure to tune per machine. It is a
  report you read, not a gate; it is not in CI, where a shared runner would make it noise.
- **Windows.** The fixture scripts are bash and the suite assumes POSIX paths.
