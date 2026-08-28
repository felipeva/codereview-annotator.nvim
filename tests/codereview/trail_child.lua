-- The switching half of `trail_spec`'s restart case, in its own process.
--
-- Inverted from every other child in this suite. The others write something and let the
-- parent read it back; this one exists so that the parent can find something **absent**.
-- The trail is navigation history and is never persisted, so the only way to see that it
-- did not survive a process is to have a process build one first -- and the process that
-- builds it cannot be the one that observes the absence.
--
-- It shares the parent's `XDG_STATE_HOME`, which is the whole point of sharing it: the
-- parent looks for its trail with this session's stores sitting on the disk in front of it.
-- If a trail were ever written, that is where it would be.
--
-- It asserts its own half rather than printing it, so the case cannot go vacuous. A child
-- that never reached the second checkout, or that could not go back, exits non-zero and the
-- parent says so instead of quietly asserting that nothing came back from nothing.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

local base = assert(vim.env.FIXTURE, "FIXTURE is not set")
local A = vim.fs.joinpath(base, "agent-a")
local B = vim.fs.joinpath(base, "agent-b")

vim.cmd("cd " .. vim.fn.fnameescape(A))

local chosen = nil
require("codereview").setup({
  syntax = false,
  pick_checkout = function(_, cb)
    cb(chosen)
  end,
})

local codereview = require("codereview")
local view = require("codereview.view")

chosen = B
codereview.switch()
assert(view.current() and view.current().root == B, "the child never reached the second checkout")

codereview.back()
assert(view.current() and view.current().root == A, "the child could not go back to the first checkout")

print("went " .. A .. " -> " .. B .. " -> back")
vim.cmd("qa!")
