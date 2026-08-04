-- Open-time and per-keystroke report on a large review. Deliberately NOT part of `make test`.
--
-- Wall-clock numbers are machine-dependent, so this is a report you read rather than an
-- assertion you trust. The one ceiling here is loose on purpose: it catches a regression
-- that changes the shape of the work (parsing every file up front, hashing blobs one at a
-- time), not the ordinary spread between a laptop and a CI runner.
--
-- Run with:  make perf
--
-- Two tiers, because every cost here is linear in the size of the review and the small one
-- hides them. 60 files is the size the budget has always watched and the only tier that can
-- fail this command; at 300 files the same operations are large enough to read a change
-- from. The larger tier reports and never asserts: a second budget would be a second number
-- to tune per machine, on a file that is read rather than gated.
--
-- The line to read first is `cursor move`. It is the body of the autocommand that fires on
-- every CursorMoved, which a reviewer pays per row while holding `j` -- unlike open, scroll
-- and repaint, which are paid at moments a reviewer expects to wait.
--
-- Two things keep opening a review fast: syntax harvesting bounded by the viewport, and
-- batched blob hashing. If open regresses, suspect one of those two. The third cost is the
-- character-level spans, reported at the foot of each tier because they are paid once per
-- git read and must never appear in the repaint line.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

vim.o.columns = 140
vim.o.lines = 50

-- A five-fold regression fails; ordinary machine variance does not. The 60-file tier only:
-- see the header for why the larger one carries no ceiling.
local BUDGET_MS = tonumber(vim.env.CODEREVIEW_PERF_BUDGET_MS) or 2000

-- Held down rather than tapped: one move is too short to time against a millisecond clock,
-- and fifty rows is roughly what leaning on `j` through a hunk costs a reviewer.
local MOVES = 50

local MKBIG = vim.fs.joinpath(root, "tests", "fixtures", "mkbig.sh")

---Build one tier's fixture repository and answer with its path.
---
---Built per run rather than taken from the environment: `mkbig.sh` already takes the file
---and line counts, so each tier asks it for its own size, and a single pre-built path could
---only ever be one of the two. It costs about half a second per tier.
---@param files integer
---@param lines integer
---@return string path
local function build(files, lines)
  local path = ("%s-big-%dx%d"):format(vim.fn.tempname(), files, lines)
  local res = vim.system({ "bash", MKBIG, path, tostring(files), tostring(lines) }, { text = true }):wait(120000)
  assert(res.code == 0, res.stderr)
  -- Through `print`, which `nvim -l` sends to stderr, rather than writing the script's own
  -- stdout: the whole report then arrives on one stream and stays in order however it is
  -- redirected.
  print(vim.trim(res.stdout))
  return path
end

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

---Time the work one `CursorMoved` does, averaged over a held-down key.
---
---The event is dispatched rather than provoked: neither `nvim_win_set_cursor` nor a
---`normal! j` raises `CursorMoved` in a headless `nvim -l` -- measured, not assumed -- so a
---report that only moved the cursor would time the move and none of the work. Dispatching
---runs the review buffer's own autocommand, so this is the whole body a reviewer pays for
---(the syntax pass and the tree sync together), not a stand-in for it.
---
---Warmed first, because the file under the cursor is parsed by the first pass after a
---paint, and that one-off parse is not what a keystroke costs. The moves stay inside that
---file for the same reason.
---@param V CRView
---@return number total_ms
local function cursor_moves(V)
  vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
  return ms(function()
    for i = 1, MOVES do
      vim.api.nvim_win_set_cursor(V.win, { 1 + i, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
    end
  end)
end

---Report one tier, and answer with the figures the two tiers are compared on.
---@param files integer
---@param lines integer
---@param budget_ms integer|nil the ceiling this tier is judged against; nil means it only reports
---@return { open: number, move: number, repaint: number }
local function tier(files, lines, budget_ms)
  print(("\n=== %d files x %d lines ==="):format(files, lines))
  vim.cmd("cd " .. vim.fn.fnameescape(build(files, lines)))

  local open_ms = ms(function()
    view.open("branch")
  end)
  local V = view.current()

  local verdict = budget_ms and ("(budget %d ms)"):format(budget_ms) or "(reported, never fails this command)"
  print(("open:            %6.0f ms   %s"):format(open_ms, verdict))
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

  -- The interactive path, and the only line here that is paid per keystroke.
  local moves_ms = cursor_moves(V)
  print(("cursor move:     %6.1f ms   (per keystroke: one CursorMoved, autocommand and all)"):format(moves_ms / MOVES))
  print(("  %2d moves       %6.0f ms   (holding `j`)"):format(MOVES, moves_ms))

  local repaint_ms = ms(function()
    view.paint()
  end)
  print(("repaint:         %6.0f ms   (every resize, expansion, reviewed toggle, scope change)"):format(repaint_ms))

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

  -- Each tier gets its own review, on its own repository: whatever the next one measures, it
  -- must not be measuring what this one left open.
  view.close()
  return { open = open_ms, move = moves_ms / MOVES, repaint = repaint_ms }
end

local small = tier(60, 200, BUDGET_MS)
local large = tier(300, 200, nil)

-- Side by side, because the point of the larger tier is the ratio: every one of these costs
-- is linear in the size of the review, so five times the files should be about five times
-- the milliseconds, and a change that flattens one of these lines is what the two slices
-- after this one are for.
-- The blank line is a prefix rather than a `print("")`: an empty message is dropped, not
-- echoed, so a line of its own would leave the table welded to the tier above it.
print(("\n%-16s %12s %12s"):format("side by side", "60 files", "300 files"))
print(("%-16s %9.0f ms %9.0f ms"):format("  open", small.open, large.open))
print(("%-16s %9.1f ms %9.1f ms"):format("  cursor move", small.move, large.move))
print(("%-16s %9.0f ms %9.0f ms"):format("  repaint", small.repaint, large.repaint))

if small.open > BUDGET_MS then
  print(("\nFAIL: open took %.0f ms, over the %d ms budget"):format(small.open, BUDGET_MS))
  vim.cmd("cq")
end
print("\nOK")
vim.cmd("qa!")
