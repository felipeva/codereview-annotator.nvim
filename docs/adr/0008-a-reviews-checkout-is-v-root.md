# A review's checkout is `V.root`, never the working directory

A **switch** sets the review tab's working directory with `:tcd`, but nothing in the plugin
reads it back. `V.root` is what every operation resolves against. The `:tcd` is there for the
**host** — the LSP root, the gitsigns base, a relative `:e` — and for nothing else.

Trusting the working directory looked equivalent and is not. Neovim silently resets a tab's
local directory to the global one once that directory is deleted, and fires **no**
`DirChanged` when it does. An agent worktree pruned while its review is open therefore leaves
the tab pointing at a live and unrelated checkout, with no event for a cache to hang on. A
review that read the working directory would go on working, and be wrong.

## Consequences

Every working-directory read inside a review is a bug, including a convenient one.
`open_file` already joins from `V.root` (`view.lua:1299`) and is the pattern to copy.

A review whose checkout was deleted stays open and readable — it needs no directory to show a
diff it already holds — with only the operations that need git switched off.

The invariant that a review tab's working directory equals `V.root` is therefore a courtesy
to the host, not a thing the plugin may rely on. It can be broken with no warning at all.
