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
The whole suite is about 1,590 cases in under ten seconds. A little over a second of that is
one deliberate wait in `trim_spec` — see "a cache is invisible unless the clock moved".

Use `make test-file`, not `:PlenaryBustedFile` — that command spawns a child *without*
`-u`, which loads your real config instead of `tests/minimal_init.lua`.

## Layout

| Path | What |
| --- | --- |
| `minimal_init.lua` | The only runtimepath is this plugin plus plenary. Also redirects `XDG_STATE_HOME` and neutralizes git config. |
| `helpers.lua` | Fixture builders, notification capture, extmark filters, highlight-group sets, anchor lookups. |
| `fixtures/*.sh` | Build a fixture repository from scratch at a given path. Take a target path; safe to run by hand. |
| `codereview/*_spec.lua` | The suite. Only `*_spec.lua` is collected. |
| `codereview/state_child.lua` | Spawned by `state_spec` — deliberately not a spec. |
| `codereview/layout_child.lua` | Spawned by `layout_spec` — deliberately not a spec. |
| `codereview/archived_child.lua` | Spawned by `render_spec` to archive a batch and turn archived entries off — deliberately not a spec. |
| `codereview/viewless_child.lua` | Spawned by `viewless_spec` — deliberately not a spec. |
| `codereview/capture_child.lua` | Spawned twice by `capture_spec` — deliberately not a spec. |
| `codereview/archive_child.lua` | Spawned by `archive_spec` to dispatch a batch under a **preamble** and exit — deliberately not a spec. |
| `codereview/norepo_child.lua` | Spawned twice by `norepo_spec` (write, then read) — deliberately not a spec. |
| `codereview/muted_child.lua` | Spawned eight times by `muted_spec`, one painted cell each — four on a token of a changed line for the muting, four on a token of a context line for the row a pane lights — deliberately not a spec. |
| `codereview/faded_child.lua` | Spawned three times by `faded_spec`, one painted cell each — deliberately not a spec. |
| `codereview/quiet_child.lua` | Spawned eight times by `quiet_spec`, one painted cell each, where two quiet states meet — deliberately not a spec. |
| `codereview/drafts_child.lua` | Spawned by `drafts_spec` to abandon a half-written note and exit — deliberately not a spec. |
| `codereview/interactive_init.lua` | The config `interactive_spec` drives, picker stub included — deliberately not a spec. |
| `codereview/trim_child.lua` | Spawned twice by `trim_spec` — once to trim two branches and exit, once to report what a later session's branch review holds — deliberately not a spec. |
| `codereview/winbar_child.lua` | Spawned four times by `split_spec` to read one cell of a pane's winbar — three inside the path for the muting, one on the file's added count for the color — deliberately not a spec. |
| `perf.lua` | Timing report at two sizes, 60 files and 300: what opening, scrolling, one `CursorMoved` and a repaint cost, plus the parse-time cost of intra-line spans reported on its own so a change moving that work into the render is visible. Not part of `make test`. |

