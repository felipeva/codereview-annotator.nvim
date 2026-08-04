-- The dispatching half of archive_spec: a Neovim that submits a batch and exits.
--
-- Deliberately a separate process, for the two reasons this feature has. The archive is
-- only meaningfully read back across a genuine restart -- reading it in the process that
-- wrote it proves nothing about what reached the disk. And the queue's id counter is
-- module-level, so a session that dispatched ids 1..n and then exited is the only place
-- the collision the seed exists to prevent can be observed at all.
--
-- Three annotations of different provenance, so that the split across the two stores is
-- exercised by the batch itself: one inside the repository, one about a file outside any
-- checkout, one with no file at all.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- archive_spec with XDG_STATE_HOME, FIXTURE and LOOSE_FILE in its environment, and it must
-- NOT load tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
local loose = assert(vim.env.LOOSE_FILE, "LOOSE_FILE is not set")

vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local codereview = require("codereview")
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "dispatched by an earlier session")
  end,
  -- Answers inline, which is all this needs: nothing here is asserting the order a picker
  -- and a composer come in, only that the batch records where it went.
  pick_target = function(cb)
    cb({ short = "agent", pane_id = "wV:p9", cwd = fixture })
  end,
  send = function() end,
})

local queue = require("codereview.queue")

vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
codereview.annotate("bug")

vim.cmd("edit " .. vim.fn.fnameescape(loose))
codereview.annotate("fix")

vim.cmd("enew")
codereview.annotate("issue")

-- Chosen before submitting, so the batch goes somewhere with a name rather than to the
-- adapter's own default -- which is what makes "it records the target" an assertion.
require("codereview.delivery").pick_target()
codereview.submit()

-- Printed so a failing archive_spec can show what the dispatching process believed it did.
print("queued: " .. #queue.all() .. " left after submitting")
print("state file: " .. require("codereview.state").path(assert(require("codereview.git").root(fixture))))
vim.cmd("qa!")
