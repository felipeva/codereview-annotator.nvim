-- Open-time budget on a large review. Deliberately NOT part of `make test`.
--
-- Wall-clock numbers are machine-dependent, so this is a report you read rather than an
-- assertion you trust. The ceiling below is loose on purpose: it catches a regression that
-- changes the shape of the work (parsing every file up front, hashing blobs one at a
-- time), not the ordinary spread between a laptop and a CI runner.
--
-- Run with:  make perf
--
-- Two things keep opening a 60-file review at ~300 ms: syntax harvesting bounded by the
-- viewport, and batched blob hashing. If this regresses, suspect one of those two.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

vim.o.columns = 140
vim.o.lines = 50

-- A five-fold regression fails; ordinary machine variance does not.
local BUDGET_MS = tonumber(vim.env.CODEREVIEW_PERF_BUDGET_MS) or 2000

local fixture = vim.env.BIG
if not fixture or fixture == "" then
  fixture = vim.fn.tempname() .. "-big"
  local sh = vim.fs.joinpath(root, "tests", "fixtures", "mkbig.sh")
  local res = vim.system({ "bash", sh, fixture }, { text = true }):wait(120000)
  assert(res.code == 0, res.stderr)
  io.write(res.stdout)
end
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local function ms(fn)
  local t0 = vim.uv.hrtime()
  fn()
  return (vim.uv.hrtime() - t0) / 1e6
end

require("codereview").setup({})
local view = require("codereview.view")
local syntax = require("codereview.syntax")
local NS = vim.api.nvim_create_namespace("codereview")
local PRIORITY = require("codereview.render").PRIORITY.syntax

local function syntax_marks(buf)
  return #vim.tbl_filter(function(m)
    return m[4].priority == PRIORITY
  end, vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true }))
end

local open_ms = ms(function()
  view.open("branch")
end)
local V = view.current()

print(("open:            %6.0f ms   (budget %d ms)"):format(open_ms, BUDGET_MS))
print(("  rows           %6d"):format(#V.render.lines))
print(("  files parsed   %6d / %d"):format(vim.tbl_count(V.syntax_painted), #V.files))
print(("  syntax marks   %6d"):format(syntax_marks(V.buf)))

-- Scroll to the bottom: files there must get parsed on demand, not up front.
print(("scroll to end:   %6.0f ms"):format(ms(function()
  vim.api.nvim_win_set_cursor(V.win, { #V.render.lines, 0 })
  vim.api.nvim_win_call(V.win, function()
    vim.cmd("normal! zz")
  end)
  syntax.apply(V, NS)
end)))
print(("  files parsed   %6d / %d"):format(vim.tbl_count(V.syntax_painted), #V.files))

print(("scroll back:     %6.0f ms   (cached)"):format(ms(function()
  vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
  vim.api.nvim_win_call(V.win, function()
    vim.cmd("normal! zz")
  end)
  syntax.apply(V, NS)
end)))

print(("repaint:         %6.0f ms"):format(ms(function()
  view.paint()
end)))

if open_ms > BUDGET_MS then
  print(("\nFAIL: open took %.0f ms, over the %d ms budget"):format(open_ms, BUDGET_MS))
  vim.cmd("cq")
end
print("\nOK")
vim.cmd("qa!")