| Spec | Covers |
| --- | --- |
| `types_spec` | Configuring annotation types: defaulting, validation, grouping, a custom type end to end |
| `diff_spec` | Scope resolution, unified-diff parsing, rename/binary/untracked, blob hashing |
| `render_spec` | Anchor map, byte columns, navigation, collapse, panel, scope cycling, archived entries on the diff — where they draw, the groups they draw in, what they cost a file they say nothing about, the flag that removes them and the key that overrides that flag in both directions, for a session — how a winbar is assembled from typed segments, with no review, no fixture and no repository behind it, and the unified layout's sticky header: the file under the cursor, the crossing, the rename spelled out, which group every piece of the bar draws in, what a narrow pane sheds and what the glyphs bought the path, the tree dismissed, a name carrying a `%`, and a review with no files |
| `split_spec` | The split layout: pane parity, anchor totality, filler, per-pane chrome and note mirroring — queued and archived alike — with no windows; then the binding, annotation parity against the unified layout, the two intersections nobody else owns, each pane's winbar naming its own side of a rename, and the painted cells proving that bar mutes with its pane and draws its counts in a group of the plugin's own |
| `layout_spec` | Switching layout: the anchor round trip, which pane receives the cursor, the filler fallback, centering, what a toggle leaves alone, and how long the choice lasts — including across a real restart |
| `spans_spec` | What is emphasized inside a changed line and how it is drawn: pairing, unequal runs, suppression and character boundaries at the parser; the priority band, background-only groups, byte offsets and both panes at the render; then the switch, the repaint and the entry that must not move |
| `syntax_spec` | Treesitter harvest/replay, caching, the row map the replay looks rows up in and everything that drops it, guardrails |
| `bounded_spec` | Emission bounded by the viewport: what a paint writes and what it leaves out, the bound it shares with the harvest, what a scroll adds and what scrolling back does not, both panes at once — on a diff taller than the window, guarded |
| `repaint_spec` | When a paint runs on a resize and when it must not: either event with nothing resized, in both layouts; a pane that really changed width; one terminal resize, which fires both events, repainting once; an event that arrives before anything moved; a window resized in another tab page; and the file tree summoned and dismissed |
| `annotate_spec` | Targeting, cross-file clamp, deleted-line rule, types, drop, grouping |
| `payload_spec` | Grouping, `@ref` vs inline, out-of-tree fallback, staleness, submit, and the **preamble**: above the header, the empty one that renders nothing, and the same arguments rendering the same message |
| `state_spec` | Persistence across a real restart, blob invalidation, corrupt files, scopes a view never opened |
| `archive_spec` | A dispatched batch kept across a real restart: both stores, the **preamble** each half carries, the snapshot and what minting it must not disturb, the bound, the id a new annotation takes, what dropping does on the anchor that holds both, and the documents written before the archive and before preambles existed |
| `archive_float_spec` | The surface over that record: which batch it decides went last, the two stores rejoined into one listing, how it draws an entry, the four things it refuses, the **preamble** it draws above the batch and will not let you edit, and the key that opens it from the diff and from the tree while the command still opens it from anywhere |
| `touched_spec` | Whether an archived entry's file has moved since its batch went: the reconciliation, the marker on the diff, the winbar tally, how a narrow pane fits a summary that tally is in, and the two switches that take it away with the entries, the three things left unjudged, which of three candidate blobs it is judged against, and that the queue's own staleness rule is untouched by any of it |
| `since_batch_spec` | The scope that diffs against the newest snapshot, inside a view: what it leaves out, syntax, navigation, collapse, reviewed marks, both layouts, the entry annotating in it produces, and where `gs` reaches it |
| `viewless_spec` | The queue with no review view open: persist, restore, submit, immediate send |
| `open_diff_spec` | The `open_diff` adapter: what it is handed across a scope whose post-image is a ref and one whose post-image is the working tree, from both panes and from the tree, and the key that exists only while it is wired |
| `delivery_spec` | What a send adapter may report — nothing, true, false, a raise — the clipboard default, the one condition that empties the queue, the draft an undispatched immediate send leaves behind, and the deliberate copy that is not a dispatch; then the **preamble**: `<C-a>` from the diff and from the float with and without a review, the empty one that submits anyway, the abandoned composer that submits nothing, and what a copy and a batch of one carry instead (nothing) |
| `capture_spec` | Annotating from an ordinary buffer: scope, types, declining one, blob, composer, diagnostics, restart, one queue, the immediate send |
| `staleness_spec` | Buffer annotations going stale: judged against disk at any scope, on restore, and in view |
| `norepo_spec` | Bare notes and files outside a checkout: the new kind, the global store, the age sweep |
| `faded_spec` | Every file but the one the cursor is in: what a review draws when it opens, the crossing, the hunk that changes nothing, the header left bright, both panes, a repaint that moves the rows, an empty review, the fade's family of blended groups beside the muting's, the switch — the two traps, `syntax = false` and a scroll past the last paint — and the cells three child processes read |
| `muted_spec` | The **pane** without focus: which pane is bright, the namespace that follows focus and the group each pane lights its row in, the **counterpart row** a muted pane lights and the family of one it comes from, the file tree never muted — bright with its row lit under every focus, and still muting the panes in both layouts when focus lands in it — a float changing nothing, a rebuilt pane and a re-summoned tree, `gA` repainting through a path that has never heard of the muting, the group left bright on purpose, the colorscheme change, both switches — and the cells eight child processes read |
| `quiet_spec` | Where **faded**, **dimmed** and **muted** meet: a queued entry and an archived one inside a faded file, the mark that draws them carrying no group of its own, the namespace a muted pane draws through holding no entry for the fade's family and a definition to fall back to — and the cells eight child processes read, at four colors one token can hold |
| `panel_spec` | Tree build, chain compaction, folding, subtree review, navigation, picker, dismissing and summoning the tree |
| `queue_float_spec` | How the float draws an entry: the bar down every row it owns, the boundary between two, notes kept and wrapped by display width, dropping from anywhere inside one, and the two keys that act on the whole batch — one closing the float, one leaving it open |
| `trim_spec` | The **trim**, at both of its seams: what a pick resolves to — every row of the listing read against git's own answer for the reading that row has always given, the oldest row at the merge base, the identity that does not move with the pre-image, the label, and the commit made afterwards that is in the review without the trim being touched; then the sets with a **hole** in them, which read from a pre-image that is built — the commit taken out of the middle, two that are not next to each other, the prefix reaching past the merge that must assemble nothing, the whole branch taken out, the commit no set can be built without, the same one succeeding beside what it depends on, the refs and the working tree the build must not touch, and the second resolve that finds the tree already built; then the **merge** on both sides of the rule that refuses it — taken out with an older commit left in, taken off the start of the branch with a hole above it, and a hole on a branch of its own with no merge on its first-parent line at all — and then what a reviewer sees of one, in a real view: the diff drawn again, the marks that survive and the one that does not, uncommitted and untracked work under it, syntax, navigation, collapse, both layouts, the entry annotating in it produces, what the queue still lists, where `gs` goes from it, and the pick that is refused — the sentence naming the commit and the file and no dependency, the store still holding the trim that was there, the review still on screen, and the same commit picked again beside the one it depends on; the merge picked out of the middle, whose sentence names no file at all, and the same merge picked off the start of the branch, which draws what the shipped trim drew; then what a session leaves behind, in a second copy of the fixture and a second process: the branch that opens where the reading stopped, the branch beside it holding its own, the rewritten commit that loses one and the sentence that says so once, the commit this repository does not have saying the same sentence beside one the branch still holds, and the detached `HEAD` that trims for the session, says it is not kept, and is gone in the session after |
| `trim_float_spec` | The float over the branch's commits: what a row carries and what it must not, the first-parent listing that leaves out what a merge brought in, the rows a cap would take away, the box on every row and the two directions `<Space>` moves it, the top row taking the whole branch in and out, the boxes a stored trim opens on, the cursor's opening row, `<CR>` applying a prefix and applying a set with a hole in it, the pick that is refused with the float left open on the row, the **merge** row checked with a commit older than it left in — the sentence about merges rather than about files, the float still open, the cursor still on it and the store still holding the trim that was there — the keys the footer names and the ones it does not, the rows still one each in a float too narrow to hold them whole, `gc` from the diff and from the tree, and the two refusals that open nothing; then the **size** on a row: absent while the float opens, filled from git's own answer for each commit, the merge row carrying its first-parent diff, the columns lined up on both edges down the listing, the counts colored at byte offsets on the subject that is not ASCII, every row sized on a branch of sixty-five, and the float closed inside the window before the answer lands; then the pair that moves between the checked rows -- both ends of a whole branch, a set with holes in it, and the empty set where both keys say so instead of moving -- and the keys the float leaves alone, pressed rather than looked up; then the **title** counting the boxes — the whole branch falling back to the single count, the count moving on a toggle with nothing applied and nothing stored, nothing checked said in a word, the total it refuses to carry, and what a refused pick leaves it saying — and the **height**, read off the window against `vim.o.lines` at two terminal sizes, one twice the other, because one size cannot tell a cap from a share; and where those meet the pair: one `<Space>` read on the title, on the footer and on where `]c` goes next, and a jump to a checked row a float on the floor has to scroll to |
| `focus_spec` | Queue-float focus across the async picker, submit closing the float, and where a submit under a **preamble** leaves the cursor |
| `drafts_spec` | A draft outliving the session it was written in, and the **preamble**'s own key: per repository, one slot outside a checkout, and never the bare note's |
| `queue_jump_spec` | Jumping from the queue float: where it lands, what it expands, and the three ways it cannot go |
| `queue_jump_panel_spec` | That jump with the tree dismissed, summoned, and never there — the one surface neither slice could test alone |
| `interactive_spec` | The insert-mode leak, and where a completed or canceled `@` leaves you, in a real pty-backed Neovim |
| `map_spec` | That `lua/codereview/CLAUDE.md` lists exactly the modules that exist — the only part of the map a machine can check |
| `checkout_spec` | The queue scoped to its **checkout**: two checkouts of one repository in one session — what each store receives, the queue left in the second read back rather than hidden, the return to the first, the annotation about a checkout you are not in that is filed nowhere and says so, and the loose entry whose id one counter keeps clear of |

