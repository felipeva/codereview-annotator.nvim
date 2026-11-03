-- The second process the claim "a trim records its base branch" needs: a Neovim that stores a
-- base branch, trims the review made from it and exits. trim_base_spec reads the store back.
--
-- A separate process for the reason trim_child is one: what a trim was made under is a claim
-- about what reached the disk, and reading it back in the process that set it proves nothing.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- trim_base_spec with XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

require("codereview").setup({ syntax = false })

local view = require("codereview.view")

local res = vim.system({ "git", "rev-parse", "HEAD~1" }, { cwd = fixture, text = true }):wait()
assert(res.code == 0, res.stderr)

assert(view.open("branch"), "the branch review did not open")
vim.cmd("CodeReviewBase feat/A")
-- The older of child's two commits, which is a prefix under feat/A and a hole under the
-- default branch.
view.trim_to({ vim.trim(res.stdout) })

vim.cmd("qa!")
