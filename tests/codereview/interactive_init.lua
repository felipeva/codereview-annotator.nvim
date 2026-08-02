-- The composer stub interactive_spec drives, in a real (pty-backed) Neovim.
--
-- Minimal on purpose: a float entered with `startinsert`, submitted from an insert-mode
-- mapping, closing its own window WITHOUT `stopinsert`. That is exactly the shape of the
-- real composer, and it is what leaves focus back in the review buffer still in INSERT.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept, _)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = 50,
      height = 3,
      row = 3,
      col = 3,
      style = "minimal",
      border = "rounded",
    })
    vim.keymap.set("i", "<C-s>", function()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      vim.api.nvim_win_close(win, true) -- closes WITHOUT stopinsert, like the real one
      on_accept(nil, text)
    end, { buffer = buf })
    vim.cmd("startinsert")
  end,
  send = function() end,
})
