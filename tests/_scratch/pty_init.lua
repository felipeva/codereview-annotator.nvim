-- Repo root from this file's own location, so the suite runs from any clone.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
require("codereview").setup({
  syntax = false,
  compose = function(ctx, on_accept, _)
    local cbuf = vim.api.nvim_create_buf(false, true)
    local cwin = vim.api.nvim_open_win(cbuf, true, {
      relative = "editor", width = 50, height = 3, row = 3, col = 3,
      style = "minimal", border = "rounded",
    })
    vim.keymap.set("i", "<C-s>", function()
      local text = table.concat(vim.api.nvim_buf_get_lines(cbuf, 0, -1, false), "\n")
      vim.api.nvim_win_close(cwin, true)   -- closes WITHOUT stopinsert, like the real one
      on_accept(nil, text)
    end, { buffer = cbuf })
    vim.cmd("startinsert")
  end,
  send = function() end,
})