## Fixtures

Five repositories, each rebuilt from scratch by its script. They are not
interchangeable, and the assertions know which one they are looking at.

- **`mkfixture.sh`** — flat `src/`-only repo covering every file status at once:
  modified, deleted, added, renamed-and-edited, staged, unstaged, untracked, untracked
  binary, gitignored, and a file with no trailing newline on either side. Used by
  `diff_spec`, `render_spec`, `syntax_spec`, `annotate_spec`, `payload_spec`, `state_spec`,
  `viewless_spec`, `capture_spec`, `delivery_spec`, `queue_jump_spec`, `queue_float_spec`,
  `split_spec`, `layout_spec`, `open_diff_spec`, `archive_spec`, `touched_spec`,
  `faded_spec`, `quiet_spec` and `interactive_spec`. Its
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
- **`mkcommits.sh`** — repo whose *history* is the point, and the smallest of the four: no
  file statuses, no binary, no rename. A branch of five commits over the default branch,
  one of them a merge that brings in a sixth commit from a side branch cut off master's
  tip. Used by `trim_spec` and `trim_float_spec`. Two rules need exactly that shape and can be seen in
  nothing else: a listing that dropped `--first-parent` draws the commit the merge brought
  in as a row of its own, and the merge base is a different commit from the oldest listed
  commit's parent, which is what resolving the oldest row has to notice. One commit on the
  branch rewrites the line an earlier one introduced, in the file that earlier one added,
  so it is the only commit here that cannot leave a review on its own — without it a
  refusal has nothing to refuse, which is "a filter test needs a fixture only that filter
  can reject". Its commits are dated days apart, as offsets back from the moment the script
  runs, so a relative date on a row is a fact a spec can check and never goes stale. One of
  the five subjects carries an em dash and is the only line in this fixture that is not
  ASCII: the commit list places every column right of the subject by measuring back from the
  end of the row in *bytes*, and across five ASCII subjects that lands exactly where
  measuring in display columns lands — so an assertion over either ruler passes whichever one
  the float used. Changing that subject's text moves the row-width and truncation
  assertions with it. The merge
  is a third rule of its own: it is free on the row that takes it off the start of the branch
  and refused with a commit older than it left in, and one history holding one merge is what
  lets a spec make both claims about one row. `trim_spec` builds a **second copy**
  for the trim a restart brings back, and cuts a `second` branch at `feature`'s tip inside
  it: two branches over one history is what "each branch keeps its own trim" needs, and
  neither branch the script builds can offer it — `lexer` has one commit of its own, so
  every trim on it resolves to the merge base, which is the review it already was. It builds
  a **third copy** for the opposite shape, and cuts a `flat` branch of three ordinary commits
  off master's tip inside it: a first-parent line with no merge on it, which is what "a branch
  with no merge in it is untouched by the merge rule" needs and which no branch over this
  history has.
- **`mkcheckouts.sh`** — one repository in three **checkouts** of it, and the only fixture
  whose checkouts are the point: `main` on master, plus `agent-a` and `agent-b`, each a
  linked checkout on a branch of its own. Used by `checkout_spec`. Unlike the other four it
  builds a plain directory holding the three rather than a repository at the path it is
  given, which keeps the whole fixture inside one `rm` — a checkout added beside the
  repository would be left behind — and leaves that path itself inside no repository. A
  second *copy* of a repository will not do: two copies are two repositories, and what is
  scoped per checkout can only be seen in checkouts that share one, which is also what
  `git worktree list` has to name for the picker built on it. `src/main.lua` is at the same
  repository-relative path in all three on purpose: an entry captured in one is then
  identical to an entry captured in another everywhere but its absolute path, which is what
  gives "the owning checkout is derived from the entry's own paths" something to fail on.
  Give the checkouts different file names and a rule reading the repository-relative path
  alone passes.
- **`mkbig.sh`** — files of a given size, half of every file rewritten. It takes counts as
  well as a path (`mkbig.sh <path> <files> <lines>`, defaulting to 60 and 200), so a caller
  asks for the height it needs rather than for a second script. `perf.lua` builds a 60-file,
  12k-line repository and a 300-file, 60k-line one per run; `bounded_spec` and `faded_spec`
  each build a 6-file one, about 1,800 rendered rows, which is the only fixture in the suite
  taller than a window and the margin around it. Nothing built from it is committed. It costs about a
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
- **The `gA` cases have to sit at the end of `render_spec`, and what they are keeping clear
  of is a winbar.** Opening a review is what runs `judge_archive`, and this file archives a
  batch part-way down — so the first case that opens a review of its own is also the first to
  put an untouched tally on the **sticky header**, and every case below it then reads a bar
  one segment longer than the one it was written against. The case that notices is `the
  sticky header on a pane that has to choose`: at 45 columns the summary sheds its spares
  first and then from its head, and one more segment on it is columns the path does not get.
  What reds is `spends the columns the shorter summary freed on the path` — the path keeps
  five columns fewer, which is the head of the pre-image name in a rename. Measured rather
  than predicted — a bare `view.reconcile()` above that block reds that one case, and nothing
  else in the suite, on a bar reading `○ ▾ …ua → src/newname.lua  +1 -1  ✓0/8 · ↺2`. Nothing
  in that failure mentions archived entries or the key, which is what makes it expensive: a
  case about `gA` breaks a case about narrow panes, and the two have nothing to say to each
  other. Moving the block up the file brings it back, and so does giving any earlier block a
  review of its own. The glyphs bought that bar about thirty columns, so what used to go at
  45 was the whole `0/N reviewed` tally; the trap is the same one, one notch further down.
- **A session-lived override can only be caught falling back to configuration once.** `gA`
  overrides `archived` for the whole process, so "unset means the configured value" is
  observable only while this process has not yet pressed the key. `render_spec`'s cases for
  it therefore run last in that file and in one order: the child process first, whose whole
  claim is what a *new* Neovim starts with, and then the direction a flag alone cannot go —
  configured off, key on — which is the last case the override is still unset for. Reversed,
  the configured value sits behind an override that agrees with nothing and both cases pass
  whatever the accessor does. Same shape as `layout_spec`'s restart cases having to run
  first. `archived_child.lua` archives a batch as well as pressing the key, for the reason
  `layout_child.lua` marks a file reviewed: without something the store genuinely carries,
  "the override did not come back" is satisfied by nothing coming back at all.
