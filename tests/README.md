# Tests

```sh
make deps                                             # clone plenary into .tests/
make test                                             # the whole suite
make test-file FILE=tests/codereview/diff_spec.lua    # one spec, in-process
make lint                                             # stylua --check
make perf                                             # open-time report, not a gate
```

`make test` runs `PlenaryBustedDirectory` over `tests/codereview/`, which starts **one
Neovim per spec file**. Each process builds its own fixture repository and gets its own
throwaway state directory, so files neither share state nor need resetting between them.
The whole suite is about 600 cases in ~5 seconds.

Use `make test-file`, not `:PlenaryBustedFile` — that command spawns a child *without*
`-u`, which loads your real config instead of `tests/minimal_init.lua`.

## Layout

| Path | What |
| --- | --- |
| `minimal_init.lua` | The only runtimepath is this plugin plus plenary. Also redirects `XDG_STATE_HOME` and neutralises git config. |
| `helpers.lua` | Fixture builders, notification capture, extmark filters, anchor lookups. |
| `fixtures/*.sh` | Build a fixture repository from scratch at a given path. Take a target path; safe to run by hand. |
| `codereview/*_spec.lua` | The suite. Only `*_spec.lua` is collected. |
| `codereview/state_child.lua` | Spawned by `state_spec` — deliberately not a spec. |
| `codereview/viewless_child.lua` | Spawned by `viewless_spec` — deliberately not a spec. |
| `codereview/capture_child.lua` | Spawned twice by `capture_spec` — deliberately not a spec. |
| `codereview/norepo_child.lua` | Spawned twice by `norepo_spec` (write, then read) — deliberately not a spec. |
| `codereview/interactive_init.lua` | The config `interactive_spec` drives, picker stub included — deliberately not a spec. |
| `perf.lua` | Open-time report on a 60-file diff. Not part of `make test`. |

| Spec | Covers |
| --- | --- |
| `types_spec` | Configuring annotation types: defaulting, validation, grouping, a custom type end to end |
| `diff_spec` | Scope resolution, unified-diff parsing, rename/binary/untracked, blob hashing |
| `render_spec` | Anchor map, byte columns, navigation, collapse, panel, scope cycling |
| `syntax_spec` | Treesitter harvest/replay, caching, guardrails |
| `annotate_spec` | Targeting, cross-file clamp, deleted-line rule, types, drop, grouping |
| `payload_spec` | Grouping, `@ref` vs inline, out-of-tree fallback, staleness, submit |
| `state_spec` | Persistence across a real restart, blob invalidation, corrupt files, scopes a view never opened |
| `viewless_spec` | The queue with no review view open: persist, restore, submit, immediate send |
| `delivery_spec` | What a send adapter may report — nothing, true, false, a raise — the clipboard default, and the one condition that empties the queue |
| `capture_spec` | Annotating from an ordinary buffer: scope, types, declining one, blob, composer, diagnostics, restart, one queue, the immediate send |
| `staleness_spec` | Buffer annotations going stale: judged against disk at any scope, on restore, and in view |
| `norepo_spec` | Bare notes and files outside a checkout: the new kind, the global store, the age sweep |
| `panel_spec` | Tree build, chain compaction, folding, subtree review, navigation, picker |
| `focus_spec` | Queue-float focus across the async picker, submit closing the float |
| `interactive_spec` | The insert-mode leak, and where a completed or cancelled `@` leaves you, in a real pty-backed Neovim |

## Fixtures

Three repositories, each rebuilt from scratch by its script. They are not
interchangeable, and the assertions know which one they are looking at.

- **`mkfixture.sh`** — flat `src/`-only repo covering every file status at once:
  modified, deleted, added, renamed-and-edited, staged, unstaged, untracked, untracked
  binary, gitignored, and a file with no trailing newline on either side. Used by
  `diff_spec`, `render_spec`, `syntax_spec`, `annotate_spec`, `payload_spec`, `state_spec`,
  `viewless_spec`, `capture_spec`, `delivery_spec` and `interactive_spec`.
- **`mktree.sh`** — nested repo whose *shape* is the point: `apps/api/src` and
  `packages/shared/src` are single-child chains that must compact, `apps` has two children
  so it must not. Used by `panel_spec` and `focus_spec`.
- **`mkbig.sh`** — 60 files, 12k changed lines, for `perf.lua` only.

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
- **The tree fixture is structural.** `panel_spec` asserts on compaction and per-directory
  tallies, so adding or omitting one file changes what it expects. Regenerate with
  `mktree.sh` rather than hand-editing a fixture repo.
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
- **`interactive_spec` must keep its teeth.** To confirm it still reproduces the bug,
  remove the `BufEnter`/`WinEnter`/`InsertEnter` autocmd in `view.lua` and the
  `stopinsert` in `annotate.lua`'s `collect`: it must fail with `mode='i'`. A headless
  version of that test passes whether or not the fix exists, which is why it drives a pty.

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
- **Timing and wall clock.** `perf.lua` reports numbers and fails only past a deliberately
  loose ceiling. It is a report you read, not a gate; it is not in CI, where a shared
  runner would make it noise.
- **Windows.** The fixture scripts are bash and the suite assumes POSIX paths.
