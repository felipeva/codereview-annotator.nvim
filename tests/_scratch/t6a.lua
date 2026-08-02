-- Phase 6, process 1: create progress and let it persist.
-- Repo root from this file's own location, so the suite runs from any clone.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110; vim.o.lines = 40
vim.cmd("cd " .. vim.fn.fnameescape(vim.env.FIXTURE))
require("codereview").setup({
  syntax = false,
  compose = function(ctx, on_accept, _) on_accept(nil, "note on " .. ctx.rel_path) end,
})
local view, queue, annotate = require("codereview.view"), require("codereview.queue"), require("codereview.annotate")
view.open("branch")
local V = view.current()
queue.clear()

local function first_line_row(path)
  for row, a in pairs(V.render.anchors) do
    if a.kind == "line" and V.files[a.file].path == path then return row end
  end
end
local function file_row(path)
  for i, f in ipairs(V.files) do if f.path == path then return V.render.file_rows[i] end end
end

vim.api.nvim_win_set_cursor(V.win, { first_line_row("src/fresh.ts"), 0 }); annotate.annotate("bug")
vim.api.nvim_win_set_cursor(V.win, { first_line_row("src/routes.ts"), 0 }); annotate.annotate("nitpick")
vim.api.nvim_win_set_cursor(V.win, { file_row("src/main.ts"), 0 }); view.toggle_reviewed()

local path = require("codereview.state").path(V.root)
print("state file: " .. path)
print(vim.fn.filereadable(path) == 1 and table.concat(vim.fn.readfile(path), "\n") or "MISSING")
vim.cmd("qa!")
