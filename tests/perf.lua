-- Open-time budget on a large review. Deliberately NOT part of `make test`.
--
-- Wall-clock numbers are machine-dependent, so this is a report you read rather than an
-- assertion you trust. The ceiling below is loose on purpose: it catches a regression that
-- changes the shape of the work (parsing every file up front, hashing blobs one at a
-- time), not the ordinary spread between a laptop and a CI runner.
--
-- Run with:  make perf
--
-- Two things keep opening a 60-file review fast: syntax harvesting bounded by the
-- viewport, and batched blob hashing. If this regresses, suspect one of those two. The
-- third cost is the character-level spans, reported separately at the bottom because they
-- are paid once per git read and must never appear in the repaint line.
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
local git = require("codereview.git")
local diff = require("codereview.diff")
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

-- Spans are computed once per git read and never during a repaint, which is the whole
-- reason they live in the parser. Both parses are timed so the cost has a home of its own:
-- if it ever stops showing up here and starts showing up in the repaint line above, the
-- work has moved back into the render and every resize is paying for it.
local cwd = vim.fn.getcwd()
local scope = assert(git.resolve_scope("branch", cwd))
local diff_text = assert(git.diff(scope, cwd, 3))
local plain_ms = ms(function()
  diff.parse(diff_text)
end)
local spans_ms = ms(function()
  diff.parse(diff_text, { spans = true })
end)
local spanned = 0
for _, file in ipairs(diff.parse(diff_text, { spans = true })) do
  for _, hunk in ipairs(file.hunks) do
    for _, ln in ipairs(hunk.lines) do
      spanned = spanned + (ln.spans and 1 or 0)
    end
  end
end
print(("parse:           %6.0f ms   (once per git read, not per repaint)"):format(plain_ms))
print(("  spans          %6.0f ms   (+%.0f ms)"):format(spans_ms, spans_ms - plain_ms))
print(("  lines spanned  %6d"):format(spanned))

if open_ms > BUDGET_MS then
  print(("\nFAIL: open took %.0f ms, over the %d ms budget"):format(open_ms, BUDGET_MS))
  vim.cmd("cq")
end
print("\nOK")
vim.cmd("qa!")