- **The tally is what notices a toggle that forgot to judge.** Turning archived entries off
  takes them off the diff whatever else the toggle skips, because a paint reads the switch —
  so every case in `render_spec` passes either way. The winbar is where it shows: the
  `untouched` segment is read off the view, and a paint drops it only when the *archive* has
  been written since the last verdict, which turning a switch off is not. Deleting
  `judge_archive()` from `view.toggle_archived` must red two cases in `touched_spec` and
  nothing at all in `render_spec`.
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
- **A spec that builds entries by hand has to resolve its checkout first.** A queue belongs
  to a **checkout**, and `queue.add` files an entry in the queue of the checkout the session
  is in — which the capture path has always resolved before it queues anything, and which a
  spec calling `queue.add` directly has not. An entry added before then joins the queue of
  nowhere and is invisible the moment anything resolves one, which reads as an empty queue
  rather than as a misplaced entry: `delivery_spec`, `archive_spec`, `archive_float_spec`,
  `queue_float_spec`, `touched_spec` and `since_batch_spec` all call `state.ensure_queue()`
  once for this, exactly as a session does. `viewless_child.lua` needs none, because it
  opens a review first.
- **A batch is the queue of the checkout you are in, so a spec cannot queue in one and
  submit from another.** `archive_spec`'s clean-tree block used to: it queued against the
  dirty fixture and then changed directory into a reset copy, because what it is really
  about is `git stash create` minting nothing. It now queues in the clean checkout. A spec
  that carries a queue across a directory change is asserting the corruption #173 removed,
  and it reports as `Queue is empty — annotate something first`.
- **Parallel runs can hide a whole spec file's failures, so judge on the exit code.**
  `PlenaryBustedDirectory` runs one Neovim per file and interleaves their output; a file
  whose cases failed can leave no `Tests Failed` line anywhere a `grep` will find, while
  every summary in the log still reads `Failed : 0`. The runner is still right — it fails
  when any child exits non-zero — so the exit code is the authority, and the way to find
  which file it was is to rerun with `{ sequential = true, keep_going = true }` and read the
  failures in order. This is the same trap as "the plenary tally lies", arriving through the
  scheduler instead of through ANSI codes.
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
- **A compose stub that answers one thing cannot tell a preamble from a note.** The same
  adapter is asked for both, so a stub returning one string leaves "the preamble reached the
  record" satisfied by an entry's note reaching it instead — and every assertion about where
  it is drawn passes on a row holding the annotation. `archive_child.lua` and
  `archive_float_spec` both branch on `ctx.preamble` and answer differently, which is the
  only reason those cases measure the preamble at all. Same trap as "a filter test needs a
  fixture only that filter can reject".
- **A batch dispatched under a preamble restores focus on a later tick.** `<C-a>` is a
  submit with a composer in front of it, and the submit schedules the focus restore every
  composer path ends with. A spec that dispatches and then opens the last-batch float has
  that restore land *after* the float is on screen — taking focus off it, so the keys the
  next case feeds go to the window behind. `archive_float_spec`'s `dispatch_under` drains
  with `vim.wait(50)` before returning, exactly as `focus_spec` drains between an annotation
  and the submit that follows it.
- **The archive lives in the same document as the queue, so "the file does not say it" is
  not "the queue does not hold it".** `delivery_spec`'s claim that a preamble never joins
  the queue was a search over the whole state file, which stopped being true the moment a
  dispatch archived one into that same file — for a reason the case is not about. It now
  decodes the document and searches the *entries*, queued and archived alike, which is the
  claim: a preamble is not an entry. Asserting over `doc.queue` alone would be weaker still,
  since a dispatched batch leaves it empty.
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
- **git config is neutralized.** Both the fixture scripts and `minimal_init.lua` set
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
  nothing — except on the file tree.** `cursorline` is set in `view_layout.window_opts` where
  a review window is built, and set again on the **panes**, as a function of focus, everywhere
  focus is decided. So a teeth check that removes it from the helper reds the tree's lit row,
  which the helper alone gives it, and nothing about the panes at all. Break the muting where
  focus is decided instead: mute against the *current* window rather than the view's latch,
  and the float cases go red; stop recomputing on `WinEnter`/`WinLeave`, and everything about
  which pane is bright does.
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
- **A lit row cannot be read on a changed line.** `line_hl_group` wins over `CursorLine` —
  measured, not assumed — so every added line, every deleted line and every header prints its
  own background whether or not the cursor is on that row. A painted cell taken there says
  the same thing lit and unlit, which makes it a reading of the line and not of the row. The
  four cells `muted_spec` reads for the **counterpart row** are on a token of a *context*
  line for that reason, and they move the cursor between that row and the file's header row
  rather than between two files: the **fade** would otherwise change the foreground under
  them, and the reading would be measuring two things at once. Same trap as "a filter test
  needs a fixture only that filter can reject".
- **A muted winbar cannot be told from a bright one by its text**, and a non-current window
  draws its winbar in `WinBarNC` whether or not anything is muted — so "the unfocused pane's
  bar is not `WinBar`" holds with the muted namespace never reaching the winbar at all. The
  path on that bar carries no group of the plugin's own, so that namespace covering `WinBar`
  and `WinBarNC` is the only thing making it recede with its pane, and the only assertion
  that can see it is the painted cell. `split_spec` spawns `winbar_child.lua` three times
  over one cell inside the path the bar names — focused, muted, and **muted off** — and it
  is the third that gives the second its teeth: without it the muted reading is only known
  to differ from `WinBar`, not to be a blend of anything. A fourth run reads a different
  cell of the same bar — the file's added count, which is where a group of the plugin's own
  is — because no reading of the path can say that group reached the screen, and no reading
  of the count can say the bar mutes: it is taken on the pane with focus, at the group's own
  brightness. Its window position is taken from `nvim_win_get_position`, which is the
  winbar's own row, and the offset into the bar is a display width **of what the bar draws**,
  from `nvim_eval_statusline`: the icon and the chevron in front of the path are multibyte,
  so a byte offset lands early, and a highlight marker is characters with no columns at all,
  so an offset measured off the option lands late.
- **An assertion about what the winbar says has to read what it draws.** The option holds
  markup: the file's `+N -M` is two segments with a marker between them, so
  `winbar:find("+1 -1")` is nil however the bar reads — and an `is_nil` written that way
  passes whatever the bar says, which is a case gone quiet rather than a case passing.
  `h.winbar` puts the option through Neovim's own statusline parser and hands back the text
  and the width a reviewer sees, and every assertion about what a bar says goes through it.
  The one that must not is `render_spec`'s escape case: `ja%%nus` in the markup is `ja%nus`
  on the screen, and there the markup *is* the claim. The case beside it reads the drawn bar,
  which is where "the name was drawn rather than expanded" can be seen at all.
