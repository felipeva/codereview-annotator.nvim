---Where the review view's windows are: the **panes**, and the layout they are in.
---
---The after pane is the view's own window and buffer, and the split layout adds a before
---pane beside it. What this module owns is everything about *where* those windows are:
---placing both cursors together, putting the two back in step after a repaint moved the
---ground under them, building and dismissing the before pane, balancing the pair when the
---file tree arrives beside them, and the toggle between the unified and split layouts.
---What is drawn *into* a pane is `view.lua`'s, and the file tree is not a pane at all.
---
---**The review view is handed in rather than required**, as `keymaps.lua` and
---`queue_float.lua` are handed it. A rebuilt pane needs the diff's keys and the view's
---cursor entry point, and the layout toggle repaints; taking those as an argument rather
---than requiring `view` for them is what keeps this module out of the cycle `view` and
---`annotate` already sit in.
---
---**`CRView` is handed in too, and mutated in place.** The view is one table, owned by
---`view.lua`, and the before pane's handles are written onto it here exactly where they
---were written before -- the same arrangement `syntax.lua` has with its caches. Nothing
---about a review is copied into a local. The one thing that is local is the layout a
---reviewer chose, which has to outlive any one review and is why it was never on the view
---to begin with.
---
---The two window helpers below are shared rather than private: every surface the review
---builds a window for wants the same scratch buffer and the same window options, the file
---tree's included, and one copy of each is what keeps them the same.
local config = require("codereview.config")
local keymaps = require("codereview.keymaps")
local render = require("codereview.render")

local M = {}

---The layout a reviewer has chosen, for the rest of this editing session.
---
---Module-level rather than on the view, because the view is torn down when a review closes
---and the choice has to outlive that: a reviewer who switched once is not quietly put back
---by opening the next review.
---
---Deliberately not written to the state store either. That store is per repository and a
---layout preference is not; and a persisted preference would silently override a later
---configuration change, which is the bug where someone edits their config and nothing
---happens. A module local lasts exactly as long as it should -- until Neovim exits, after
---which configuration decides again.
---@type "unified"|"split"|nil nil until a reviewer has chosen, when configuration decides
local session_layout = nil

---@return "unified"|"split"
function M.opening_layout()
  return session_layout or config.get().layout
end

--- Panes ----------------------------------------------------------------------

---@param V CRView|nil
---@return boolean
function M.has_before(V)
  return V ~= nil and V.before_win ~= nil and vim.api.nvim_win_is_valid(V.before_win)
end

---Every review window there is, after pane first.
---@param V CRView
---@return integer[]
local function panes(V)
  local out = { V.win }
  if M.has_before(V) then
    out[#out + 1] = V.before_win
  end
  return out
end

---Which review window has focus, and the render drawn in it.
---
---Defaults to the after pane, which is the right answer for a caller that is in neither:
---it is the primary pane everywhere else, and every other use of the view's window is
---either a focus restore or a geometry read, for which the two panes are equivalent.
---
---Internal. Exported only because target resolution lives in another module, and is
---exercised through that module's behaviour rather than directly.
---@param V CRView
---@return integer win, CRRender|nil render
function M.focused_pane(V)
  if M.has_before(V) and vim.api.nvim_get_current_win() == V.before_win then
    return V.before_win, V.before_render
  end
  return V.win, V.render
end

---Put every pane on `row`, running the same view command in each.
---
---Explicitly rather than through `cursorbind`: the binding follows cursor *motions*, and
---nothing here moves a cursor -- it sets one. Running the same command in both windows is
---also what keeps their top lines identical, which the binding alone would not restore.
---
---And with the binding *lifted* while it does, because the binding tracks scroll deltas: the
---first pane's `zz` propagates into the second pane before the second pane has been placed,
---and the second pane's own `zz` then propagates back -- landing the two somewhere neither
---was asked for, and nine rows apart. Both panes are set from the same row and the same
---command instead, which is what makes the result the command that was asked for.
---@param V CRView
---@param row integer
---@param cmd string|nil A normal-mode view command: `zt` to put the row at the top, `zz`
---       to centre it, nil to leave the window where it is
function M.place(V, row, cmd)
  local bound = M.has_before(V)
  ---@param on boolean
  local function bind_panes(on)
    for _, win in ipairs(panes(V)) do
      vim.wo[win].scrollbind = on
      vim.wo[win].cursorbind = on
    end
  end

  if bound then
    bind_panes(false)
  end
  for _, win in ipairs(panes(V)) do
    local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(row, last)), 0 })
    if cmd then
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("normal! " .. cmd)
      end)
    end
  end
  if bound then
    -- Turning the binding back on records the offset the panes are at now; it does not
    -- scroll either of them, which is what makes lifting it safe.
    bind_panes(true)
  end
end

