-- The first half of layout_spec: a Neovim that chooses the split layout and then exits.
--
-- Deliberately a separate process. "The choice resets when Neovim exits" is only
-- meaningfully tested across a genuine restart -- clearing a module-level variable by hand
-- in one process proves nothing about what a *new* one starts with, and an assertion made
-- in the same process would pass however the choice were stored.
--
-- It also marks a file reviewed, which the store genuinely does carry. That is what lets
-- the next session prove the channel between the two is live before concluding the layout
-- is not on it: without it, "nothing about the layout came back" would be satisfied by
-- nothing coming back at all.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- layout_spec with XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 140
vim.o.lines = 45
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

require("codereview").setup({ layout = "unified", syntax = false })

local view = require("codereview.view")

view.open("branch")
local V = assert(view.current(), "no review view opened")
assert(V.before_win == nil, "the child did not open in the configured layout")

-- Progress the store does carry, made before the toggle so it cannot depend on where the
-- toggle left the cursor.
vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[1], 0 })
view.toggle_reviewed()

view.toggle_layout()
assert(view.current().before_win ~= nil, "the child never reached the split layout")

-- Printed so a failing layout_spec can show what the choosing process believed it did.
-- `nvim -l` sends this to stderr, not stdout.
print(("reviewed %s; state file: %s"):format(V.files[1].path, require("codereview.state").path(V.root)))
vim.cmd("qa!")
