-- The writing half of drop_restart_spec, in its own process.
--
-- Deliberately a separate process. The queue is read back once per session, so a process
-- that dropped an entry and then restored would be reading its own memory, and a drop that
-- never reached the disk would pass. Only the session after this one can say what a drop
-- left behind.
--
-- Queues two bugs through the capture path, opens the queue float with no review view
-- anywhere in the session, drops the first with `x` and exits with nothing written after
-- that. Two rather than one, so the next session can tell a drop that was written from a
-- queue that was blanked: one survivor, and the right one, is the only reading that says
-- the drop itself reached the disk.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned with
-- XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

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

local queue = require("codereview.queue")
local view = require("codereview.view")

vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
for _, text in ipairs({ "dropped one", "kept one" }) do
  note = text
  codereview.annotate("bug")
end
assert(queue.count() == 2, "the two captures did not both queue")
assert(not view.current(), "a review view is open, and the drop under test has none")

local ids = vim.tbl_map(function(item)
  return tostring(item.id)
end, queue.all())

view.review_queue()
-- The row is found by its note rather than by a row number, so a float whose chrome moves
-- still drops the entry this child means to drop.
assert(vim.fn.search("dropped one") > 0, "the float does not show the entry to drop")
vim.api.nvim_feedkeys("x", "x", false)
assert(queue.count() == 1 and queue.all()[1].note == "kept one", "the drop did not reach the queue")

-- Printed for the parent: the ids as they were before the drop.
print("ids: " .. table.concat(ids, ","))
vim.cmd("qa!")