---Put both panes back on the same row and the same top line.
---
---`scrollbind` and `cursorbind` track deltas rather than absolute positions, so a repaint
---that changes the line count beneath them leaves the panes reading different code while
---still believing they are in step. Four operations do that -- toggling expansion, toggling
---reviewed, reloading the diff and changing scope -- and every one of them ends in a paint,
---so the binding is re-asserted there rather than at four call sites.
---@param V CRView
function M.resync(V)
  if not M.has_before(V) then
    return
  end
  local from = M.focused_pane(V)
  local last = vim.api.nvim_buf_line_count(V.buf)
  local row = math.max(1, math.min(vim.api.nvim_win_get_cursor(from)[1], last))
  local top = vim.api.nvim_win_call(from, function()
    return vim.fn.line("w0")
  end)
  for _, win in ipairs(panes(V)) do
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview({ topline = math.max(1, math.min(top, last)), lnum = row, col = 0, leftcol = 0 })
    end)
  end
end

--- Setup -----------------------------------------------------------------------

---@param buf integer
---@param name string
function M.scratch(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = name
  vim.api.nvim_buf_set_name(buf, name .. "://" .. tostring(buf))
end

---Give a review buffer everything it carries: the diff's keys, and the two autocommands
---that watch its cursor.
---
---An operation of its own rather than a loop in `open`, because a before pane's buffer is
---`bufhidden = "wipe"`. Toggling the layout back to unified destroys it, and toggling to
---split again builds a *new* one that has to be given all of this over -- the same lesson
---the panel learned when it became dismissible, and the same failure if it is forgotten: a
---pane that comes back with no keymaps at all.
---@param V CRView
---@param view table The review view, whose keys and cursor entry point this pane is given.
---@param buf integer
function M.attach_pane(V, view, buf)
  keymaps.diff(buf, view)

  -- The review buffer is nomodifiable, so insert mode is never meaningful in it. It can
  -- still be arrived at while already inserting: a composer opened with `startinsert` and
  -- submitted from an insert-mode mapping closes its window without ending insert, and
  -- focus lands here mid-insert -- no InsertEnter fires, because insert never ended.
  -- Every navigation key is then a failed edit rather than a motion.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "InsertEnter" }, {
    group = V.augroup,
    buffer = buf,
    callback = function()
      if vim.fn.mode():sub(1, 1) == "i" then
        vim.schedule(function()
          if vim.fn.mode():sub(1, 1) == "i" then
            vim.cmd("stopinsert")
          end
        end)
      end
    end,
  })

  -- One name rather than the three reaches behind it, wired directly rather than wrapped:
  -- this fires on every keystroke a reviewer holds, so nothing sits between the event and
  -- the work it comes due for.
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved" }, {
    group = V.augroup,
    buffer = buf,
    callback = view.cursor_moved,
  })
end

---@param win integer
function M.window_opts(win)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = true
  vim.wo[win].list = false
  vim.wo[win].spell = false
end

--- The before pane -------------------------------------------------------------

