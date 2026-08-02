-- The config interactive_spec drives, in a real (pty-backed) Neovim.
--
-- No `compose` adapter on purpose: the plugin's own composer is the subject now. This used
-- to hold a stub shaped like a host's composer -- a float entered with `startinsert`,
-- submitted from an insert-mode mapping, closing its window without `stopinsert` -- because
-- there was nothing else to drive. Now that the plugin ships the thing that stub was
-- imitating, the imitation is worth less than the original.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

require("codereview").setup({
  syntax = false,
  send = function() end,
})
