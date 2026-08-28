# A review's checkout is `V.root`, never the working directory

A **switch** sets the review tab's working directory with `:tcd`, but nothing in the plugin
reads it back. `V.root` is what every operation resolves against. The `:tcd` is there for the
**host** — the LSP root, the gitsigns base, a relative `:e` — and for nothing else.

Trusting the working directory looked equivalent and is not. Neovim silently resets a tab's
local directory to the global one once that directory is deleted, and emits nothing a cache
can hang on when it does. An agent worktree pruned while its review is open therefore leaves
the tab pointing at a live and unrelated checkout. A review that read the working directory
would go on working, and be wrong.

## What actually happens, measured

Neovim 0.12, macOS, with a tab's own directory deleted while that tab is current:

| moment | what fires | `getcwd()` | `getcwd(0, 0)` |
| --- | --- | --- | --- |
| the directory is deleted | **nothing at all** | `""` | the deleted directory |
| leaving that tab | `DirChangedPre` + `DirChanged`, scope `global` | the other tab's | the deleted directory |
| coming back to it | `DirChangedPre`, scope `tabpage` — and **no** `DirChanged` | the **global** directory | the deleted directory |

Read the second row before concluding an event exists to use: a `DirChanged` does arrive, and
it describes the *other* tab. The one that would say this tab's answer has changed — a
`DirChanged` at `tabpage` scope on re-entry — never arrives. `haslocaldir()` goes on answering
`1` throughout, and `vim.uv.cwd()` is `nil` for as long as the tab is not left.

So `""` is not the standing answer, and reasoning as though it were is the trap. Stay in the
tab and a working-directory read is empty and fails loudly; leave and come back and it names
a live, unrelated checkout, resolves, succeeds and is wrong.

## Consequences

Every working-directory read inside a review is a bug, including a convenient one.
`open_file` joins from `V.root` and is the pattern to copy.

**Including the reads that are not in this code.** Any call that absolutises a relative path
reads the working directory, and Neovim's own library does it silently: `vim.filetype.match`
puts a relative filename through `vim.fs.abspath`, which is an `assert(vim.uv.cwd())`. The
syntax pass asked it for a language by a repository-relative path and therefore *raised* on
every paint and every cursor move once the checkout was gone — a review made unusable with no
git call anywhere near it. Four slices read this ADR and none caught that, because the prose
above only warned about reads a grep for `getcwd` would find. It is not enough to keep
`getcwd` out of a review: a path handed to any library has to be joined from `V.root` first.

A review whose checkout was deleted stays open and readable — it needs no directory to show a
diff it already holds — with the operations that need the checkout refused by name. That
verdict is re-tested per operation and never latched, so a directory that comes back works
again at the next keypress.

There is exactly one place in the plugin where the two candidate answers differ, and it is
this one. `tests/codereview/frozen_spec.lua` is therefore where this ADR is proved rather
than restated; the mutation at the end of that file is the proof, and every other spec is
satisfied by an implementation that reads the tab and happens to agree.

The invariant that a review tab's working directory equals `V.root` is therefore a courtesy
to the host, not a thing the plugin may rely on. It can be broken with no warning at all.
