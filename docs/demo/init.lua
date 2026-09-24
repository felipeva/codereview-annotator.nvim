-- The config demo.tape records with: this plugin on the runtimepath, and nothing of the
-- user's. State goes to a temporary directory so a recording starts from an empty queue.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(root)

vim.env.XDG_STATE_HOME = vim.fn.tempname() .. "-state"
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_SYSTEM = "/dev/null"
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.termguicolors = true
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.opt.shortmess:append("I")
vim.o.cmdheight = 1

-- A stand-in agent that accepts every batch: the demo shows the hand-off, not a transport.
require("codereview").setup({
  send = function()
    return true
  end,
})
