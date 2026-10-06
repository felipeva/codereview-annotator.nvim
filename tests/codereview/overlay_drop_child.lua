-- The writing half of overlay_drop_restart_spec, in its own process.
--
-- A process of its own for the reason drop_child gives: the queue is read back once per
-- session, so a process that dropped an entry and then restored would read its own memory,
-- and a drop that never reached the disk would pass.
--
-- Queues two bugs on two lines through the capture path, turns the **overlay** on, enters
-- the **margin** with `<C-w>l` from the first one's line, drops it with `x` and exits with
-- nothing written after that. No review view anywhere in the session. Two rather than one,
-- so the next session can tell a drop that was written from a queue that was blanked.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned with
-- XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 120
vim.o.lines = 30

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local note = "unset"
local codereview = require("codereview")
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
})

local overlay = require("codereview.overlay")
local queue = require("codereview.queue")
local view = require("codereview.view")

vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
local code = vim.api.nvim_get_current_win()
for line, text in ipairs({ "dropped one", "kept one" }) do
  note = text
  codereview.annotate("bug", { first = line, last = line })
end
assert(queue.count() == 2, "the two captures did not both queue")

local ids = vim.tbl_map(function(item)
  return tostring(item.id)
end, queue.all())

codereview.overlay()
local m = assert(overlay.margin(), "the overlay opened no margin")
vim.api.nvim_win_set_cursor(code, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>l", true, false, true), "x", false)
assert(vim.api.nvim_get_current_win() == m.win, "<C-w>l did not enter the margin")
vim.api.nvim_feedkeys("x", "x", false)
assert(queue.count() == 1 and queue.all()[1].note == "kept one", "the drop did not reach the queue")
assert(not view.current(), "a review view is open, and the drop under test has none")

-- Printed for the parent: the ids as they were before the drop.
print("ids: " .. table.concat(ids, ","))
vim.cmd("qa!")
