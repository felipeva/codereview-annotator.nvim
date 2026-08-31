-- The first half of wrap_spec's restart proof: a Neovim that folds long lines and exits.
--
-- Deliberately a separate process, for the reason `archived_child.lua` beside it is one.
-- "The override dies with the session" is a claim about what a *new* Neovim starts with, and
-- no assertion made in the process that pressed the key can settle it: a module local
-- cleared by hand says nothing about what reached the disk, and an assertion made here would
-- pass however the override were stored.
--
-- It also queues an annotation, which the store genuinely does carry. That is what lets the
-- next session prove the channel between the two is live before concluding the switch is not
-- on it: without it, "the choice did not come back" would be satisfied by nothing coming
-- back at all.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- wrap_spec with XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- Configured **off**, so that the state below is one only the key can have reached.
require("codereview").setup({
  wrap = false,
  syntax = false,
  compose = function(_, on_accept, _)
    on_accept(nil, "queued by the session that folded")
  end,
})

local config = require("codereview.config")
local state = require("codereview.state")
local view = require("codereview.view")

view.open("branch")
local V = assert(view.current(), "no review view opened")
assert(vim.wo[V.win].wrap == false, "the child did not open unfolded")

require("codereview.annotate").annotate("bug")
assert(#require("codereview.queue").all() == 1, "the child queued nothing for the store to carry")

view.toggle_wrap()
assert(config.wrap() == true, "the child never reached the folded state")
assert(vim.wo[view.current().win].wrap == true, "the child's pane is not folding")
assert(config.get().wrap == false, "the child wrote the configured value")

-- Resolved, because the state store is keyed on the root git answers with, and git answers
-- with symlinks resolved.
local root = assert(vim.uv.fs_realpath(fixture))
-- Printed so a failing wrap_spec can show what the session that pressed the key believed it
-- did. `nvim -l` sends this to stderr, not stdout.
print(("wrap on; state file: %s"):format(state.path(root)))
vim.cmd("qa!")
