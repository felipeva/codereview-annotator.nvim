---The composer the plugin ships.
---
---Deliberately the same shape as the `compose` adapter a host injects -- it *is* the
---default implementation of that contract, not a lesser path beside it. Anything a host
---composer is handed, this one is handed; anything it must do, this one does.
local config = require("codereview.config")

local M = {}

---Open the composer.
---@param ctx table What is being annotated. See `codereview-opt-compose`.
---@param on_accept fun(target: table|nil, text: string)
---@param label string Verb for the submit key
---@return integer win
function M.open(ctx, on_accept, label)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = math.min(84, math.max(40, math.floor(vim.o.columns * 0.7)))
  local height = 6
  local cfg_win = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    -- `ctx.label` already reads "Bug · src/main.lua:12" -- the type and the target, which is
    -- everything there is to say about what is being written here.
    title = (" %s "):format(ctx.label),
    title_pos = "center",
    footer = "",
    footer_pos = "center",
  }
  local win = vim.api.nvim_open_win(buf, true, cfg_win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  ---Redraw the footer. The target is the only part that changes while the composer is
  ---open, and it is worth showing: it is what decides where the batch ends up.
  local function refresh()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    -- Truncated because a target name can be long ("janus · Analyze RUM patterns") and a
    -- footer wider than the float is silently clipped, taking the keys with it.
    local name = require("codereview.view").target_label()
    if #name > 16 then
      name = name:sub(1, 15) .. "…"
    end
    cfg_win.footer = (" ^T %s · ^S %s · q abandon "):format(name, label)
    vim.api.nvim_win_set_config(win, cfg_win)
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Closing a float does not put focus back where the annotation started. Neovim focuses
    -- the window it recorded last -- a picker this composer opened, say -- and the first
    -- window in the tab once that is gone, which during a review is the tree. The plugin
    -- restores this itself once a note is accepted; on the abandoned path nothing else can,
    -- which is what `origin_win` is on the context for.
    if ctx.origin_win and vim.api.nvim_win_is_valid(ctx.origin_win) then
      vim.api.nvim_set_current_win(ctx.origin_win)
    end
  end

  ---Read before closing: `bufhidden = "wipe"` takes the buffer with the window.
  local function submit()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    close()
    -- The target argument is the adapter contract's, not this composer's: routing is a
    -- property of the batch and the plugin already holds it.
    on_accept(nil, text)
  end

  -- Both modes: you are typing when you finish, but you may well have pressed <Esc> to
  -- reread the note first, and a submit key that only works in one of those is a trap.
  vim.keymap.set({ "i", "n" }, "<C-s>", submit, { buffer = buf, desc = label })
  -- Routing without abandoning the note. The picker answers on a later tick and puts focus
  -- back here itself, so there is nothing to restore -- only a footer to redraw.
  vim.keymap.set({ "i", "n" }, "<C-t>", function()
    require("codereview.view").pick_target(refresh)
  end, { buffer = buf, desc = "Choose target" })
  -- The sentinel is written *before* the picker opens, so cancelling leaves the literal
  -- character that was just pressed. The position is remembered rather than re-derived for
  -- the same reason a host composer has to remember it: the picker takes focus, and the
  -- cursor with it, so by the time it answers the composer's cursor means nothing.
  vim.keymap.set("i", "@", function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(win))
    vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { "@" })
    col = col + 1
    vim.api.nvim_win_set_cursor(win, { row, col })

    -- Only where a word begins. Notes contain email addresses, and an `@` that continues a
    -- word is a character the user typed, not a request for a picker. Whitespace-or-start
    -- rather than anything cleverer, because the rule has to be predictable while typing:
    -- you should never be surprised by a picker.
    local before = col > 1 and vim.api.nvim_buf_get_text(buf, row - 1, col - 2, row - 1, col - 1, {})[1]
    if before and not before:match("%s") then
      return
    end

    local pick_file = config.get().pick_file
    if not pick_file then
      return
    end
    pick_file(function(chosen)
      if not (chosen and chosen.path) then
        return
      end
      local payload = require("codereview.payload")
      -- A picker is entitled to answer with an absolute path, but a reference in a note
      -- should read the way every other reference in the batch reads. Resolved through the
      -- same helpers the payload uses, so a symlinked working directory does not turn a
      -- perfectly relative path into an absolute one. Outside the tree there is nothing to
      -- be relative to, and the absolute path is the only name the file has.
      local path = chosen.path
      if path:sub(1, 1) == "/" then
        local root = payload.resolve_base(vim.uv.cwd())
        path = payload.relative_to(vim.uv.fs_realpath(path) or path, root) or path
      end
      -- Rendered by the module that reads references, not spelled out again here. Lines are
      -- optional: a picker that cannot select them omits both, and the reference is then to
      -- the file rather than to a range in it.
      local ref = payload.ref(path, chosen.first, chosen.last)
      -- Past the `@`: the sentinel is already in the buffer, and re-writing it would either
      -- double it or mean re-deriving where it went.
      vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { ref:sub(2) .. " " })
    end)
  end, { buffer = buf, desc = "Reference a file" })

  -- Normal mode only. In insert both are the keys you actually want -- `q` is a letter and
  -- <Esc> is how you leave insert to reread what you wrote.
  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Abandon" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Abandon" })

  refresh()
  -- You opened this to write something, so start writing. Leaving insert mode again is
  -- `collect`'s job, not this one's: closing a window does not end insert by itself, and
  -- the review buffer is `nomodifiable`, where every motion would land as a failed edit.
  vim.cmd("startinsert")
  return win
end

return M
