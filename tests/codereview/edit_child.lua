-- The writing half of edit_restart_spec, in its own process.
--
-- Deliberately a separate process. The queue is read back once per session, so a process
-- that edited an entry and then restored would be reading its own memory, and an edit that
-- never reached the disk would pass. Only the session after this one can say what an edit
-- left behind.
--
-- Queues three entries through the capture path, edits the middle one, and exits with
-- nothing written after the edit: whatever the next session finds is what the edit wrote.
-- The middle one because an edit that re-queued would land last, and the ids are printed so
-- the parent can tell an entry that kept its id from one that took a new one.
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

-- Printed for the parent: the ids as they were before the edit, and which one was edited.
print("ids: " .. table.concat(ids, ","))
print("edited: " .. ids[2])
vim.cmd("qa!")
