-- overlay_follow_spec's child: an annotation captured in a checkout and written to its store,
-- by a Neovim that then exits.
--
-- A process of its own because the queue is read back once per checkout per session, and the
-- case it serves is a checkout the parent has never read: the parent must find this entry on
-- the disk, through the margin's first paint there, and nowhere else. Captured through
-- `annotate`, which is the capture path a reviewer uses and the one that writes the store.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- overlay_follow_spec with the parent's XDG_STATE_HOME and with CHECKOUT in its environment,
-- and it must NOT load tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local checkout = assert(vim.env.CHECKOUT, "CHECKOUT is not set")
vim.cmd("cd " .. vim.fn.fnameescape(checkout))
vim.cmd("edit src/long.lua")

require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "stored in another checkout")
  end,
})
require("codereview").annotate("bug", { first = 3, last = 3 })

-- `nvim -l` sends print to stderr; the parent reads both streams.
print(("queued=%d"):format(#require("codereview.queue").all()))
vim.cmd("qa!")
