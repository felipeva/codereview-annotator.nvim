-- The first half of state_spec: a Neovim that makes review progress and then exits.
--
-- Deliberately a separate process. Persistence is only meaningfully tested across a
-- genuine restart -- calling `state.load()` twice in one process proves nothing about
-- what reached the disk, and an in-memory queue would satisfy every assertion.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- state_spec with XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

require("codereview").setup({
  syntax = false,
  compose = function(ctx, on_accept, _)
    on_accept(nil, "note on " .. ctx.rel_path)
  end,
})

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")

view.open("branch")
local V = view.current()
queue.clear()

local function line_row(path)
  for row, a in pairs(V.render.anchors) do
    if a.kind == "line" and V.files[a.file].path == path then
      return row
    end
  end
end

local function file_row(path)
  for i, f in ipairs(V.files) do
    if f.path == path then
      return V.render.file_rows[i]
    end
  end
end

vim.api.nvim_win_set_cursor(V.win, { assert(line_row("src/fresh.lua")), 0 })
annotate.annotate("bug")
vim.api.nvim_win_set_cursor(V.win, { assert(line_row("src/routes.lua")), 0 })
annotate.annotate("nitpick")
vim.api.nvim_win_set_cursor(V.win, { assert(file_row("src/main.lua")), 0 })
view.toggle_reviewed()

-- Printed so a failing state_spec can show what the writing process believed it saved.
print("state file: " .. require("codereview.state").path(V.root))
vim.cmd("qa!")