- **`WinResized` is no use to a test.** It is fired from the main loop, so it lands after
  whatever changed the width has returned — and in a headless spec, which never pumps the
  loop, it does not land at all. Anything that changes a window's width has to repaint for
  itself; the resize autocmd is for the reviewer dragging a border, nothing else.
- **`VimResized` is not the same, and the difference decides what a resize test can drive.**
  Setting `columns` or `lines` from a script fires it *synchronously*, so a spec that changes
  either one with a review open has already run the resize callback by the time its next line
  runs. `nvim_win_set_width` fires neither event. `repaint_spec` uses both facts: it changes a
  pane's width outright where it wants to fire an event by hand, and it changes `columns`
  where it wants the real trigger — measured rather than assumed, because the first version
  of its terminal-resize case changed `columns` in the `describe` body and then counted the
  paints of two events that had nothing left to do, which reported *zero* repaints and read
  as the guard working perfectly.
- **The file tree cannot change size on its own, so its place in the resize record has no
  spec.** The record the guard compares holds all three review windows, because
  `paint_panel` builds the tree from its own window's width — but the tree can never be the
  only one that moved. Narrowing it hands the columns to a **pane** (measured: the tree at 34
  → 20 put the before pane at 37 → 51), and its height is the panes' height, since the three
  share a row. So the record differs on a pane whether or not the tree is in it, and taking
  the tree out of `dimensions()` reds nothing in the suite. That is a fact about where the
  windows are and not a case waiting to be written; the same shape as "no fixture is both
  tall and multilingual" above. Anyone who gives the tree a window arrangement of its own
  should take this bullet out and assert it.
- **A repaint test needs a seam a counter cannot fake, and change ticks are it.**
  `repaint_spec` reads `nvim_buf_get_changedtick` on the two panes and the file tree, because
  a paint rewrites each of those buffers exactly once. A counter on the view would measure the
  line it was written beside rather than the work, and would still read as correct if the
  paint stopped writing anything. Its first block spends three cases pinning that a paint
  really does move all three ticks, and by exactly one: without them the whole file is a row
  of assertions that nothing moved, which is also what a seam that stopped measuring looks
  like. Same trap as "a filter test needs a fixture only that filter can reject".
- **A resize record holding widths alone passes everything a diff is padded by.** Header
  padding and the winbar's fitting are the visible half of a pane's size and both are width,
  so a guard comparing widths only reads as complete. Emission is bounded by the *viewport*,
  which is a height: a window that grew taller shows rows whose marks were never written, and
  nothing repaints them until the reviewer scrolls. Dropping the height from `view.lua`'s
  `dimensions()` must red `repaint_spec`'s `a window that changed only its height` and nothing
  else in the suite — it left the whole suite green before that block was written.
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
  is bounded — the same trap as "centering is unobservable in a window taller than its
  buffer". `bounded_spec` builds `mkbig` for it, and its first case guards that the render
  really is taller than one paint can reach — as does the last block of `faded_spec`, which
  needs the same height for the same reason. Two of its cases judge against
  figures the implementation cannot move — how many of the render's marks reached the buffer
  at all, and whether the last file's marks did — because the rest derive their expectations
  from `syntax.viewport`, and a case that asks the bound where the bound is goes quiet when
  the bound goes away.
- **A fade built on the replay's row map passes every case that runs with highlighting on.**
  That map holds a span per file, which is what anything asking "where is this file drawn"
  reaches for first — and it is built only when `syntax` is on, so a rule reading it does
  nothing at all for a reviewer who turned highlighting off. A file's rows come from the
  render's `file_rows` instead. `faded_spec` opens one review with `syntax = false` for this
  reason alone: gating the fade on `V.syntax_rows` reds those two cases and nothing else in
  the suite.
- **A fade that renames rows once passes everything except a scroll.** Emission is bounded by
  the viewport, so the rows on screen at the moment of a crossing are not the rows a reviewer
  will be looking at a second later. Renaming what can be seen when a paint or a crossing runs
  satisfies every case made against a fixture that fits on screen; the rows scrolled into
  afterwards then arrive as the render drew them. `faded_spec`'s last block builds `mkbig`,
  crosses into the second file, and scrolls to the end of that same file so the margin below
  the window reaches into the third without the cursor ever leaving the second — the one case
  that reds when the fade is decided per paint rather than per mark.
- **A fade keyed to the crossing latch leaves a third file bright.** `V.current_file` starts
  nil and moves only on a crossing, while a *paint* asks the live question and can park the
  cursor somewhere the latch never hears about — a layout toggle does it. So "the file left"
  taken from the latch names a file that was already faded, and the file the rows on screen
  were really drawn for stays bright. The view records what the emission drew, beside the
  bands. Both traps above caught this while it was being written, and neither was written
  for it.
- **Two quiet states that meet are invisible to the spec of either one.** A queued entry and
  an archived one inside a faded file keep their own colors because the fade renames
  `hl_group` and `line_hl_group` and returns early for a mark carrying neither — an entry's
  colors are in the chunks of its virtual lines. A faded file inside a muted pane is faded
  once because the muted namespace links the groups `hl.groups()` names, and the faded family
  is not among them. Both were true from the day the fade landed and neither was measured:
  making the fade rename an entry's chunks reds seven cases, **all** of them in `quiet_spec`,
  and linking the faded family into the muted namespace reds two, both there. Nothing else in
  the suite notices either cut.
- **An absent namespace entry and a dead link draw different things.** A group a namespace
  does not name falls back to its global definition and draws it; a link that reaches no
  definition draws nothing at all. So "the muted namespace holds no entry for
  `CodeReviewFaded.CodeReviewAdd`" is only half the claim, and the half a cell cannot show:
  `quiet_spec` reads the global definition beside it and asserts it holds a color and is not
  itself a link. `hl.lua` writes a twin that loses its color back as a link to the group it
  blends for the same reason.
- **Two blends can only be counted apart when the two strengths differ.** A cell says how far
  a color was pulled, not how many times it was pulled, so with `muted.strength` equal to
  `faded.strength` a file faded once and a file merely muted print the same number — and
  "faded once, not twice" then passes for a fade that never ran. `quiet_spec` and
  `quiet_child.lua` run the window rule at 0.25 and the fade at 0.5, which gives one token
  four readings that are all different: `ec0000` on `004400` bright, `760000` on `002200`
  faded, `b10000` on `003300` muted, and `590000` on `001a00` had the two stacked. Their
  channels divide by four so all three blends are exact.
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
- **A focus assertion made on the tick an annotation restored focus is measuring that
  restore.** `annotate`'s `collect` schedules a focus restore of its own, and the `vim.wait`
  a later assertion spends waiting for focus to settle is what pumps it. So a block that
  queues an annotation and then submits on the same tick passes with the *submit's* restore
  deleted — measured twice while `focus_spec`'s preamble cases were being written, each cut
  applied on its own. Draining the loop between the two is what gives the second one teeth,
  and the case that needs it is the one where the batch was refused: a dispatch repaints,
  and the repaint puts focus back whether or not anything else does.
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
- **Centering is unobservable in a window taller than its buffer.** `split_spec` runs at 45
  lines, where the whole fixture diff fits on screen and nothing can scroll, so a `zz`
  assertion there passes with the `zz` deleted. `layout_spec` runs at 24 for that reason,
  and asserts centering as "a second `zz` here changes nothing" plus a guard that the window
  had scrolled at all.
