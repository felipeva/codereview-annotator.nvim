-- The writing half of checkout_restart_spec, in its own process.
--
-- Deliberately a separate process. What reached the disk is only meaningfully tested across
-- a genuine restart -- calling `state.load` twice in one process proves nothing about what
-- was written -- and the queue's id counter does not survive a process at all, so the id a
-- new annotation takes can only collide with an **archive** in the session after the one
-- that dispatched it.
--
-- What it leaves behind, and why each half of it is there:
--
--   agent-a   one batch dispatched (id 1), and one annotation left unsent behind it (id 2)
--   agent-b   two annotations, both dispatched (ids 3 and 4), and no queue at all
--
-- The second checkout keeps nothing queued on purpose: with a stored queue to come back,
-- restoring it would lift the counter past the archive on its own, and the case would pass
-- with the archive never read. Its ids are also both above everything the first checkout
-- holds, which is what makes "seeded from *this* checkout's archive" the only thing that
-- can keep a new annotation clear of them.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned with
-- XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

local base = assert(vim.env.FIXTURE, "FIXTURE is not set")
local A = vim.fs.joinpath(base, "agent-a")
local B = vim.fs.joinpath(base, "agent-b")

-- The note the composer answers with, set before each capture. Every checkout holds
-- `src/main.lua` at the same repository-relative path, so the note is the only thing that
-- says which checkout an entry was written in.
local note = "unset"
require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
  -- Reports nothing, which delivery reads as a dispatch -- and a dispatch is what archives.
  send = function() end,
})

local codereview = require("codereview")
local queue = require("codereview.queue")

---@param checkout string
---@param text string
local function annotate_in(checkout, text)
  vim.cmd("cd " .. vim.fn.fnameescape(checkout))
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(checkout, "src/main.lua")))
  note = text
  codereview.annotate("bug")
end

annotate_in(A, "dispatched from agent-a")
codereview.submit()
-- Asserted on the queue rather than on a return value: `codereview.submit` is the view's,
-- and the view returns nothing -- what a dispatch is, is the queue being empty afterwards.
assert(queue.count() == 0, "the first checkout's batch was not dispatched")
annotate_in(A, "left unsent in agent-a")

annotate_in(B, "dispatched from agent-b")
annotate_in(B, "also dispatched from agent-b")
codereview.submit()
assert(queue.count() == 0, "the second checkout's batch was not dispatched")

-- Printed so a failing spec can show what the writing process believed it left behind.
local state = require("codereview.state")
print("agent-a store: " .. state.path(A))
print("agent-b store: " .. state.path(B))
print("still queued: " .. queue.count())
vim.cmd("qa!")
