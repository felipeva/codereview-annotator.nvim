-- One session of capture_spec's restart case, in its own process.
--
-- Captures a single annotation from an ordinary buffer through the public entry point,
-- reports the resulting queue size and exits. The spec runs it twice: persistence is only
-- meaningfully tested across a genuine restart, and the queue is restored once per
-- session, so "a later session does not clobber an earlier one" cannot be observed from
-- inside the process that already restored.
--
-- Parameterised by environment rather than argv, because `-l` hands script arguments to
-- Neovim itself. Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it,
-- and it must NOT load tests/minimal_init.lua, which would mint its own state directory.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
local file = assert(vim.env.CAPTURE_FILE, "CAPTURE_FILE is not set")
local note = assert(vim.env.CAPTURE_NOTE, "CAPTURE_NOTE is not set")
-- The one optional variable: with no type named, the child declines one below. An empty
-- string would not do as the signal -- `vim.system` drops an empty value, so the child
-- cannot tell it from a variable nobody set.
local type_name = vim.env.CAPTURE_TYPE

vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local codereview = require("codereview")
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
})

local queue = require("codereview.queue")

vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, file)))

if type_name then
  codereview.annotate(type_name)
else
  -- Declining is the only way to reach an untyped annotation through the public entry
  -- point, and the decline entry is the last one the picker offers.
  vim.ui.select = function(items, _, cb)
    cb(items[#items], #items)
  end
  codereview.annotate()
end

-- The count is the whole point of the second run: it can only include the first session's
-- annotation if capture restored the persisted queue before adding to it.
print("queued: " .. queue.count())
vim.cmd("qa!")
