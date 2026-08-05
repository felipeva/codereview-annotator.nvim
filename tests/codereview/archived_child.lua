-- The first half of render_spec's restart proof: a Neovim that turns archived entries off
-- and then exits.
--
-- Deliberately a separate process. "The override dies with the session" is a claim about
-- what a *new* Neovim starts with, and no assertion made in the process that pressed the
-- key can settle it: a module local cleared by hand says nothing about what reached the
-- disk, and an assertion made here would pass however the override were stored.
--
-- It also archives a batch, which the store genuinely does carry. That is what lets the
-- next session prove the channel between the two is live before concluding the override is
-- not on it: without it, "the override did not come back" would be satisfied by nothing
-- coming back at all.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- render_spec with XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

require("codereview").setup({ archived = true, syntax = false })

local config = require("codereview.config")
local render = require("codereview.render")
local state = require("codereview.state")
local view = require("codereview.view")

-- Resolved, because the archive is keyed on the root git answers with, and git answers with
-- symlinks resolved.
local root = assert(vim.uv.fs_realpath(fixture))
local path = "src/main.lua"

state.archive_batch({
  {
    id = 1,
    type = "bug",
    kind = "file",
    path = path,
    key = render.file_key(path),
    note = "from the session that turned them off",
  },
}, "agent", root)

view.open("branch")
local V = assert(view.current(), "no review view opened")
assert(next(V.archived) ~= nil, "the child never drew an archived entry to turn off")

view.toggle_archived()
assert(config.archived() == false, "the child never reached the off state")
assert(next(view.current().archived) == nil, "the child is still drawing archived entries")
assert(config.get().archived == true, "the child wrote the configured value")

-- Printed so a failing render_spec can show what the session that pressed the key believed
-- it did. `nvim -l` sends this to stderr, not stdout.
print(("archived off; state file: %s"):format(state.path(root)))
vim.cmd("qa!")
