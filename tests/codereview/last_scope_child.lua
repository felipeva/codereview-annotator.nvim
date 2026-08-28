-- The writing half of last_scope_spec, in its own process.
--
-- Deliberately a separate process. "The scope is recorded in the checkout's *document*" is
-- only meaningfully tested across a genuine restart: a module-level table keyed on the
-- checkout passes every single-process case in that file and nothing in one session can
-- tell the two apart, because a checkout's entries and marks never leave memory once it has
-- been visited. A second session is the only reader that has to have got it off the disk.
--
-- What it leaves behind: one checkout last reviewed at the `worktree` scope, with the file
-- in that scope marked reviewed. The mark is there so the session after this one can prove
-- the channel between the two is live before concluding anything about the scope -- without
-- it, "the scope did not come back" would be satisfied by there being no store at all.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned with
-- XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

local base = assert(vim.env.FIXTURE, "FIXTURE is not set")
local A = vim.fs.joinpath(base, "agent-a")
vim.cmd("cd " .. vim.fn.fnameescape(A))

require("codereview").setup({ syntax = false })

local view = require("codereview.view")

-- Named rather than defaulted, and `worktree` rather than any other: an argument-less open
-- answers with the branch scope, so a scope a return could reach by accident would leave
-- the next session unable to say what it was reading.
view.open("worktree")
local V = assert(view.current(), "no review view opened")
assert(V.scope.name == "worktree", "the child did not open the scope it asked for")
assert(#V.files > 0, "the worktree scope of this checkout has nothing in it")

vim.api.nvim_set_current_win(V.win)
vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[1], 0 })
view.toggle_reviewed()

-- Printed so a failing spec can show what the writing process believed it left behind.
-- `nvim -l` sends this to stderr, not stdout.
print(
  ("reviewed %s in the %s scope; state file: %s"):format(
    V.files[1].path,
    V.scope.name,
    require("codereview.state").path(V.root)
  )
)
vim.cmd("qa!")
