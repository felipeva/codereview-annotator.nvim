-- Repo root from this file's own location, so the suite runs from any clone.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter"))
vim.o.columns = 140; vim.o.lines = 50
vim.cmd("cd " .. vim.fn.fnameescape(vim.env.BIG))
local function ms(fn) local t0 = vim.uv.hrtime(); fn(); return (vim.uv.hrtime() - t0) / 1e6 end
require("codereview").setup({})
local view = require("codereview.view")
local NS = vim.api.nvim_create_namespace("codereview")
local function syn() return #vim.tbl_filter(function(m) return m[4].priority == 150 end,
  vim.api.nvim_buf_get_extmarks(0, NS, 0, -1, { details = true })) end

print(("open (60 files, 12k lines): %.0f ms"):format(ms(function() view.open("branch") end)))
local V = view.current()
print(("  rows=%d  files parsed=%d/%d  syntax marks=%d")
  :format(#V.render.lines, vim.tbl_count(V.syntax_painted), #V.files,
    #vim.tbl_filter(function(m) return m[4].priority == 150 end,
      vim.api.nvim_buf_get_extmarks(V.buf, NS, 0, -1, { details = true }))))

-- Scroll to the bottom: files there must get parsed on demand.
print(("scroll to end:               %.0f ms"):format(ms(function()
  vim.api.nvim_win_set_cursor(V.win, { #V.render.lines, 0 })
  vim.api.nvim_win_call(V.win, function() vim.cmd("normal! zz") end)
  require("codereview.syntax").apply(V, NS)
end)))
print(("  files parsed=%d/%d"):format(vim.tbl_count(V.syntax_painted), #V.files))

print(("scroll back (cached):        %.0f ms"):format(ms(function()
  vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
  vim.api.nvim_win_call(V.win, function() vim.cmd("normal! zz") end)
  require("codereview.syntax").apply(V, NS)
end)))

print(("repaint:                     %.0f ms"):format(ms(function() view.paint() end)))
vim.cmd("qa!")
