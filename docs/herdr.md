# Integrating with herdr

A worked example of the three adapters, wiring a review batch to a Claude session running
in another [herdr](https://github.com/herdr) tab.

Nothing here is special-cased in the plugin — it is what `opts.send`, `opts.pick_target`
and `opts.compose` are for. Read it as the reference integration; the same shape works for
any transport.

## Why an agent in another tab is the hard case

A herdr agent is a **separate Claude process on its own IDE connection**. At-mentions
cannot reach it — they broadcast over the local session's WebSocket and would land in the
wrong Claude. So the payload has to be self-contained text, and every `@path` in it has to
resolve against *that agent's* working directory rather than this Neovim's.

That constraint is the reason `pick_target` hands back a `cwd`, and the reason refs are
resolved at submit time instead of when a note is captured.

## The wiring

```lua
{
  dir = vim.fn.expand("~/Codes/lua/codereview-annotator.nvim"),
  cmd = "CodeReview",
  opts = {
    -- Every adapter is wrapped in a closure so util.claude is not required while lazy
    -- evaluates this spec.
    send = function(payload, target)
      require("util.claude").deliver({ scope = "none", prerendered = true }, target, payload)
    end,
    pick_target = function(cb)
      require("util.claude").pick_target(cb)
    end,
    compose = function(ctx, on_accept, label)
      require("util.claude").compose(ctx, on_accept, label)
    end,
  },
}
```

`util.claude` here is a host-config module that already owns herdr routing, the `@file`
composer and the delivery ordering. The point of the adapters is that none of that is
reimplemented.

## `send(payload, target)`

`payload` is the fully rendered batch; `target` is whatever `pick_target` produced, or
`nil` for local delivery. Two flags in the example are load-bearing and neither is
obvious:

**`scope = "none"`** — the batch already carries every path, range and diff block inline.
Without it the delivery layer tries to prepend a context mention for a single file, which
a batch does not have.

**`prerendered = true`** — turns off the single-note reference deduper. That deduper
exists because pressing `@` while annotating the file you are looking at yields a
redundant whole-file ref; over a batch, though, repeated references to one file are
normal and correct, and deduping would silently strip every mention after the first.

Without a `send` adapter the payload goes to the `+` register instead, and the queue is
kept rather than cleared — nothing consumed it, so dropping it would lose the review.

## `pick_target(cb)`

Call back with a table carrying at least `short` (shown in the winbar and the queue
float's footer) and `cwd`. Call back with `nil` for "deliver locally".

**`cwd` is the contract that matters.** At submit time every annotation's absolute path is
re-resolved against it: inside that tree an entry becomes `@path#L12`, outside it degrades
to an absolute path with its code inlined. Get `cwd` wrong and refs silently stop being
emitted — the batch still arrives and still reads correctly, it just gets bulkier and
loses its clickability.

One sharp edge: `git rev-parse --show-toplevel` returns the canonical path, so on macOS a
repo reached through `/var/...` has a root of `/private/var/...`. If an agent reports the
symlinked form, the prefix match fails and every ref degrades. A `vim.uv.fs_realpath()` on
both sides fixes it.

## `compose(ctx, on_accept, label)`

Collect note text and call `on_accept(target, text)`. Without it the plugin falls back to
`vim.ui.input`.

`ctx` carries `scope = "none"`, a `label` for the prompt (`"Bug · src/main.lua:12"`),
`rel_path` and `file_path`.

**The plugin ignores the `target` argument you pass to `on_accept`.** If your composer
offers its own routing picker, that choice does not survive — routing is a property of the
whole batch, not of one note, and is set with `<C-t>` on the review buffer instead. This
is deliberate: a batch goes to one agent, and picking per note would raise the question of
what to do when two notes disagree.

## Which queue is which

There are two, and they share nothing.

| | This plugin | A host config's own queue |
| --- | --- | --- |
| Where | `lua/codereview/queue.lua` | e.g. `~/.config/nvim/lua/util/claude_queue.lua` |
| Fed by | `<leader>r` — the review view | `<leader>a` — buffer/visual annotation |
| Reviewed with | `require("codereview").queue()` | that config's own picker |
| Persisted | **yes**, with git blob hashes | typically not — session only |
| Survives a restart | yes; a moved file's note is flagged stale | no |

**The queue the review view uses is the plugin's own.** The `send` adapter is called with
an already-rendered batch, at the very end — it is a delivery hook, not a queue. Wiring
`send` to a host config's delivery path does not route anything through that config's
queue, and the two never see each other's entries.

That means annotations captured in the review view are only ever reviewed and submitted
through `:CodeReview`'s own float, and a host config's separate annotation flow keeps its
own list. Deliberate — it lets an existing flow keep working untouched — but worth knowing
before wondering why `<leader>a`'s queue looks empty after a review session.

Persistence is the practical difference. The plugin records the git blob each entry was
captured against, so after a restart a note whose file has changed comes back flagged
`⚠ stale` and never travels as an `@ref`; its code is inlined instead. A session-scoped
queue sidesteps that problem by not having it.

## Failure modes worth knowing

- **`herdr agent prompt` exits 0 even when it fails.** The error appears only in the JSON
  body, so an integration that checks the exit code alone reports success on failure.
- **`herdr` not on PATH** should degrade to local delivery, not an error on every submit.
- **A long batch is one prompt.** Delivery waits for the agent to settle
  (`--wait --until idle`), so a submit is not instant and the adapter should not block the
  editor on it.
