---The composer the plugin ships.
---
---Deliberately the same shape as the `compose` adapter a host injects -- it *is* the
---default implementation of that contract, not a lesser path beside it. Anything a host
---composer is handed, this one is handed; anything it must do, this one does.
local config = require("codereview.config")
local drafts = require("codereview.drafts")

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

  local draft_key = drafts.key(ctx)
  local restored = drafts.get(draft_key)

  -- The batch's routing by default, because a note written here joins the batch. An
  -- immediate send hands its own on the context: that note has a target of its own, and
  -- naming the batch's would name a destination this note is not going to.
  local routing = ctx.routing or require("codereview.delivery").routing()

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
  ---open, and it is worth showing: it is what decides where this note ends up.
  local function refresh()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    -- Truncated because a target name can be long ("janus · Analyze RUM patterns") and a
    -- footer wider than the float is silently clipped, taking the keys with it.
    local name = routing.label()
    if #name > 16 then
      name = name:sub(1, 15) .. "…"
    end
    -- `^D` only while there is something to discard. A key named in the footer that does
    -- nothing is worse than one that is not named at all.
    local drop = restored and " · ^D drop" or ""
    cfg_win.footer = (" ^T %s%s · ^S %s · q abandon "):format(name, drop, label)
    vim.api.nvim_win_set_config(win, cfg_win)
  end

  ---@param keep_draft boolean Stash what is written for next time
  local function close(keep_draft)
    -- Read before the window goes: `bufhidden = "wipe"` takes the buffer with it.
    if keep_draft and vim.api.nvim_buf_is_valid(buf) then
      drafts.set(draft_key, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    end
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
    close(false)
    -- Committed as far as this composer is concerned: a submitted note is not an
    -- abandoned one, and nothing of the window that collected it is worth restoring.
    --
    -- It is no longer the last word on the note, though. `on_accept` may deliver, and a
    -- delivery can report that it did not go -- by which time this window is closed and
    -- its buffer wiped, so the caller writes the note back under this same key rather
    -- than losing it. Clearing here is still right: it is the caller's business whether
    -- there is anything left to keep.
    drafts.set(draft_key, nil)
    -- The target argument is the adapter contract's, not this composer's: routing is a
    -- property of the batch and the plugin already holds it.
    on_accept(nil, text)
  end

  -- Both modes: you are typing when you finish, but you may well have pressed <Esc> to
  -- reread the note first, and a submit key that only works in one of those is a trap.
  vim.keymap.set({ "i", "n" }, "<C-s>", submit, { buffer = buf, desc = label })
  -- Routing without abandoning the note. The picker answers on a later tick and puts focus
  -- back here itself, so there is nothing to restore -- only a footer to redraw. What it
  -- changes is whatever this composer is routing: the batch, or this one note.
  vim.keymap.set({ "i", "n" }, "<C-t>", function()
    routing.pick(refresh)
  end, { buffer = buf, desc = "Choose target" })
  -- The sentinel is written *before* the picker opens, so canceling leaves the literal
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
      -- Said out loud, because a host that wires its adapters up incompletely otherwise
      -- gets a key that does nothing, which is indistinguishable from one that is broken.
      -- The sentinel stays where it was written: what is missing is the reference, not the
      -- character the reviewer just typed.
      vim.notify(
        "No file picker configured — set pick_file to reference a file",
        vim.log.levels.WARN,
        { title = "Code review" }
      )
      return
    end
    pick_file(function(chosen)
      -- Empty when the picker was dismissed, which is the whole point of writing the
      -- sentinel up front: canceling costs the reviewer the `@` they typed and nothing
      -- else, and everything below still applies to where that leaves them.
      local spliced = ""
      if chosen and chosen.path then
        local payload = require("codereview.payload")
        -- A picker is entitled to answer with an absolute path, but a reference in a note
        -- should read the way every other reference in the batch reads. Resolved through
        -- the same helpers the payload uses, so a symlinked working directory does not turn
        -- a perfectly relative path into an absolute one. Outside the tree there is nothing
        -- to be relative to, and the absolute path is the only name the file has.
        local path = chosen.path
        if path:sub(1, 1) == "/" then
          local root = payload.resolve_base(vim.uv.cwd())
          path = payload.relative_to(vim.uv.fs_realpath(path) or path, root) or path
        end
        -- Rendered by the module that reads references, not spelled out again here. Lines
        -- are optional: a picker that cannot select them omits both, and the reference is
        -- then to the file rather than to a range in it.
        local ref = payload.ref(path, chosen.first, chosen.last)
        -- Past the `@`: the sentinel is already in the buffer, and re-writing it would
        -- either double it or mean re-deriving where it went.
        spliced = ref:sub(2) .. " "
        vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { spliced })
      end

      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      -- The picker took focus, and the cursor and insert mode with it, so handing writing
      -- back is this composer's job. Past what was just written: a reference carries a
      -- trailing space that is an invitation to keep typing, and it is only that if the
      -- cursor is behind it.
      local target = col + #spliced
      vim.api.nvim_win_set_cursor(win, { row, target })
      -- Keys rather than `startinsert`, which is a no-op on the tick a picker answers on: a
      -- picker that closes with `stopinsert` leaves the editor still reporting insert mode
      -- with the exit merely pending, so a request to start inserting is dropped and the
      -- exit lands afterwards regardless. Reading the mode here is no better -- it reports
      -- the one being left. `<C-\><C-n>` settles that first, from whichever mode the picker
      -- really left behind, and the key after it is then read against a known state.
      --
      -- `A` when nothing follows, because normal mode cannot hold a cursor past the last
      -- character of a line: the target arrives one column short there, and appending is
      -- what recovers it. Mid-sentence the two are different places, and the end of the
      -- line is not the one being written at.
      local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
      local settle = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
      vim.api.nvim_feedkeys(settle .. (target >= #line and "A" or "i"), "n", false)
    end)
  end, { buffer = buf, desc = "Reference a file" })

  -- Normal mode only. In insert both are the keys you actually want -- `q` is a letter and
  -- <Esc> is how you leave insert to reread what you wrote.
  -- Discarding is not the same as writing an empty note: it says "forget what I left here",
  -- and without it the only way to be rid of a draft is to submit it.
  vim.keymap.set({ "i", "n" }, "<C-d>", function()
    if not restored then
      return
    end
    restored = nil
    drafts.set(draft_key, nil)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    refresh()
  end, { buffer = buf, desc = "Discard the restored draft" })

  local function abandon()
    close(true)
  end
  vim.keymap.set("n", "q", abandon, { buffer = buf, desc = "Abandon (keeps a draft)" })
  vim.keymap.set("n", "<Esc>", abandon, { buffer = buf, desc = "Abandon (keeps a draft)" })

  if restored then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(restored, "\n"))
    -- The end of the draft, not the start of its last line. A draft comes back to be
    -- carried on with, and column zero puts the next word before the reviewer's own words
    -- rather than after them.
    local last = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(win, { last, #vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] })
    -- Said out loud, because text you did not just type appearing in a buffer you are about
    -- to write in is otherwise a small mystery.
    vim.notify("Draft restored — ^D to discard", vim.log.levels.INFO, { title = "Code review" })
  end

  refresh()
  -- You opened this to write something, so start writing. Leaving insert mode again is
  -- `collect`'s job, not this one's: closing a window does not end insert by itself, and
  -- the review buffer is `nomodifiable`, where every motion would land as a failed edit.
  --
  -- With the bang, because normal mode cannot hold a cursor past the last character of a
  -- line: the end-of-draft position set above arrives one column short, and only the bang
  -- makes entering insert mean the end of the line rather than that clamped column. On an
  -- empty composer the two are the same thing.
  vim.cmd("startinsert!")
  return win
end

return M
