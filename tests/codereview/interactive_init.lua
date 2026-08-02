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

---What the picker answers with. `nil` is a cancel; `interactive_spec` flips this over the
---socket to drive that case.
_G.cr_pick_answer = { path = "src/routes.lua", first = 2, last = 4 }

---How many times the picker has answered *and* the composer has finished reacting. What
---the spec polls on: neither the keystroke nor the answer is a state it can wait for.
_G.cr_picks = 0

require("codereview").setup({
  syntax = false,
  send = function() end,
  -- Behaves like a real picker rather than answering inline: a window that opens on a
  -- later tick, takes focus, leaves insert mode behind it, and hands focus back when it is
  -- done. Answering inline would leave the composer in insert mode by accident -- never
  -- having left it -- and an assertion that insert mode comes back would pass with nothing
  -- restoring it, which is the trap this whole file exists to avoid.
  pick_file = function(cb)
    local composer = vim.api.nvim_get_current_win()
    vim.schedule(function()
      local picker = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
        relative = "editor",
        width = 30,
        height = 5,
        row = 1,
        col = 1,
        style = "minimal",
      })
      -- Scheduled apart from the answer: returning from an insert-mode mapping can put Vim
      -- straight back into insert, so a `stopinsert` has to survive a trip through the
      -- main loop before the composer is handed anything.
      vim.cmd("stopinsert")
      vim.schedule(function()
        vim.api.nvim_win_close(picker, true)
        vim.api.nvim_set_current_win(composer)
        cb(_G.cr_pick_answer)
        -- Counted after the fact, so a spec polling on it knows the composer has finished
        -- reacting rather than merely that the picker answered.
        _G.cr_picks = _G.cr_picks + 1
      end)
    end)
  end,
})
