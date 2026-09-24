-- The writing half of edit_restart_spec, in its own process.
--
-- Deliberately a separate process. The queue is read back once per session, so a process
-- that edited an entry and then restored would be reading its own memory, and an edit that
-- never reached the disk would pass. Only the session after this one can say what an edit
-- left behind.
--
-- Queues three entries through the capture path, all of them bugs, edits the middle one's
-- note, takes the type off the first and makes the last a nitpick, and exits with nothing
-- written after that: whatever the next session finds is what the edits wrote. The middle
-- one because an edit that re-queued would land last, and the ids are printed so the parent
-- can tell an entry that kept its id from one that took a new one. The first one's type is
-- taken off because an untyped entry has no `type` at all, and a field that is absent is
-- the one a write can lose without anything failing.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned with
-- XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- The note the composer answers with, set before each capture and before the edit.
local note = "unset"
local codereview = require("codereview")
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
})

local queue = require("codereview.queue")

vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
for _, text in ipairs({ "first", "second, as captured", "third" }) do
  note = text
  codereview.annotate("bug")
end
assert(queue.count() == 3, "the three captures did not all queue")

local ids = vim.tbl_map(function(item)
  return tostring(item.id)
end, queue.all())

note = "second, as edited"
require("codereview.annotate").edit_note(queue.all()[2])
assert(queue.all()[2].note == note, "the edit did not reach the queue")

-- The type picker answers with the row whose label ends in `pick`.
local pick
vim.ui.select = function(items, _, cb)
  for i, item in ipairs(items) do
    if vim.endswith(item, pick) or item:find(" " .. pick .. " ", 1, true) then
      return cb(item, i)
    end
  end
end
pick = "no type"
require("codereview.annotate").change_type(queue.all()[1])
pick = "nitpick"
require("codereview.annotate").change_type(queue.all()[3])
assert(queue.all()[1].type == nil and queue.all()[3].type == "nitpick", "the type changes did not reach the queue")

-- Printed for the parent: the ids as they were before the edit, and which one was edited.
print("ids: " .. table.concat(ids, ","))
print("edited: " .. ids[2])
vim.cmd("qa!")
