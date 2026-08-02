-- Minimal init for the plenary suite.
--
-- Two things go on the runtimepath and nothing else: this plugin, and plenary. No user
-- config, no nvim-treesitter -- a spec that passes here passes on a bare Neovim, which is
-- what CI runs.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

vim.opt.runtimepath:prepend(root)

-- `tests/` is not a `lua/` directory, so the specs reach their helpers through the
-- package path rather than the runtimepath.
package.path = root .. "/?.lua;" .. package.path

-- Wherever plenary happens to live: cloned by `make deps`, or already present in a
-- developer's plugin manager.
local plenary
for _, candidate in ipairs({
  root .. "/.tests/plenary.nvim",
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim",
  vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
}) do
  if vim.fn.isdirectory(candidate) == 1 then
    plenary = candidate
    break
  end
end
if not plenary then
  error("plenary.nvim not found -- run `make deps`")
end
vim.opt.runtimepath:append(plenary)
vim.cmd("runtime plugin/plenary.vim")

-- Persistence goes to a throwaway directory that Neovim deletes on exit.
--
-- Unconditional, and per process: reusing a state directory makes review-progress
-- assertions pass because a *previous* run's state was restored, and inheriting the real
-- one writes into ~/.local/state/nvim/codereview/, where a user has genuine review state.
-- Anything that deliberately needs two processes to share a directory (state_spec) passes
-- XDG_STATE_HOME explicitly to the child and does not load this file there.
vim.env.XDG_STATE_HOME = vim.fn.tempname() .. "-state"

-- Every `git` the plugin or a spec shells out to runs without user or system config.
-- Inherited settings quietly change what the fixtures mean: `diff.renames = false` turns
-- the rename case into an unrelated add and delete, and `commit.gpgsign` makes building a
-- fixture depend on a gpg agent. Child processes inherit this, so the spawned Neovims in
-- state_spec and interactive_spec are covered too.
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_SYSTEM = "/dev/null"

vim.o.swapfile = false
vim.o.shadafile = "NONE"
