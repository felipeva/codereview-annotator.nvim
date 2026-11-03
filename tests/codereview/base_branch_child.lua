-- The second process every claim about a kept **base branch** needs: a Neovim that stores a
-- base branch on two branches and exits, and a Neovim that opens a branch review and reports
-- what it is measured from.
--
-- A separate process for the reason trim_child is one: a base branch that outlives a session
-- is a claim about what reached the disk.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- base_branch_spec with XDG_STATE_HOME, FIXTURE and MODE in its environment, and it must NOT
-- load tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
local mode = assert(vim.env.MODE, "MODE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

require("codereview").setup({ syntax = false })

local view = require("codereview.view")

---@param args string[]
local function git(args)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = fixture, text = true }):wait()
  assert(res.code == 0, table.concat(args, " ") .. ": " .. (res.stderr or ""))
end

assert(view.open("branch"), "the branch review did not open")

if mode == "read" then
  -- Printed rather than asserted: the spec owns the expectations, and `nvim -l` sends this to
  -- stderr.
  local scope = assert(view.current()).scope
  print("label: " .. scope.label)
  print("before: " .. scope.before)
else
  -- Two branches, two different base branches: one value on one branch cannot tell a store
  -- keyed by branch from a store keyed by checkout.
  vim.cmd("CodeReviewBase feat/A")
  git({ "checkout", "-q", "feat/A" })
  view.set_scope("branch")
  vim.cmd("CodeReviewBase origin/feat/A")
  git({ "checkout", "-q", "child" })
end

vim.cmd("qa!")
