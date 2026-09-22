---The file tree's stateful half: its window, its buffer, and the actions its keys run.
---
---`panel.lua` is the pure half -- the tree built out of a file list, the single-child chains
---compacted, what folding leaves visible, the per-directory tallies -- and this is the half
---that was never split out with it: where that tree is drawn, when it is redrawn, and what
---each of its keys does to the review underneath it. The same division `render.lua` and
---`view.lua` already have for the diff.
---
---**Which file the diff cursor is in is not this module's.** The tree highlights it and
---follows it, but it is a fact about the diff and its anchor map, so it is `view.lua`'s
---`current_file` -- asked for here, never kept here. The crossing that decides *repaint
---now* is `view.lua`'s too, and is judged whether or not there is a tree; this module is
---told, it does not ask. That is what lets a second surface follow the same crossing
---without reaching down into the tree for it.
---
---**The review view is handed in rather than required**, as `keymaps.lua`, `queue_float.lua`
---and `view_layout.lua` are handed it. Where this calls back -- the tree's `<CR>` expands a
---collapsed file and jumps into the diff, a subtree marked reviewed repaints and persists,
---the window toggle repaints, and every paint asks which file the cursor is in -- it takes
---`view` as an argument. That is what keeps this module out of the cycle `view` and
---`annotate` already sit in.
---
---**`CRView` is handed in too, and mutated in place.** The view is one table, owned by
---`view.lua`, and the tree's window, its buffer and its render are written onto it here
---exactly where they were written before -- the same arrangement `syntax.lua` has with its
---caches. Nothing about a review is copied into a local.
---
---The tree's window is not a **pane**: the panes are the two images a split layout draws, and
---this window sits beside them. What it does share with them is how a review window is made --
---the scratch buffer, the window options, and the balance the panes need when this one arrives
---or leaves beside them -- and all three are `view_layout.lua`'s, which this module requires.
---That edge is one-directional.
local config = require("codereview.config")
local keymaps = require("codereview.keymaps")
local panel = require("codereview.panel")
local view_layout = require("codereview.view_layout")

local M = {}

local NS_PANEL = vim.api.nvim_create_namespace("codereview_panel")

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

--- Painting --------------------------------------------------------------------