- **Two bound panes given the same view command land somewhere neither was asked for.**
  `scrollbind` tracks deltas, so running `zz` in the after pane scrolls the before pane
  before the before pane has been placed, and its own `zz` then scrolls the after pane
  back — nine rows apart, neither centered. `place` lifts both bindings while it works and
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
  as do `🎉`/`🎈`, so a byte-wise diff emphasizes a trailing byte alone — a boundary inside
  a character. Replacing `diff.lua`'s `characters()` with a byte loop must red five cases,
  two of which come through the fixture. It rides on a line that file already changed, so
  no count anywhere moved. This is the same trap as "a filter test needs a fixture only that
  filter can reject".
- **The rename fixture cannot carry it.** `src/oldname.lua` was the obvious host and is the
  wrong one: lengthening its one changed line pushes the similarity index back under git's
  50% default, and the rename silently degrades into an add plus a delete. Three cases go
  green-to-red for reasons that have nothing to do with what was being tested. Keep that
  file ASCII.
- **A "both panes" assertion needs a pair that emphasizes both sides.** `src/main.lua`'s
  edit is a pure insertion, so its *deletion* carries no spans at all — asserting emphasis
  in both panes on its row passes with the before pane never drawing anything, because the
  case is then reading the after pane twice. `spans_spec` uses `src/nonl.md`, the fixture's
  only pair that changes something on each side.
- **The commit list's opening row can only be measured from a row that is not the top.** A
  fresh window puts the cursor on row 1, so `trim_float_spec`'s "opens the cursor on the row
  that takes the whole branch in or out" — the case made with no **trim** set — is satisfied
  by placing it there, by placing it nowhere, and by deleting every line that could place it.
  It was measured as toothless while it was the only such case, and it is kept because it is
  the claim a reviewer can see. What gives the rule teeth are the two blocks that reopen the
  float over a trim that is already set: one lands the cursor on the second row, and the one
  that takes a commit out with the older ones left in lands it on the *last* row, which is as
  far from a fresh window's as this fixture reaches. Deleting the `nvim_win_set_cursor` in
  `trim_float.lua` reds those and nothing else in the suite. Same trap as "a filter test
  needs a fixture only that filter can reject".
- **A guarantee that nothing is mapped over a key is worth nothing unless a spec presses
  it.** The commit list promises `/`, `n`, `N`, `gg` and `G`, and the natural case for that
  reads the buffer's mapping table and finds no entry for them. It passes against a mapping
  added later in another file, which is the only way that promise ever breaks — the float's
  own module is the one file anybody adding a key here would already be reading.
  `trim_float_spec` presses each of them and reads where the cursor landed, over a needle
  that matches two rows and no more: on a needle matching one row, `n` and `N` land back
  where the search already was and pass without being bound to anything. Measured by mapping
  `/` and `n` onto the float: four of the search cases red. The exact-set assertion beside
  them reds as well, and is kept for what it says about this file's own keys — it could not
  have caught the same mapping made anywhere else.
- **A jump pair pressed in the easy middle asserts the half that was never in doubt.** What
  `]c` and `[c` get wrong is the end of the run, where a wrap reads exactly like a working
  key, and the set with nothing in it, where the cheapest implementation moves the cursor to
  the first row and says nothing. So the block presses at the last checked row, at the newest
  one — where the row above is the one that takes the whole branch in or out, and is not a
  commit — and with every box cleared. Measured: making either direction wrap reds three
  cases, moving instead of reporting on an empty set reds two, and jumping to the next *row*
  rather than the next *checked* row reds four. The scattered set is what gives that last one
  its teeth: over a run with no hole in it, the two rules are one rule.
- **A run of rows pressed together has to be pressed over a *mixed* run.** "Make every row in
  the run the same" and "flip each row in the run" produce the same rows over a run that is
  uniform, so a block that drew its run over an untouched listing passes against either rule
  and asserts nothing about the one the key exists for. `trim_float_spec` takes two rows out
  first, and not next to each other, before it draws anything. The direction is the second
  half: a run drawn downward from a checked row reads the same under "follows the row the run
  started at" and under "follows the row nearest the top of the list", so one block draws its
  run *upward* from an unchecked row, which is the only shape that tells the two apart.
  Measured: flipping each row instead of making them uniform reds six cases, reading the
  direction off the top of the run reds the two in the upward block, and folding the
  `All commits` row into a run that reaches it reds one. The `<CR>` block stays green under
  all three, because the run it applies is uniform — which is the trap itself, seen from the
  other side.
- **A visual-mode key on this float has to be fed with the keys that draw the rows.** The
  press reads `line("v")` while the selection is still live, because `'<` and `'>` are not
  written until visual mode is left and say which row is *higher* rather than which one the
  reviewer began on — the same trap the review path's own visual capture is recorded under
  above. `trim_float_spec`'s driver feeds the motion and the press together, from the row the
  run starts at, so a run drawn upward is fed upward. It also asserts the reviewer is left in
  normal mode on a float that is still open: leaving visual mode means feeding a key back, and
  `<Esc>` — the obvious one — is this float's own key for closing.
- **A box a spec reads has to be read as a column, and which spelling means *in* has to be
  learned rather than written down.** `trim_float_spec` takes the box column's width from
  where the sha starts on a row, and takes the checked spelling off a float opened over a
  review with nothing taken out of it — where every box says *in* by definition. Writing the
  character down instead would leave the file asserting the float's implementation against
  itself, and would red on a change of glyph that no reviewer would call a defect.
  `trim_spec`'s own driver learns it the same way, because it presses `<Space>` to build a
  reading and cannot know which rows to press without it. `trim_child.lua` needs none of
  that, and says why: neither branch it trims has been trimmed before, so every box it meets
  is checked — which it asserts rather than assumes, because a box that started the other way
  would build the wrong reading for the process that reads it back.
