-- The reading half of uuid_restart_spec, in its own process. Spawned twice.
--
-- Deliberately a separate process. The queue is read back once per session, so only a new
-- process can show what a restore takes from the disk, and what it leaves there.
--
-- Restores the queue and does nothing else: no capture, no edit, no submit. Whatever is on
-- the disk after this process is what the restore wrote. Prints each entry's kind and
-- uuid, in queue order, for the parent.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned with
-- XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

require("codereview").setup({ syntax = false })
require("codereview.state").ensure_queue()

for _, item in ipairs(require("codereview.queue").all()) do
  print(("entry: %s %s"):format(item.kind, tostring(item.uuid)))
end
vim.cmd("qa!")