---Add the before pane, to the left of the after pane.
---
---A window and a buffer of its own rather than a second rendering of the existing one: the
---two panes hold different text, and Neovim binds scrolling and the cursor between windows,
---not between renderings.
---@param V CRView
---@param view table The review view, handed on to the pane this builds.
function M.show_before_pane(V, view)
  vim.api.nvim_set_current_win(V.win)
  vim.cmd("leftabove vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  M.scratch(buf, "codereview")
  M.window_opts(win)
  V.before_buf, V.before_win = buf, win

  -- Both window-local. `scrollopt`, which decides what a bound window keeps in step, is
  -- global -- a plugin that set it would reach outside its own windows -- so it is left
  -- alone. Its default gives vertical synchronisation only, and horizontal scrolling
  -- staying independent per pane is accepted.
  for _, w in ipairs({ V.win, win }) do
    vim.wo[w].scrollbind = true
    vim.wo[w].cursorbind = true
  end

  M.attach_pane(V, view, buf)
  vim.api.nvim_set_current_win(V.win)
end

---Dismiss the before pane, leaving the after pane as the whole review view.
---
---Its buffer is `bufhidden = "wipe"`, so closing the window destroys the buffer and every
---keymap and autocommand bound to it. Nothing is kept back to re-attach later: showing the
---pane again builds a new one and gives it the set over.
---
---The binding is lifted from the surviving pane rather than left set on it, so that the
---unified layout is the same single window it has always been.
---@param V CRView
local function hide_before_pane(V)
  local win = V.before_win
  V.before_buf, V.before_win, V.before_render = nil, nil, nil
  vim.wo[V.win].scrollbind = false
  vim.wo[V.win].cursorbind = false
  -- Leave it deliberately rather than letting Neovim pick a successor for a window it is
  -- about to close: the after pane is where the review continues.
  if vim.api.nvim_get_current_win() == win then
    vim.api.nvim_set_current_win(V.win)
  end
  pcall(vim.api.nvim_win_close, win, true)
end

---Give the two panes equal width.
---
---Called when the windows themselves change rather than on every paint: a reviewer who has
---dragged the border between the panes has said what they want, and a repaint is not the
---moment to overrule them. What does change the split without being asked is the panel
---appearing or disappearing beside it, which is what this covers.
---@param V CRView
function M.balance_panes(V)
  if not M.has_before(V) then
    return
  end
  local total = vim.api.nvim_win_get_width(V.before_win) + vim.api.nvim_win_get_width(V.win)
  pcall(vim.api.nvim_win_set_width, V.before_win, math.floor(total / 2))
end

--- The layout ------------------------------------------------------------------

---Row in `rendered` carrying the same anchor, or the file's header when it carries none.
---
---Anchor indices -- file, hunk and line -- mean the same thing in both layouts, because a
---layout decides where a row is drawn and not what a row is. Buffer rows do not: the same
---line of the same hunk sits at a different row in each. So the anchor is what a toggle
---carries across, and this is the scan the queue float's jump and `]a` already make.
---
---**Filler** is the one anchor with no counterpart -- it exists only in the split layout,
---and names a place the unified layout draws no row for at all -- so it finds nothing and
---falls through to the header, which needs no branch of its own. That is the same reading
---target resolution already gives it: the cursor is on nothing, so this means the file.
---@param rendered CRRender
---@param anchor CRAnchor
---@return integer
local function row_carrying(rendered, anchor)
  for row = 1, #rendered.lines do
    local a = rendered.anchors[row]
    if a and a.kind == anchor.kind and a.file == anchor.file and a.hunk == anchor.hunk and a.line == anchor.line then
      return row
    end
  end
  return rendered.file_rows[anchor.file] or 1
end

---Whether an anchor names a place in the before pane, and so which pane receives the cursor.
---
---The line's side decides, through the key that already carries it: only a pure deletion
---produces a pre-image key, and a context line exists in both images with its key preferring
---the post-image. No new rule -- it is the one that already decides which pane a note is
---drawn in and which pane the queue float jumps to.
---@param V CRView
---@param anchor CRAnchor
---@return boolean
local function belongs_to_before(V, anchor)
  if anchor.kind ~= "line" then
    return false
  end
  local file = V.files[anchor.file]
  return render.is_before_key(render.line_key(file.path, file.hunks[anchor.hunk].lines[anchor.line]))
end

---Switch between the unified and split layouts, from either pane or from the file tree.
---
---Configuration decides the layout a review opens in; this decides it from there on, and
---the choice is remembered for the rest of the session rather than for this review only.
---
---What survives the switch is the **anchor** under the cursor, never the row: the same line
---of the same hunk sits at a different row in each layout, so a row carried across would
---land on unrelated code. The result is centred, because the row moved structurally and an
---exact scroll offset preserved across that would be preserving something meaningless.
---@param V CRView|nil
---@param view table The review view: the anchor under its cursor, and the repaint this needs.
function M.toggle_layout(V, view)
  if not view.current() then
    return
  end
  -- Read before the rebuild, from whichever pane has focus. Asked from the tree it answers
  -- for the after pane, which is where the diff cursor is.
  local anchor = view.anchor_at_cursor()
  local in_panel = V.panel_win ~= nil and vim.api.nvim_get_current_win() == V.panel_win

  if M.has_before(V) then
    hide_before_pane(V)
  else
    M.show_before_pane(V, view)
  end
  V.layout = M.has_before(V) and "split" or "unified"
  session_layout = V.layout

  -- The panes have just taken columns from each other, or handed them all back to one
  -- window, and a file header is padded to the width of the window drawing it -- so this
  -- repaints rather than leaning on the resize autocommand, which fires from the main loop
  -- and therefore lands after the toggle has returned.
  --
  -- No balancing beside it: a `vsplit` halves the window it splits, and closing one half
  -- gives its columns back to the other, so the two panes are already comparable. What is
  -- not is the panel arriving or leaving beside them, which is where `balance_panes` lives.
  view.paint()

  if not anchor then
    return
  end
  local to_before = M.has_before(V) and belongs_to_before(V, anchor)
  local rendered = to_before and V.before_render or V.render
  -- Focus follows the code, unless it was never in the diff to begin with: a reviewer who
  -- toggled from the tree asked for a different layout, not for a different window. Set
  -- either way rather than only when it moves, because building a pane takes focus to
  -- split the window and the tree has to be handed it back.
  vim.api.nvim_set_current_win(in_panel and V.panel_win or (to_before and V.before_win or V.win))
  view.goto_row(row_carrying(rendered, anchor), "zz")
end

return M