- **A case about a row in the commit list has to say which listing it is reading.** The
  float opens on the commits and fills the size columns in when git answers, which is a later
  tick — so `trim_float_spec` holds two readings of the same buffer: `rows`, taken as the
  float opened and carrying no figure at all, and what `filled_rows` hands back after waiting
  for one. Assert a size against the first and the case reds; assert *what a row carries*
  against the second without listing the size and it reds the other way. The wait is a
  condition and never a sleep: a fixed drain that is too short passes because nothing was
  ever drawn, which is the same shape as a filter test with nothing to reject.
- **The float closed before its figures arrive is a window a spec has to land inside.** The
  answer is painted from a callback, so a float already wiped is a write into a dead buffer —
  and the case for it only measures anything while the close really did beat the answer. The
  block asserts that it did, off the rows it took at the open, rather than trusting the race
  it just won. It also cannot wait on the float it closed, because there is nothing left to
  observe: it opens a second float over the same branch and waits for *that* answer, which
  asked git the same question second and therefore lands no earlier. What a write into a dead
  buffer costs is a message and not a failure — an error thrown on a scheduled callback is
  outside every `pcall` the caller has — so the assertion is over `:messages`, cleared
  immediately before the close. Deleting the validity guard in `trim_float.lua` reds that one
  case and nothing else in the suite.
- **A refused merge takes two specs to pin, and each half passes while the other is broken.**
  The rule that refuses a **merge** above the leading run and the key that reaches it were
  built as separate slices, and neither file's cases red for the other's regression.
  Measured on the merge-row block in `trim_float_spec`, which presses `<Space>` on that row
  and `<CR>`: deleting the merge rule in `git.lua` so the merge falls through to the ordinary
  path reds the two cases about the *sentence* — the merge is then attempted, it collides, and
  the reviewer is told `conflicts in src/lexer.lua`, a file they did not write — while the
  float's three cases stay green, because a fall-through still refuses. Deleting the
  `trim_refusal` call in `trim_float.lua` so the pick closes and applies reds *those* three
  and leaves the sentence cases green, because `view.trim_to` says the same sentence one step
  later. The store's own case reds under neither: it takes deleting the guard in **both**
  places before anything is stored. Assert all four together or the pairing is untested by
  each file that looks like it covers it.
- **A trim is a hidden input to branch scope resolution, and it now reaches the disk.**
  `git.resolve_scope("branch", …)` reads `state.trim(root)`, which reads the repository's
  state document keyed by the branch checked out at that moment — so a spec that sets one and
  does not clear it hands it to every block below, *and* to any child process sharing the
  state directory, including blocks and children that open a review and expect the whole
  branch. `trim_spec` and `trim_float_spec` both reset it at the seams between their halves.
  Eight other call sites resolve `branch` with nothing set, and each spec process gets a state
  directory and a fixture of its own, so they stay correct — but a `branch` scope behaving
  oddly should send the reader to the stored trim before anywhere else.
- **"The full branch opened" cannot red on its own for a trim holding a commit that is gone.**
  The store drops such a trim and says so, but `resolve_scope` also refuses a count it cannot
  take — the guard #140 left — and a set it cannot anchor on, so the whole branch opens
  whether or not anything checked the trim. `trim_spec` keeps that case because it is the claim a reviewer can see; the teeth are
  in the sentence beside it, which reds the moment the check goes. Measured: deleting the
  check reds the sentence alone, and deleting the check *and* the count guard reds both. Same
  shape as "the commit list's opening row can only be measured from a row that is not the
  top".
- **A pre-image asserted by file name cannot tell the merge base from the oldest commit's
  parent.** Both hold `src/lexer.lua`, so a review reading from either one draws the same four
  paths — and `git diff --name-only` for the two is one list. What separates them is the
  *status*: against the merge base the branch **modified** that file, and against the oldest
  commit's parent it **added** it. `trim_spec`'s every-pick block compares `status<TAB>path`
  against `git diff --name-status` for exactly this reason, and the oldest row is the row that
  reds when the anchor is wrong. Same trap as "a filter test needs a fixture only that filter
  can reject", arriving through the expectation instead of through the fixture.
- **A pre-image is asserted by its delta and never by a tree object's identity.** A trim with a
  hole in it reads from a tree that is built, and the tempting assertion is the tree oid —
  cheap, exact, and it passes against a tree assembled the wrong way for as long as the
  expectation was assembled the same wrong way, which is what happens when the expectation is
  produced by a script that shares the implementation's rule. What a reviewer can see is which
  files the review draws and how much of each, so that is what `trim_spec` compares. Names
  alone are not enough either: taking out the commit that *added* `src/config_spec.lua` leaves
  that path in the review, because a kept commit changed it afterwards — the counts (`+1 -1`
  rather than the whole file arriving) are where a pre-image that took nothing out shows.
- **Two cases in the matrix exist because reasoning got the rule wrong twice.** A prefix trim
  reaching past the merge, and every commit taken out: both are ordinary readings, both are
  refused outright by the obvious rule of accumulating from the merge base, and a suite without
  them passes on a rule that breaks the shipped feature. Deleting the anchor in `git.lua`'s
  `pre_image` — building from the base and applying the leading run as well — reds 29 cases in
  `trim_spec`, and those two blocks are the ones that exist for it and nothing else. Measured.
- **The merge rule needs both of its answers, and one row can only give one of them.** A merge
  taken out with an older commit left in is refused; the same merge taken off the *start* of
  the branch is free, assembles nothing, and is the shipped `gc` flow on any branch with a
  merge in it. A block that asserts only the refusal is satisfied by a rule that refuses every
  set holding a merge, which breaks the trim that already ships — so `trim_spec` makes both
  claims about the one merge the fixture has, and adds a third selection where the merge is
  taken off the start *and* a commit above it is taken out, which is the only case that can
  tell "where the merge sits" from "the set holds a merge". Measured: that mutation reds those
  three cases and nothing else; asking the same question before a plain prefix has returned
  reds 32; not asking it at all reds the two that are the sentence. And "a branch with no merge
  in it is unaffected" is a claim no branch over this history can make, so it is made over a
  `flat` branch built for it.
- **A cache is invisible unless the clock moved between the two builds.** The tree a hole
  builds is cached on the repository, the base, `HEAD` and the set, and the claim is that a
  second resolve does not build it again. A commit object carries the moment it was minted, so
  two accumulations inside one second mint the *same* object — and "the second resolve produced
  the same commit" then holds with nothing cached at all. `trim_spec` waits past a whole second
  between the two, which is the only reason removing the cache reds that case; measured, it
  reds that one and nothing else in the suite. Same trap as "a filter test needs a fixture only
  that filter can reject".