---@param V CRView
---@param view table The review view, asked which file the diff cursor is in.
function M.paint_panel(V, view)
  if not (V.panel_win and vim.api.nvim_win_is_valid(V.panel_win)) then
    return
  end
  local cfg = config.get()
  V.panel_render = panel.build(V.files, {
    width = vim.api.nvim_win_get_width(V.panel_win),
    icons = cfg.icons,
    -- The configured **annotation types**, in order, so the tree can colour a file's state
    -- mark in that file's **leading type**. Handed over like the glyph table above and the
    -- adapters below rather than read by the tree itself: the builder is pure, and what
    -- decides which type leads is the host's own declaration order.
    types = cfg.types,
    file_icon = cfg.file_icon,
    dir_icon = cfg.dir_icon,
    reviewed = V.reviewed,
    notes = V.notes,
    collapsed = V.collapsed,
    -- Asked, rather than read off `V.current_file`: a paint can run between two crossings
    -- -- a fold, a resize, the tree arriving beside a cursor nothing has moved since. The
    -- two agree everywhere `CursorMoved` has reached, so the suite cannot tell them apart;
    -- asking is what the tree did for itself before this moved, and a prefactor keeps it.
    current = view.current_file(),
  })
  vim.bo[V.panel_buf].modifiable = true
  vim.api.nvim_buf_set_lines(V.panel_buf, 0, -1, false, V.panel_render.lines)
  vim.bo[V.panel_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(V.panel_buf, NS_PANEL, 0, -1)
  for _, m in ipairs(V.panel_render.marks) do
    pcall(vim.api.nvim_buf_set_extmark, V.panel_buf, NS_PANEL, m.row, m.col, m.opts)
  end
end

---Move the panel's highlight (and cursor, when it is not focused) to follow the diff.
---
---Reached only when the diff cursor has crossed into a different file -- `view.lua` judges
---that, and does so with or without a tree. Rebuilding the tree on each keystroke is
---wasted work on a large review, so the cheapness that guard buys is unchanged; what
---changed is that the guard is no longer this module's to hold.
---@param V CRView|nil
---@param view table The review view, asked which file the diff cursor is now in.
function M.sync_panel(V, view)
  if not (V and V.panel_win and vim.api.nvim_win_is_valid(V.panel_win)) then
    return
  end
  M.paint_panel(V, view)
  local index = view.current_file()
  local row = index and V.panel_render.file_row[index]
  if row and vim.api.nvim_get_current_win() ~= V.panel_win then
    pcall(vim.api.nvim_win_set_cursor, V.panel_win, { row, 0 })
  end
end

--- Focus -----------------------------------------------------------------------

---Move between the tree and the diff.
---@param V CRView|nil
---@param view table The review view, whose window the diff is drawn in.
function M.toggle_focus(V, view)
  if not view.current() then
    return
  end
  if not (V.panel_win and vim.api.nvim_win_is_valid(V.panel_win)) then
    return
  end
  if vim.api.nvim_get_current_win() == V.panel_win then
    vim.api.nvim_set_current_win(V.win)
  else
    -- Entering the tree, land on the file being read rather than wherever the cursor was.
    local index = view.current_file()
    local row = index and V.panel_render and V.panel_render.file_row[index]
    vim.api.nvim_set_current_win(V.panel_win)
    if row then
      pcall(vim.api.nvim_win_set_cursor, V.panel_win, { row, 0 })
    end
  end
end

--- Panel actions ---------------------------------------------------------------

---@param V CRView
---@return integer|nil file_index, string|nil dir_path, integer row
local function panel_at_cursor(V)
  if not (V.panel_render and V.panel_win and vim.api.nvim_win_is_valid(V.panel_win)) then
    return nil, nil, 0
  end
  local row = vim.api.nvim_win_get_cursor(V.panel_win)[1]
  return V.panel_render.row_file[row], V.panel_render.row_dir[row], row
end

---Keep the cursor on the same tree row across a repaint, so collapsing a directory does
---not fling the cursor to the top of the panel.
---@param V CRView
---@param row integer
local function keep_panel_cursor(V, row)
  if V.panel_win and vim.api.nvim_win_is_valid(V.panel_win) then
    local last = vim.api.nvim_buf_line_count(V.panel_buf)
    pcall(vim.api.nvim_win_set_cursor, V.panel_win, { math.min(row, last), 0 })
  end
end

---`<CR>`: open a file, or fold a directory.
---@param V CRView
---@param view table The review view: the repaint a collapsed file needs, and the arrival.
function M.panel_select(V, view)
  local fi, dir, row = panel_at_cursor(V)
  if dir then
    V.collapsed[dir] = not V.collapsed[dir] or nil
    M.paint_panel(V, view)
    keep_panel_cursor(V, row)
    return
  end
  if not fi then
    return
  end
  -- Jumping to a reviewed file expands it: you asked to look at it.
  if V.expanded[V.files[fi].path] == false then
    V.expanded[V.files[fi].path] = true
    view.paint()
  end
  vim.api.nvim_set_current_win(V.win)
  -- The row this file is drawn on, or the drawing of it: the tree lists every file in the
  -- review, and under **solo** the diff draws one of them, so a row picked here is often a
  -- file the diff has no row for. That is not a failure -- it is the file to draw next, and
  -- `goto_file` is the one place that says so.
  view.goto_file(fi)
end

---`gd` in the tree: read the file under the cursor in the host's diff tool.
---
---With no line. The tree knows which file you are looking at and nothing about where in
---it, and a row that is a directory names no file at all.
---@param V CRView|nil
---@param view table The review view, which owns the handover to the host.
function M.panel_open_diff(V, view)
  if not view.current() then
    return
  end
  local fi = panel_at_cursor(V)
  if not fi then
    return
  end
  view.hand_to_diff(V.files[fi], nil)
end

---@param V CRView
---@param view table The review view, asked which file the diff cursor is in.
---@param shut boolean|nil nil toggles
function M.panel_fold(V, view, shut)
  local _, dir, row = panel_at_cursor(V)
  if not V.panel_render then
    return
  end

  if not dir then
    -- On a file, `h` folds the directory containing it -- the same reflex as in any tree.
    -- The parent is the nearest directory row above with a SMALLER depth; the nearest one
    -- by position may be a sibling directory the cursor has already scrolled past.
    if shut ~= true then
      return
    end
    local depth = V.panel_render.row_depth[row]
    for r = row - 1, 1, -1 do
      if V.panel_render.row_dir[r] and (V.panel_render.row_depth[r] or 0) < (depth or 0) then
        V.collapsed[V.panel_render.row_dir[r]] = true
        M.paint_panel(V, view)
        keep_panel_cursor(V, r)
        return
      end
    end
    return
  end

  if shut == nil then
    V.collapsed[dir] = not V.collapsed[dir] or nil
  else
    V.collapsed[dir] = shut or nil
  end
  M.paint_panel(V, view)
  keep_panel_cursor(V, row)
end

---@param V CRView|nil
---@param view table The review view, asked whether there is one at all.
---@param shut boolean
function M.panel_fold_all(V, view, shut)
  if not view.current() then
    return
  end
  V.collapsed = {}
  if shut then
    for _, dir in ipairs(panel.dir_paths(panel.tree(V.files, { reviewed = V.reviewed, notes = V.notes }))) do
      V.collapsed[dir] = true
    end
  end
  M.paint_panel(V, view)
  keep_panel_cursor(V, 1)
end

---Toggle reviewed from the tree. On a directory, this applies to the whole subtree --
---"I have read this package" is a thing you want to say in one keystroke.
---@param V CRView
---@param view table The review view: the repaint and the write to disk this comes with.
function M.panel_toggle_reviewed(V, view)
  local fi, dir, row = panel_at_cursor(V)

  if dir then
    local indices = panel.files_under(V.files, dir)
    if #indices == 0 then
      return
    end
    local all_reviewed = true
    for _, index in ipairs(indices) do
      if not V.reviewed[V.files[index].path] then
        all_reviewed = false
        break
      end
    end
    for _, index in ipairs(indices) do
      local file = V.files[index]
      if all_reviewed then
        V.reviewed[file.path] = nil
        V.expanded[file.path] = true
      else
        V.reviewed[file.path] = file.blob or ""
        V.expanded[file.path] = false
      end
    end
    view.paint()
    view.persist()
    keep_panel_cursor(V, row)
    info(
      ("%s %d file%s under %s"):format(
        all_reviewed and "Unmarked" or "Marked",
        #indices,
        #indices == 1 and "" or "s",
        dir
      )
    )
    return
  end

  if not fi then
    return
  end
  -- The diff's own `R` and this one are one rule rather than two copies of one, which is what
  -- keeps the tree from needing a second opinion about what **solo** does to this key: mark
  -- the file, and under solo go on to the next unreviewed one. The paint is here only when
  -- the view stayed where it was, because going on repaints through the motion.
  if not view.mark_reviewed(fi) then
    view.paint()
  end
  keep_panel_cursor(V, row)
end

---@param V CRView
---@param view table The review view, whose "nearest row in that direction" rule this shares.
---@param forward boolean
function M.panel_jump_file(V, view, forward)
  local _, _, row = panel_at_cursor(V)
  if not V.panel_render then
    return
  end
  local target = view.nearest(V.panel_render.file_rows, row, forward)
  if target then
    keep_panel_cursor(V, target)
  end
end

--- The panel window ------------------------------------------------------------

---Build the panel: its window, its buffer and its keymaps.
---
---An operation of its own rather than a step inside `open`, because the toggle has to be
---able to run it again. The panel buffer is `bufhidden = "wipe"`, so a dismissed panel
---leaves nothing to re-attach: the buffer is gone and every keymap bound to it with it.
---@param V CRView
---@param view table The review view, whose tree keys this buffer is given.
function M.show_panel(V, view)
  local cfg = config.get()
  vim.api.nvim_set_current_win(V.win)
  vim.cmd(cfg.panel.position == "right" and "botright vsplit" or "topleft vsplit")
  local pwin = vim.api.nvim_get_current_win()
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(pwin, pbuf)
  view_layout.scratch(pbuf, "codereviewpanel")
  view_layout.window_opts(pwin)
  vim.api.nvim_win_set_width(pwin, cfg.panel.width)
  vim.wo[pwin].winfixwidth = true
  V.panel_buf, V.panel_win = pbuf, pwin
  keymaps.panel(pbuf, view)
  vim.api.nvim_set_current_win(V.win)
end

---Dismiss the panel. Collapsed directories are untouched: they live on the review.
---@param V CRView
local function hide_panel(V)
  local win = V.panel_win
  V.panel_buf, V.panel_win, V.panel_render = nil, nil, nil
  -- `V.current_file` is deliberately left alone. It used to be cleared here, because the
  -- crossing was judged inside this module's sync and stopped being judged the moment the
  -- window went away -- so the latch sat on whatever was being read at that instant, and
  -- reading that file again once the tree was back repainted nothing. The crossing is
  -- `view.lua`'s now and keeps being judged with no tree, so the latch tracks a reviewer
  -- through a dismissed tree instead of going stale behind one, and clearing it would only
  -- forge a crossing that did not happen. `panel_spec` pins the property either way.
  --
  -- A reviewer who dismisses the tree is not asking to be left in the window they
  -- dismissed, so leave it deliberately rather than letting Neovim pick a successor.
  if vim.api.nvim_get_current_win() == win then
    vim.api.nvim_set_current_win(V.win)
  end
  pcall(vim.api.nvim_win_close, win, true)
end

---Show or dismiss the file tree, from the diff or from the tree itself.
---
---Configuration decides the state a review opens in; this decides it from there on.
---@param V CRView|nil
---@param view table The review view, whose repaint the new width comes due for.
function M.toggle_panel(V, view)
  if not view.current() then
    return
  end
  if V.panel_win and vim.api.nvim_win_is_valid(V.panel_win) then
    hide_panel(V)
  else
    M.show_panel(V, view)
  end
  -- With three windows competing for the terminal's columns, the panel's arrival or
  -- departure is taken out of, or given back to, whichever pane Neovim picked. Split the
  -- difference so the two panes stay comparable, which is the whole point of the layout.
  view_layout.balance_panes(V)
  -- The diff just changed width and its file headers are padded to that width, so this has
  -- to repaint. The resize autocmd does not cover it: WinResized is fired from the main
  -- loop, so it lands after the toggle has returned -- and never at all if nothing else
  -- pumps the loop, which is exactly the headless case.
  view.paint()
end

return M
