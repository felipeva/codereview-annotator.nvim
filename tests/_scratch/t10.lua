-- Regressions: queue-float focus after <C-t>, and insert mode leaking out of the composer.
-- Repo root from this file's own location, so the suite runs from any clone.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 120
vim.o.lines = 45
vim.cmd("cd " .. vim.fn.fnameescape(vim.env.TREE))

local fail = 0
local function check(label, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then
    fail = fail + 1
  end
  print(("%s %-50s got=%s want=%s"):format(ok and "ok  " or "FAIL", label, vim.inspect(got), vim.inspect(want)))
end

local sent = {}
local pending -- the picker's callback, held so it fires asynchronously like a real one

require("codereview").setup({
  syntax = false,
  -- Synchronous. Insert mode is unreachable in headless Neovim, so the insert-mode
  -- leak (and its fix) cannot be exercised here at all -- that is covered end-to-end by
  -- pty_test.py, which drives a real terminal.
  compose = function(ctx, on_accept, _)
    on_accept(nil, "note on " .. ctx.rel_path)
  end,
  -- Mimics vim.ui.select: the callback lands on a later tick, not inline.
  pick_target = function(cb)
    pending = function()
      cb({ short = "janus · api", pane_id = "wV:p3", cwd = "/elsewhere" })
    end
  end,
  send = function(text, target)
    sent[#sent + 1] = { text = text, target = target }
  end,
})

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")

view.open("branch")
local V = view.current()
queue.clear()

--- Setup ---------------------------------------------------------------------
local function first_line_row()
  for row, a in pairs(V.render.anchors) do
    if a.kind == "line" then
      return row
    end
  end
end

vim.api.nvim_set_current_win(V.win)
vim.api.nvim_win_set_cursor(V.win, { first_line_row(), 0 })
annotate.annotate("bug")
check("annotation was queued", queue.count(), 1)

--- Bug 1: the queue float keeps focus across <C-t> ----------------------------
view.review_queue()
local qwin = vim.api.nvim_get_current_win()
local qbuf = vim.api.nvim_win_get_buf(qwin)
check("queue float is focused when opened", qwin ~= V.win, true)
check("float is tracked for cleanup", V.queue_win, qwin)

local function footer()
  local c = vim.api.nvim_win_get_config(qwin)
  return c.footer and tostring(c.footer[1][1]) or ""
end
check("footer starts on the local target", footer():find("local", 1, true) ~= nil, true)

-- Press <C-t>; the picker has not answered yet.
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-t>", true, false, true), "x", false)
check("focus held while the picker is open", vim.api.nvim_get_current_win(), qwin)

pending() -- picker answers
check("target recorded", V.target.short, "janus · api")
check("focus RETURNED to the float, not the diff", vim.api.nvim_get_current_win(), qwin)
check("float still open", vim.api.nvim_win_is_valid(qwin), true)
check("footer repainted with the new target", footer():find("janus", 1, true) ~= nil, true)

--- <C-s> from the float submits AND closes ------------------------------------
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
check("batch was sent", #sent, 1)
check("sent to the chosen agent", sent[1].target.pane_id, "wV:p3")
check("queue emptied", queue.count(), 0)
check("float closed", vim.api.nvim_win_is_valid(qwin), false)
check("tracking cleared", V.queue_win, nil)

--- Submitting from the DIFF must also close an open float ---------------------
sent = {}
vim.api.nvim_set_current_win(V.win)
vim.api.nvim_win_set_cursor(V.win, { first_line_row(), 0 })
annotate.annotate("fix")
view.review_queue()
local qwin2 = vim.api.nvim_get_current_win()
check("second float open", vim.api.nvim_win_is_valid(qwin2), true)

-- Simulate the old failure mode directly: submit while focus sits in the diff.
vim.api.nvim_set_current_win(V.win)
view.submit()
check("submitted from the diff", #sent, 1)
check("no stale float left listing a sent batch", vim.api.nvim_win_is_valid(qwin2), false)
check("queue emptied", queue.count(), 0)

--- <C-t> from the diff still focuses the diff ---------------------------------
V.target = nil
vim.api.nvim_set_current_win(V.win)
view.pick_target()
pending()
check("picking from the diff returns to the diff", vim.api.nvim_get_current_win(), V.win)
check("winbar shows the target", vim.wo[V.win].winbar:find("janus", 1, true) ~= nil, true)

print(("\n%s  %d failure(s)"):format(fail == 0 and "ALL PASS" or "FAILURES", fail))
vim.cmd(fail == 0 and "qa!" or "cq")