- **A refusal decided on the word `CONFLICT` cannot be told from one decided on the exit
  status by any green suite.** Both refuse the fixture's dependent commit, because this git
  prints that word. What separates them is a git that words it differently, which no CI runner
  here has — so the case that has teeth is the mutation: making `merge_tree` ignore its exit
  status and take the first line of the output as a tree reds six cases in `trim_spec`, four of
  them about the refusal a reviewer reads. Run that mutation rather than trusting the green.
- **"The whole set was dropped" needs a survivor that would have narrowed the review.** A trim
  is a set, and any commit failing the ancestry check drops all of it — but a store that kept
  the commits that passed opens the full branch anyway whenever the survivors have a hole in
  them, because a set that is not a prefix resolves to nothing. So the surviving commit in
  `trim_spec`'s case is the *oldest* commit on the branch, which narrows the review on its own,
  and the case above it sets that commit alone and asserts the review really is narrower.
  Without that guard the block passes against per-commit survival.
- **"The trim was not written" cannot be read off a detached `HEAD` alone.** A trim set while
  `HEAD` is detached is kept in memory and never filed, and it is also never *read* from the
  document — so a later process opening the same detached checkout finds the whole branch
  whether or not anything was written. `trim_spec` spawns `trim_child.lua` in `read` mode for
  the claim a reviewer can see, which is that the session after this one opens the full
  branch; that has teeth against the implementation worth fearing, a trim filed under the
  root when there is no branch to file it under. Asserting the document's own shape instead
  would pin the store rather than the behavior, which no spec in this suite does.
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
- **A winbar assertion has to say how wide the pane was.** Both halves of the sticky header
  fit on a wide pane and neither one does on a narrow one, so "the summary is still there"
  and "the summary gave way" are both true depending on a number no assertion mentions.
  Worse, nothing resizes itself: `vim.o.columns` hands every new column to the *last*
  window rather than sharing them, and `WinResized` never lands in a headless spec — so a
  case that widens a terminal and asserts is usually asserting against the width it started
  at. `render_spec` sets the pane's width outright and asserts it took, and `split_spec`
  widens the terminal, levels the windows with `wincmd =`, repaints by hand and *guards*
  that the before pane really did end up wide enough to hold a revision and a path at once.
  Without that guard its rename cases pass by reading a bar the path never reached.
- **An ASCII winbar cannot fail the byte-padding bug.** The bar is padded to the pane's
  width by arithmetic, and by *bytes* it comes out a dozen columns short while every
  substring assertion in the suite still passes. `render_spec` parks on `src/newname.lua`,
  whose bar carries `○`, `▾`, `→` and `·` at once, and asserts the bar's display width is
  the pane's width exactly — with a second assertion that the bar really is longer in bytes
  than in columns, or the case is comparing two equal numbers and measuring nothing.
  Replacing the `strdisplaywidth` in `render.bar_width` with `#` — the one ruler both bars
  are padded and fitted by — must red it, and reds four cases across `render_spec` and
  `since_batch_spec`. Same trap as "an ASCII fixture cannot fail the byte-splitting bug".
- **A highlight marker is the same trap arriving from the other side.** `%#Group#` occupies
  several characters in a bar and no columns at all on the screen, so a ruler that counts it
  overshoots exactly as a byte count undershoots — and nothing on the bar carries a marker
  yet, so no assertion made against what the bar *says* can notice. `render_spec`'s winbar
  assembly block measures both spellings of one, the group a segment carries and a marker
  written into chrome, and asserts they weigh nothing. Deleting the stripping in
  `render.bar_width` reds one case; measuring the escaped literal instead of the drawn one
  reds two.
- **A string case cannot tell markup from a plausible string.** Every case in that block was
  written against the encoding the assembly emits, so a wrong one — `%{Group}` for
  `%#Group#` — would have taken the expectations with it and left the block green. One case
  hands the bar to `nvim_eval_statusline` instead and asks Neovim what it drew: the text
  with the marker gone, the group named in a highlight run, and a width that has to equal
  `render.bar_width`'s. Move the encoding and its expectation together and it is the only
  case that reds. It is also the only one in the block that needs a window at all, and any
  window will do — there is no review behind it.
- **The kinds on the bar are the view's choice, and only one case pins it.** `render.bar`
  escapes a literal and leaves chrome alone, which the pure cases prove — but *which* kind
  each piece of a bar is asked for is decided in `view.lua`, and no fixture in the suite
  holds a `%` in a path, a branch name or a scope label. `render_spec` reaches it through a
  picker stub instead: a **target** called `ja%nus`, on a wide pane, whose `%` must come out
  doubled. Marking the summary's segments as chrome reds that case and nothing else.
- **The sticky header's teeth are in the case with no tree.** With the tree open, a winbar
  hung off the tree's own repaint follows the cursor perfectly, so every case but that one
  passes with the crossing latch put back inside `view_panel.sync_panel`. Returning early
  from `view.lua`'s `follow_file` when `V.panel_win` is nil must red the tree-dismissed case
  in `render_spec` — it freezes on the file that was being read when the tree went away —
  and one case in `panel_spec`. That is the whole reason #103 moved the latch.
- **A set comparison passes when one set was never read.** `map_spec` matches the module
  map's rows with a pattern over the table's first column, so reformatting that column —
  dropping the backticks, say — silently yields no rows, and "no row names a module that is
  gone" then holds over nothing. It asserts both sides are non-empty before comparing them,
  which is the only reason that reformatting reds two cases instead of one.

## Deliberately not covered

- **Rendering as pixels.** Assertions are against the buffer, the anchor map and extmark
  metadata — never a screenshot. Highlight *groups* are checked; the colors a colorscheme
  resolves them to are not.
- **The `git diff` long tail.** Submodules, mode-only changes and combined (merge) diffs
  are not handled by the plugin and are not tested either way. They should degrade to a
  visible "unsupported entry" row rather than a stack trace; today neither behavior is
  pinned down.
- **Real adapters.** `send`, `pick_target` and `compose` are injected stubs throughout.
  That is the point of the seam — the plugin carries no opinion about the transport — but
  it means no test exercises a real agent handoff.
- **Horizontal scroll synchronization between panes.** There is nothing to cover: it is
  `scrollopt` that decides whether a bound window keeps its horizontal position in step,
  `scrollopt` is global, and the plugin deliberately does not set it. What *is* covered is
  that it stays untouched.
- **Timing and wall clock.** `perf.lua` reports numbers and fails only past a deliberately
  loose ceiling, and only at 60 files: the 300-file tier reports and cannot fail the
  command, because a second ceiling would be a second figure to tune per machine. It is a
  report you read, not a gate; it is not in CI, where a shared runner would make it noise.
- **Windows.** The fixture scripts are bash and the suite assumes POSIX paths.
