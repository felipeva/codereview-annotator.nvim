---The review surface: buffers, windows, keymaps, navigation.
---
---One view exists at a time, in its own tab page. Everything it draws comes from
---`render.lua`; everything it knows about position comes from that render's anchor map.
---
---In the split layout the view keeps its existing buffer and window as the **after** pane
---and gains a before pane beside it. The after-image is the primary one everywhere else --
---context lines are attributed to it, line keys prefer it, an entry's line numbers prefer
---it, and opening a file resolves through it -- so naming it primary here is consistent
---rather than arbitrary, and it is what keeps the unified layout untouched.
local config = require("codereview.config")
local git = require("codereview.git")
local render = require("codereview.render")
local panel = require("codereview.panel")
local hl = require("codereview.hl")
local delivery = require("codereview.delivery")

local M = {}

local NS = vim.api.nvim_create_namespace("codereview")
local NS_PANEL = vim.api.nvim_create_namespace("codereview_panel")

---@class CRView
---@field root string
---@field scope CRScope
---@field files CRFile[]
---@field per_scope table<string, { reviewed: table<string,string>, expanded: table<string,boolean> }>
---@field reviewed table<string, string>   Path -> blob at the time it was marked
---@field expanded table<string, boolean>
---@field notes table<string, table[]>     Line key -> annotations
---@field buf integer                     The after pane
---@field win integer                     The after pane
---@field before_buf integer|nil          nil in the unified layout
---@field before_win integer|nil          nil in the unified layout
---@field layout "unified"|"split"
---@field panel_buf integer|nil
---@field panel_win integer|nil
---@field tab integer
---@field augroup integer                 Autocommands belonging to this review
---@field render CRRender|nil             The after pane's render
---@field before_render CRRender|nil      nil in the unified layout
---@field panel_render CRPanelRender|nil
---@field painted_bands table<integer, boolean>|nil  Row bands whose marks have been emitted

---@type CRView|nil
local V = nil

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
local function opening_layout()
  return session_layout or config.get().layout
end

---@param msg string
local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "Code review" })
end

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

---@return CRView|nil
function M.current()
  if V and vim.api.nvim_win_is_valid(V.win) then
    return V
  end
  return nil
end

---Reviewed/expanded state is tracked per scope: marking a file done in `staged` says
---nothing about whether you have reviewed the whole branch's changes to it.
---@param scope CRScope
---@return string
local function scope_key(scope)
  return scope.name .. ":" .. scope.before
end

--- Panes ----------------------------------------------------------------------

---@return boolean
local function has_before()
  return V ~= nil and V.before_win ~= nil and vim.api.nvim_win_is_valid(V.before_win)
end

---Every review window there is, after pane first.
---@return integer[]
local function panes()
  local out = { V.win }
  if has_before() then
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
---@return integer win, CRRender|nil render
function M.focused_pane()
  if has_before() and vim.api.nvim_get_current_win() == V.before_win then
    return V.before_win, V.before_render
  end
  return V.win, V.render
end

---Row the cursor is on, in whichever pane has focus. The two agree row for row, so this
---is a question about the cursor rather than about the layout.
---@return integer
local function cursor_row()
  local win = M.focused_pane()
  return vim.api.nvim_win_get_cursor(win)[1]
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
---@param row integer
---@param cmd string|nil A normal-mode view command: `zt` to put the row at the top, `zz`
---       to centre it, nil to leave the window where it is
local function place(row, cmd)
  local bound = has_before()
  ---@param on boolean
  local function bind_panes(on)
    for _, win in ipairs(panes()) do
      vim.wo[win].scrollbind = on
      vim.wo[win].cursorbind = on
    end
  end

  if bound then
    bind_panes(false)
  end
  for _, win in ipairs(panes()) do
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
local function resync()
  if not has_before() then
    return
  end
  local from = M.focused_pane()
  local last = vim.api.nvim_buf_line_count(V.buf)
  local row = math.max(1, math.min(vim.api.nvim_win_get_cursor(from)[1], last))
  local top = vim.api.nvim_win_call(from, function()
    return vim.fn.line("w0")
  end)
  for _, win in ipairs(panes()) do
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview({ topline = math.max(1, math.min(top, last)), lnum = row, col = 0, leftcol = 0 })
    end)
  end
end

--- Painting --------------------------------------------------------------------

---Index of the file the diff cursor is currently inside, for the panel's highlight.
---@return integer|nil
local function current_file_index()
  local win, rendered = M.focused_pane()
  if not (rendered and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  for r = row, 1, -1 do
    if rendered.anchors[r] then
      return rendered.anchors[r].file
    end
  end
  return nil
end

local function paint_panel()
  if not (V.panel_win and vim.api.nvim_win_is_valid(V.panel_win)) then
    return
  end
  local cfg = config.get()
  V.panel_render = panel.build(V.files, {
    width = vim.api.nvim_win_get_width(V.panel_win),
    icons = cfg.icons,
    reviewed = V.reviewed,
    notes = V.notes,
    collapsed = V.collapsed,
    current = current_file_index(),
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
---Repaints only when the file actually changed: this runs on every CursorMoved, and
---rebuilding the tree on each keystroke is wasted work on a large review.
local function sync_panel()
  if not (V and V.panel_win and vim.api.nvim_win_is_valid(V.panel_win)) then
    return
  end
  local index = current_file_index()
  if index == V.panel_current then
    return
  end
  V.panel_current = index
  paint_panel()
  local row = index and V.panel_render.file_row[index]
  if row and vim.api.nvim_get_current_win() ~= V.panel_win then
    pcall(vim.api.nvim_win_set_cursor, V.panel_win, { row, 0 })
  end
end

local function update_winbar()
  if not vim.api.nvim_win_is_valid(V.win) then
    return
  end
  local reviewed = 0
  for _ in pairs(V.reviewed) do
    reviewed = reviewed + 1
  end
  local added, removed = require("codereview.diff").totals(V.files)
  local notes = 0
  for _, items in pairs(V.notes) do
    notes = notes + #items
  end
  local bar = (" Code review · %s · %d/%d reviewed · +%d -%d"):format(
    V.scope.label,
    reviewed,
    #V.files,
    added,
    removed
  )
  if notes > 0 then
    bar = bar .. (" · %d note%s"):format(notes, notes == 1 and "" or "s")
  end
  local to = delivery.target()
  if to and to.short then
    bar = bar .. (" · → %s"):format(to.short)
  end
  vim.wo[V.win].winbar = bar:gsub("%%", "%%%%")
end

---Name the revision the before pane is showing.
---
---The after pane's winbar already says what the review is; what it cannot say is which of
---the two images is the base, and a reviewer should never have to infer that from the code.
local function update_before_winbar()
  if not has_before() then
    return
  end
  local rev = V.scope.before
  -- `:0` is git's name for the index, and a name nobody reads as one.
  local bar = (" Before · %s"):format(rev == ":0" and "index" or rev)
  vim.wo[V.before_win].winbar = bar:gsub("%%", "%%%%")
end

---Write one pane's render into its buffer: the lines, and nothing else.
---
---Which of the render's marks reach the buffer is `paint_bands`' decision, taken against
---the window rather than against the diff. The namespace is cleared here, so this is also
---where everything a previous paint emitted stops existing.
---@param buf integer
---@param rendered CRRender
local function write_pane(buf, rendered)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
end

---First index in `marks` whose row is at or after `row`.
---
---`render.build` appends each mark as it draws the row it belongs to, so a pane's marks are
---in non-decreasing row order and a run of rows is a slice of that array. Found rather than
---filtered, because a filter is a walk of the whole review -- the cost this bounding exists
---to remove, and one that would then be paid again on every scroll into new rows.
---`bounded_spec` pins the ordering this relies on, for both panes.
---@param marks table[]
---@param row integer 0-indexed, as an extmark's row is
---@return integer
local function lower_bound(marks, row)
  local lo, hi = 1, #marks + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if marks[mid].row < row then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

---Emit every mark one pane's render put on rows `first`..`last`, 1-indexed and inclusive.
---@param buf integer
---@param rendered CRRender
---@param first integer
---@param last integer
local function emit_rows(buf, rendered, first, last)
  local marks = rendered.marks
  for i = lower_bound(marks, first - 1), #marks do
    local m = marks[i]
    if m.row > last - 1 then
      return
    end
    -- An end_col past the end of a line is a hard error; a mis-measured header should
    -- lose its colour, not abort the whole repaint.
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, m.row, m.col, m.opts)
  end
end

---Emit the marks for the rows near the window, in every pane there is.
---
---Bounded by the viewport, not by the diff, for the reason the harvest already is and
---against the same bounds: a 300-file review renders 271,000 marks, and writing all of them
---is a sixth of a second on every resize, expansion, reviewed toggle and scope change.
---
---Rows are tracked in bands so that scrolling back re-emits nothing, and quantising is what
---keeps that tracking a handful of lookups instead of a set the size of the review. The
---grain is the harvest's margin: one figure decides both how far ahead the view paints and
---how coarsely it remembers, and a band is either wholly emitted or wholly not.
---
---Cheap when there is nothing new -- which is what lets it hang off `CursorMoved`.
local function paint_bands()
  if not V.render then
    return
  end
  local syntax = require("codereview.syntax")
  local band = syntax.VIEWPORT_MARGIN
  local lo, hi = syntax.viewport(V)
  V.painted_bands = V.painted_bands or {}
  for b = math.floor((lo - 1) / band), math.floor((hi - 1) / band) do
    if not V.painted_bands[b] then
      V.painted_bands[b] = true
      -- Both panes draw the same rows, so one set of bands answers for both: a band is
      -- emitted into both or into neither, which is what keeps the two images comparable
      -- row for row wherever a reviewer has scrolled.
      emit_rows(V.buf, V.render, b * band + 1, (b + 1) * band)
      if V.before_render then
        emit_rows(V.before_buf, V.before_render, b * band + 1, (b + 1) * band)
      end
    end
  end
end

---Redraw from the files already in memory. Cheap; no git.
---@param keep_file integer|nil File index to park the cursor on afterwards
function M.paint(keep_file)
  if not M.current() then
    return
  end
  local cfg = config.get()
  -- The queue is the source of truth for annotations; the view only ever displays a
  -- projection of it, so there is no second copy to keep in sync.
  V.notes = require("codereview.queue").by_key()
  -- Both panes from one walk: their row counts and their anchors agree by construction
  -- rather than because two calls happened to be handed the same arguments.
  V.render, V.before_render = render.build(V.files, {
    width = vim.api.nvim_win_get_width(V.win),
    before_width = has_before() and vim.api.nvim_win_get_width(V.before_win) or nil,
    layout = has_before() and "split" or "unified",
    icons = cfg.icons,
    expanded = V.expanded,
    reviewed = V.reviewed,
    notes = V.notes,
    types = cfg.types,
  })

  write_pane(V.buf, V.render)
  if V.before_render then
    write_pane(V.before_buf, V.before_render)
  end
  -- The namespaces above were just cleared, so nothing this records still exists. Dropped
  -- here rather than in `paint_bands` for the reason `syntax_painted` is dropped by the
  -- paint: what a band means is decided by the render it was emitted from.
  V.painted_bands = {}

  paint_panel()
  update_winbar()
  update_before_winbar()

  if keep_file and V.render.file_rows[keep_file] then
    place(V.render.file_rows[keep_file])
  end

  -- After `place`, not before it: parking the cursor on a file is what decides which rows
  -- are near the window, and a repaint has to leave the rows it lands on painted rather
  -- than waiting for the reviewer to move.
  paint_bands()

  -- The namespace was just cleared and the renders above are new, so nothing a previous
  -- paint derived from them still describes what is on screen -- but the parsed captures
  -- behind it are still good. Unconditional, unlike the pass below it: a row map left over
  -- from a paint made with highlighting off would be replayed onto rows it never described
  -- the moment highlighting came back.
  local syntax = require("codereview.syntax")
  syntax.repainted(V)
  if config.get().syntax then
    syntax.apply(V, NS)
  end

  resync()
end

---Write progress to disk. Called from every mutation rather than from `paint`, which
---also runs on resize and would turn a window drag into a stream of file writes.
---
---With a view, that means the reviewed marks and the queue together. Without one, only
---the queue -- there are no marks to write, and writing the document anyway would blank
---the ones a review left behind.
function M.persist()
  local state = require("codereview.state")
  if V then
    state.persist(V)
    return
  end
  -- Passed even when nil: there may still be annotations with no repository to write, and
  -- skipping would leave a submitted batch's entries on disk to come back next start.
  state.persist_queue(state.ambient_root())
end

---Read the persisted queue back if this session has not, and say what came back stale.
---
---The latch itself belongs to persistence, which owns the stores it reads and returns a
---count rather than phrasing one. What is left here is the sentence, worded exactly as a
---review reports staleness: with no view open this is the only moment a restored
---annotation's untrustworthy line anchors would otherwise go unmentioned.
local function ensure_queue()
  local staled = require("codereview.state").ensure_queue()
  if staled > 0 then
    info(require("codereview.queue").stale_phrase(staled))
  end
end

--- Cursor queries --------------------------------------------------------------

---@return CRAnchor|nil
local function anchor_at_cursor()
  local win, rendered = M.focused_pane()
  if not rendered then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  -- Walk upward: a blank padding row still belongs to the file above it, so a cursor
  -- resting in whitespace resolves to something sensible rather than nothing. In the split
  -- layout there is nothing to walk -- every row carries an anchor, and a filler row says
  -- so rather than letting the cursor inherit an unrelated line above it.
  for r = row, 1, -1 do
    if rendered.anchors[r] then
      return rendered.anchors[r], r
    end
  end
  return nil
end

---@return CRFile|nil, integer|nil
local function file_at_cursor()
  local anchor = anchor_at_cursor()
  if not anchor then
    return nil
  end
  return V.files[anchor.file], anchor.file
end

M.anchor_at_cursor = anchor_at_cursor
M.file_at_cursor = file_at_cursor

--- Actions ---------------------------------------------------------------------

---@param rows integer[]
---@param from integer
---@param forward boolean
---@return integer|nil
local function nearest(rows, from, forward)
  local best
  for _, r in ipairs(rows) do
    if forward and r > from then
      if not best or r < best then
        best = r
      end
    elseif not forward and r < from then
      if not best or r > best then
        best = r
      end
    end
  end
  return best
end

---Put a file header at the top of the window rather than leaving it wherever it lands:
---jumping to a file is a request to read it, and its first hunk should be on screen.
---
---Both panes, because a jump that moved only one would leave them reading different code.
---@param row integer
---@param cmd string|nil `zt`, `zz`, or nil to leave the window where it is
local function goto_row(row, cmd)
  place(row, cmd)
  sync_panel()
end

---@param what "file"|"hunk"
---@param forward boolean
function M.jump(what, forward)
  if not M.current() or not V.render then
    return
  end
  local rows = what == "file" and V.render.file_rows or V.render.hunk_rows
  local row = nearest(rows, cursor_row(), forward)
  if not row then
    info(("No %s %s here"):format(forward and "next" or "previous", what))
    return
  end
  goto_row(row, what == "file" and "zt" or nil)
end

---Jump to the next or previous file that is still unreviewed.
---
---The point of marking files reviewed is to stop looking at them, so the common motion is
---"take me to the next thing I have not done" -- not "the next file", which walks back
---through everything already finished.
---@param forward boolean
function M.jump_unreviewed(forward)
  if not M.current() or not V.render then
    return
  end
  local rows = {}
  for index, row in ipairs(V.render.file_rows) do
    if not V.reviewed[V.files[index].path] then
      rows[#rows + 1] = row
    end
  end
  if #rows == 0 then
    info("Everything in this scope is reviewed")
    return
  end

  local row = nearest(rows, cursor_row(), forward)
  if not row then
    -- Wrap: with the reviewed files skipped there are few targets left, and stopping dead
    -- at the last one means scrolling back by hand.
    row = forward and rows[1] or rows[#rows]
    info(forward and "Wrapped to the first unreviewed file" or "Wrapped to the last unreviewed file")
  end
  goto_row(row, "zt")
end

---Jump to the next or previous annotated line.
---@param forward boolean
function M.jump_annotation(forward)
  if not M.current() or not V.render then
    return
  end
  ---Rows carrying a note, and whether the before pane is the one carrying it there. Both
  ---anchor maps are read: a note on a deleted line exists only in the before pane's, and
  ---skipping it would make half a reviewer's remarks unreachable by `]a`.
  local owner = {}
  ---@param rendered CRRender|nil
  ---@param is_before boolean
  local function collect(rendered, is_before)
    for row, a in pairs(rendered and rendered.anchors or {}) do
      local file = V.files[a.file]
      local key
      if a.kind == "line" then
        key = render.line_key(file.path, file.hunks[a.hunk].lines[a.line])
      elseif a.kind == "file" and not is_before then
        -- A whole-file note carries no side, and it hangs off the after pane's header.
        key = render.file_key(file.path)
      end
      -- The after pane is collected first, so a row annotated on both sides is recorded as
      -- its own rather than being claimed by the before pane.
      if key and V.notes[key] and owner[row] == nil then
        owner[row] = is_before
      end
    end
  end
  collect(V.render, false)
  collect(V.before_render, true)

  local rows = vim.tbl_keys(owner)
  if #rows == 0 then
    info("No annotations yet")
    return
  end
  table.sort(rows)

  local row = nearest(rows, cursor_row(), forward) or (forward and rows[1] or rows[#rows])
  -- Land in the pane the note is drawn in, so the jump arrives at the code and not beside
  -- it. A row annotated on both sides keeps whichever pane the reviewer is already in.
  if has_before() and owner[row] and vim.api.nvim_get_current_win() ~= V.before_win then
    vim.api.nvim_set_current_win(V.before_win)
  end
  goto_row(row, "zz")
end

---Jump straight to a file, chosen from a list.
---
---`]f` is fine for the next file; it is useless for "the one three hundred rows down that
---I know the name of".
function M.pick_file()
  if not M.current() then
    return
  end
  local cfg = config.get()
  local items, labels = {}, {}
  for index, file in ipairs(V.files) do
    local reviewed = V.reviewed[file.path] ~= nil
    local notes = 0
    for key, list in pairs(V.notes) do
      if key:sub(1, #file.path + 1) == file.path .. ":" then
        notes = notes + #list
      end
    end
    items[#items + 1] = index
    labels[#labels + 1] = ("%s %-50s %s%s"):format(
      reviewed and cfg.icons.reviewed or (notes > 0 and cfg.icons.annotated or cfg.icons.unreviewed),
      file.path,
      file.binary and "binary" or ("+%d -%d"):format(file.added, file.removed),
      notes > 0 and ("  [%d]"):format(notes) or ""
    )
  end

  vim.ui.select(labels, { prompt = "Jump to file:" }, function(_, choice)
    if not choice then
      return
    end
    local index = items[choice]
    -- A file collapsed because it is reviewed must open when you deliberately jump to it,
    -- otherwise the jump lands on a header with nothing beneath it.
    if V.expanded[V.files[index].path] == false then
      V.expanded[V.files[index].path] = true
      M.paint()
    end
    if V.render.file_rows[index] then
      goto_row(V.render.file_rows[index], "zt")
    end
  end)
end

--- Focus -----------------------------------------------------------------------

---Move between the tree and the diff.
function M.toggle_focus()
  if not M.current() then
    return
  end
  if not (V.panel_win and vim.api.nvim_win_is_valid(V.panel_win)) then
    return
  end
  if vim.api.nvim_get_current_win() == V.panel_win then
    vim.api.nvim_set_current_win(V.win)
  else
    -- Entering the tree, land on the file being read rather than wherever the cursor was.
    local index = current_file_index()
    local row = index and V.panel_render and V.panel_render.file_row[index]
    vim.api.nvim_set_current_win(V.panel_win)
    if row then
      pcall(vim.api.nvim_win_set_cursor, V.panel_win, { row, 0 })
    end
  end
end

function M.toggle_reviewed()
  local file, index = file_at_cursor()
  if not file then
    return
  end
  if V.reviewed[file.path] then
    V.reviewed[file.path] = nil
    V.expanded[file.path] = true
  else
    -- The blob is what makes the mark verifiable later: on reload, a file whose content
    -- no longer hashes to this is a file you have not actually reviewed.
    V.reviewed[file.path] = file.blob or ""
    V.expanded[file.path] = false
  end
  M.paint(index)
  M.persist()
end

function M.toggle_expand()
  local file, index = file_at_cursor()
  if not file then
    return
  end
  local current = V.expanded[file.path]
  if current == nil then
    current = V.reviewed[file.path] == nil
  end
  V.expanded[file.path] = not current
  M.paint(index)
end

---Re-read the diff from git, preserving reviewed marks and annotations.
function M.refresh()
  if not M.current() then
    return
  end
  local cfg = config.get()
  local files, err =
    git.collect(V.scope, V.root, { context = cfg.context, untracked = cfg.untracked, spans = cfg.spans })
  if not files then
    warn("git: " .. (err or "diff failed"))
    return
  end
  V.files = files
  require("codereview.syntax").invalidate(V)
  M.reconcile()
  M.paint()
  M.persist()
end

---Re-check reviewed marks and annotations against the diff now on screen, reporting what
---the blob comparison invalidated.
function M.reconcile()
  if not V then
    return
  end
  local unmarked, staled = require("codereview.state").reconcile(V)
  local parts = {}
  if unmarked > 0 then
    parts[#parts + 1] = ("%d file%s changed since review"):format(unmarked, unmarked == 1 and "" or "s")
  end
  if staled > 0 then
    parts[#parts + 1] = require("codereview.queue").stale_phrase(staled)
  end
  if #parts > 0 then
    info(table.concat(parts, ", "))
  end
end

---@param spec string|nil nil cycles to the next scope this repository offers
function M.set_scope(spec)
  if not M.current() then
    return
  end
  if not spec then
    -- Asked per repository rather than read off a constant: which scopes are safe to walk
    -- blind depends on whether anything has ever been dispatched from this one.
    local cycle = git.cycle(V.root)
    local at = 1
    for i, name in ipairs(cycle) do
      if name == V.scope.name then
        at = i
        break
      end
    end
    spec = cycle[(at % #cycle) + 1]
  end

  local scope, err = git.resolve_scope(spec, V.root)
  if not scope then
    warn(err or ("cannot resolve scope: " .. spec))
    return
  end

  local cfg = config.get()
  local files, derr =
    git.collect(scope, V.root, { context = cfg.context, untracked = cfg.untracked, spans = cfg.spans })
  if not files then
    warn("git: " .. (derr or "diff failed"))
    return
  end

  V.scope = scope
  V.files = files
  -- Cached captures are keyed by path and side only, so they are meaningless once the
  -- refs behind those sides change.
  require("codereview.syntax").invalidate(V)
  local key = scope_key(scope)
  V.per_scope[key] = V.per_scope[key] or { reviewed = {}, expanded = {} }
  V.reviewed = V.per_scope[key].reviewed
  V.expanded = V.per_scope[key].expanded
  require("codereview.state").restore(V, key)
  queue_restored = true
  M.reconcile()

  if #files == 0 then
    info(("No changes in scope '%s'"):format(scope.label))
  end
  M.paint()
  place(1)
end

---Line in the current file that this row corresponds to.
---
---A deleted line does not exist in the working tree, so we fall back to the nearest
---preceding line that does -- landing on the code that replaced it rather than on an
---unrelated line that happens to share the number.
---@param file CRFile
---@param anchor CRAnchor
---@return integer
local function worktree_line(file, anchor)
  local hunk = file.hunks[anchor.hunk]
  if not hunk then
    return 1
  end
  local ln = hunk.lines[anchor.line]
  if ln and ln.new then
    return ln.new
  end
  for i = (anchor.line or 1) - 1, 1, -1 do
    if hunk.lines[i].new then
      return hunk.lines[i].new
    end
  end
  return math.max(1, hunk.new_start)
end

function M.open_file()
  local anchor = anchor_at_cursor()
  if not anchor then
    return
  end
  local file = V.files[anchor.file]
  local abs = vim.fs.joinpath(V.root, file.path)
  if vim.fn.filereadable(abs) == 0 then
    warn(("%s does not exist in the working tree"):format(file.path))
    return
  end
  local line = anchor.kind == "line" and worktree_line(file, anchor) or 1
  -- A new tab keeps the review intact: `gT` returns to exactly where you were.
  vim.cmd("tabedit " .. vim.fn.fnameescape(abs))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd("normal! zz")
end

---Hand a file and the refs its scope is between to the host's diff tool, and stop caring.
---
---The plugin ships no diff tool and keeps no opinion about which one this is, the same way
---it keeps none about delivery (ADR-0001): everything the host needs to fetch either image
---is in the spec, and what it does with them is its own. Nothing it opens has an anchor
---map, so this is a read-only detour -- there is nowhere in there to annotate from.
---@param file CRFile
---@param line integer|nil nil when the caller knows a file but no position in it
local function hand_to_diff(file, line)
  local adapter = config.get().open_diff
  if not adapter then
    -- Reachable only when a host bound this itself: the view binds no key without an
    -- adapter, precisely so that pressing one can never do nothing quietly.
    warn("No open_diff adapter configured")
    return
  end
  adapter({
    -- Absolute, because the spec carries no root to read a relative path against. From
    -- this the host can reach both the file and the repository it is in.
    path = vim.fs.joinpath(V.root, file.path),
    before = V.scope.before,
    -- nil when the post-image is the working tree, which is most scopes. Not an error and
    -- not worth a sentinel: nil says "the file on disk", which is what a diff tool would
    -- have opened anyway.
    after = V.scope.after,
    line = line,
  })
end

---`gd`: read the file under the cursor in the host's diff tool.
---
---At the line `<CR>` opens, deleted-line fallback and all -- one rule about where a diff
---row lands in the post-image, not two. A row that names no line hands over none rather
---than inventing line 1: a file header knows which file and nothing about where in it.
function M.open_diff()
  if not M.current() then
    return
  end
  local anchor = anchor_at_cursor()
  if not anchor then
    return
  end
  local file = V.files[anchor.file]
  hand_to_diff(file, anchor.kind == "line" and worktree_line(file, anchor) or nil)
end

--- Panel actions ---------------------------------------------------------------

---@return integer|nil file_index, string|nil dir_path, integer row
local function panel_at_cursor()
  if not (V.panel_render and V.panel_win and vim.api.nvim_win_is_valid(V.panel_win)) then
    return nil, nil, 0
  end
  local row = vim.api.nvim_win_get_cursor(V.panel_win)[1]
  return V.panel_render.row_file[row], V.panel_render.row_dir[row], row
end

---Keep the cursor on the same tree row across a repaint, so collapsing a directory does
---not fling the cursor to the top of the panel.
---@param row integer
local function keep_panel_cursor(row)
  if V.panel_win and vim.api.nvim_win_is_valid(V.panel_win) then
    local last = vim.api.nvim_buf_line_count(V.panel_buf)
    pcall(vim.api.nvim_win_set_cursor, V.panel_win, { math.min(row, last), 0 })
  end
end

---`<CR>`: open a file, or fold a directory.
function M.panel_select()
  local fi, dir, row = panel_at_cursor()
  if dir then
    V.collapsed[dir] = not V.collapsed[dir] or nil
    paint_panel()
    keep_panel_cursor(row)
    return
  end
  if not fi or not V.render.file_rows[fi] then
    return
  end
  -- Jumping to a reviewed file expands it: you asked to look at it.
  if V.expanded[V.files[fi].path] == false then
    V.expanded[V.files[fi].path] = true
    M.paint()
  end
  vim.api.nvim_set_current_win(V.win)
  goto_row(V.render.file_rows[fi], "zt")
end

---`gd` in the tree: read the file under the cursor in the host's diff tool.
---
---With no line. The tree knows which file you are looking at and nothing about where in
---it, and a row that is a directory names no file at all.
function M.panel_open_diff()
  if not M.current() then
    return
  end
  local fi = panel_at_cursor()
  if not fi then
    return
  end
  hand_to_diff(V.files[fi], nil)
end

---@param shut boolean|nil nil toggles
function M.panel_fold(shut)
  local _, dir, row = panel_at_cursor()
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
        paint_panel()
        keep_panel_cursor(r)
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
  paint_panel()
  keep_panel_cursor(row)
end

---@param shut boolean
function M.panel_fold_all(shut)
  if not M.current() then
    return
  end
  V.collapsed = {}
  if shut then
    for _, dir in ipairs(panel.dir_paths(panel.tree(V.files, { reviewed = V.reviewed, notes = V.notes }))) do
      V.collapsed[dir] = true
    end
  end
  paint_panel()
  keep_panel_cursor(1)
end

---Toggle reviewed from the tree. On a directory, this applies to the whole subtree --
---"I have read this package" is a thing you want to say in one keystroke.
function M.panel_toggle_reviewed()
  local fi, dir, row = panel_at_cursor()

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
    M.paint()
    M.persist()
    keep_panel_cursor(row)
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
  local file = V.files[fi]
  if V.reviewed[file.path] then
    V.reviewed[file.path] = nil
    V.expanded[file.path] = true
  else
    V.reviewed[file.path] = file.blob or ""
    V.expanded[file.path] = false
  end
  M.paint()
  M.persist()
  keep_panel_cursor(row)
end

---@param forward boolean
function M.panel_jump_file(forward)
  local _, _, row = panel_at_cursor()
  if not V.panel_render then
    return
  end
  local target = nearest(V.panel_render.file_rows, row, forward)
  if target then
    keep_panel_cursor(target)
  end
end

--- Delivery -------------------------------------------------------------------

---Choose where the batch goes, from a surface this module owns.
---
---The choice is delivery's; what is left here is windows. Delivery puts focus back in the
---window that asked, so all this adds is the case delivery cannot know about: that window
---being gone by the time the picker answers -- the queue float closed under it, say -- in
---which case the diff is where a reviewer belongs.
---@param on_done fun()|nil Runs after a target is chosen, once the picker has closed
function M.pick_target(on_done)
  local asked_from = vim.api.nvim_get_current_win()
  delivery.pick_target(function()
    if not vim.api.nvim_win_is_valid(asked_from) and M.current() then
      vim.api.nvim_set_current_win(V.win)
    end
    -- The winbar names the target, and the picker is asynchronous: repainting after
    -- `pick_target` returns paints before there is anything new to say.
    if V then
      update_winbar()
    end
    if on_done then
      on_done()
    end
  end)
end

---What the review a batch is going out of can say about itself, or nothing when there is
---no review at all.
---
---Handed over rather than read back: delivery knows nothing about views, and a batch that
---leaves with none open is answered from the working directory instead. Shared by submit
---and copy because the payload names this in its first line -- a copy assembled from a
---different context would differ from the send it stands in for by exactly that line.
---@return { root?: string, scope_label?: string, files?: integer, reviewed?: integer }
local function review_ctx()
  local V_ = M.current()
  if not V_ then
    return {}
  end

  local reviewed = 0
  for _ in pairs(V_.reviewed) do
    reviewed = reviewed + 1
  end
  return { root = V_.root, scope_label = V_.scope.label, files = #V_.files, reviewed = reviewed }
end

---Submit the batch, and put the windows back the way a sent batch leaves them.
---
---The rule -- restore, deliver, empty only on a dispatch -- is delivery's, because none of
---it is about a window and all of it happens with nothing open. What is left here is the
---float that was listing the batch, the diff behind it, and telling delivery what this
---review can say about itself.
function M.submit()
  -- Submitting empties the queue, so any open queue float is now describing nothing.
  if V and V.queue_win and vim.api.nvim_win_is_valid(V.queue_win) then
    vim.api.nvim_win_close(V.queue_win, true)
    V.queue_win = nil
  end

  local dispatched = delivery.submit(review_ctx())
  -- A batch that did not go is still queued and still drawn on the diff, so there is
  -- nothing to repaint -- and the reviewer has already been told why.
  if dispatched then
    M.paint()
  end
end

---Copy the batch to the clipboard, exactly as submitting would have rendered it.
---
---Nothing here does what submit does with the windows, because nothing was consumed: the
---queue still holds every entry, the diff still draws them, and a float listing them is
---still telling the truth. That is the whole difference between the two keys, and it is
---why this one leaves the surface alone.
function M.copy()
  delivery.copy(review_ctx())
end

--- The queue review float ------------------------------------------------------

---Put the cursor on the place a queued annotation is about.
---
---Says why not rather than doing nothing when it cannot, and says it differently each
---time: a **bare note** will never have a destination, a missing review view means open
---one, and a file the scope does not cover means change scope. One shared "cannot jump
---there" would name none of the three remedies.
---@param entry CRAnnotation
---@return boolean jumped Whether the cursor actually moved; false has already reported why
function M.jump_to_entry(entry)
  -- One queue holds both paths' entries, and the capture path can produce an annotation
  -- with no file behind it at all. Checked before the view, because opening a review would
  -- not give this one anywhere to go either.
  if entry.kind == "note" then
    info("A bare note is about no file — there is nowhere to jump to")
    return false
  end
  if not M.current() then
    info("No review view open — open one to jump to an annotation")
    return false
  end

  local index
  for i, file in ipairs(V.files) do
    if file.path == entry.path then
      index = i
      break
    end
  end
  -- An entry captured outside a checkout has no repository-relative path, so it names the
  -- only path it has and falls in here too: no scope of this review covers it.
  if not index then
    info(
      ("%s is not in the %s scope — change scope to jump to it"):format(entry.path or entry.abs_path, V.scope.label)
    )
    return false
  end

  -- A file collapsed because it is reviewed must open when you deliberately jump into it,
  -- otherwise the jump lands on a header with nothing beneath it -- the same courtesy the
  -- file picker extends. Reviewed with nothing recorded reads as collapsed too, which is
  -- how the render decides it.
  local expanded = V.expanded[entry.path]
  if expanded == nil then
    expanded = V.reviewed[entry.path] == nil
  end
  if not expanded then
    V.expanded[entry.path] = true
    M.paint()
  end

  -- The entry's key is already sided, so it also says which pane the annotation belongs to,
  -- and that pane's anchor map is the only one carrying it. No new rule: the same key that
  -- decides where the note is drawn decides where the jump lands.
  local to_before = has_before() and render.is_before_key(entry.key)
  local rendered = to_before and V.before_render or V.render

  -- The scan `]a` already makes: the anchor map is the only thing that knows which row a
  -- key is on now, which is what lets a stale annotation still land wherever its anchor
  -- points. A whole-file entry's key matches no line, and neither does a line that this
  -- diff no longer renders; both mean the file, so both land on its header.
  local row = rendered.file_rows[index]
  local file = V.files[index]
  for r, a in pairs(rendered.anchors) do
    if
      a.file == index
      and a.kind == "line"
      and render.line_key(file.path, file.hunks[a.hunk].lines[a.line]) == entry.key
    then
      row = r
      break
    end
  end

  vim.api.nvim_set_current_win(to_before and V.before_win or V.win)
  goto_row(row, "zz")
  return true
end

--- Rendering the queue as rows ------------------------------------------------

---Extmarks belonging to the float, in a namespace of its own so clearing them cannot
---disturb the diff's or the tree's.
local NS_QUEUE = vim.api.nvim_create_namespace("codereview_queue")

---One column to the left of every bar, reserved so a later change can put a selection
---marker there without moving anything. Nothing draws in it yet.
local GUTTER = " "

---Where a queued entry is, and what state rides on the right of its first row.
---
---Not `annotate.describe`, which folds the tag into the location because a composer title
---is one line with everything to say in it. A row has a right-hand column, so the tag reads
---as state rather than as part of the path -- and that column is where staleness now lives,
---instead of the `⚠` prefix that was this float's entire vocabulary for saying anything
---about an entry.
---@param entry CRAnnotation
---@return string where, { text: string, hl: string }[] state
local function entry_state(entry)
  local state = {}
  if entry.stale then
    state[#state + 1] = { text = "⚠ stale", hl = "CodeReviewStale" }
  end
  -- A bare note is about no file, so there is no location to print and no tag to print it
  -- with; every branch below reads a path this one does not have.
  if entry.kind == "note" then
    return "(no file)", state
  end
  -- Outside a checkout there is no repository-relative path, and the absolute one is the
  -- only name the file has.
  local where = entry.path or entry.abs_path
  if entry.kind == "file" then
    state[#state + 1] = { text = entry.tag or "whole file", hl = "CodeReviewQueueState" }
    return where, state
  end
  if entry.tag then
    state[#state + 1] = { text = entry.tag, hl = "CodeReviewQueueState" }
  end
  local range = entry.first == entry.last and tostring(entry.first) or ("%d-%d"):format(entry.first, entry.last)
  return ("%s:%s"):format(where, range), state
end

---Turn the queue into the float's rows.
---
---An entry is a run of rows carrying a bar in its annotation type's group -- its heading,
---its inlined diff block, every wrapped line of its note, and the blank lines *inside* that
---note. The blank row *between* two entries carries none. That is what makes the boundary
---hold whatever a note contains: once notes keep their own line structure, a blank line can
---no longer separate entries, because a note can contain one. It costs no extra rows over
---the flat list it replaces, and it makes an entry's type legible at every row rather than
---only where the reviewer happened to enter it.
---
---The bar is buffer text rather than an extmark, as the diff's change bar is. That is what
---keeps `rows` -- which maps *every* row to the entry owning it, not only the headings --
---trivially exact, so resolving the cursor stops being a nearest-heading-above guess and a
---reviewer can no longer drop something whose extent they cannot see.
---
---Its highlight columns are byte offsets, not display columns: the bar glyph is multibyte,
---and so is anything a host configures in its place.
---@param items CRAnnotation[]
---@param opts { types: CRType[], bar: string, width: integer }
---@return { lines: string[], marks: table[], rows: table<integer, integer> }
local function build_queue(items, opts)
  local lines, marks, rows = {}, {}, {}
  local bar = opts.bar
  local bar_col, bar_end = #GUTTER, #GUTTER + #bar
  -- Padded to the widest number in the batch, so entry 10 does not shift the column every
  -- row below it is drawn in.
  local digits = #tostring(#items)
  local indent = GUTTER .. bar .. (" "):rep(digits + 2)
  local body = math.max(8, opts.width - vim.fn.strdisplaywidth(indent))

  ---@param row integer 1-indexed
  ---@param col integer 0-indexed byte
  local function mark(row, col, o)
    marks[#marks + 1] = { row = row - 1, col = col, opts = o }
  end

  ---A row belonging to `entry`, carrying its bar and nothing else by default.
  ---@return integer row
  local function bar_row(id, group, text)
    lines[#lines + 1] = text
    rows[#lines] = id
    mark(#lines, bar_col, { end_col = bar_end, hl_group = group })
    return #lines
  end

  local index = 0
  -- The same helper the payload renders through, handed the same list: what the float
  -- shows and what the batch says have to be the one grouping, not two that agree today.
  for gi, group in ipairs(require("codereview.types").group(items, opts.types)) do
    if gi > 1 then
      lines[#lines + 1] = ""
    end
    local label = ("## %s"):format(group.type.label)
    local heading = label
    if group.type.directive and group.type.directive ~= "" then
      heading = heading .. (" — %s"):format(group.type.directive)
    end
    lines[#lines + 1] = heading
    -- Painted rather than inherited. The float used to set `filetype=markdown` and take
    -- whatever the `##` and `>` prefixes happened to attract, which coloured its chrome by
    -- accident and an entry's annotation type not at all.
    mark(#lines, 0, { end_col = #label, hl_group = "CodeReviewTitle" })
    if #heading > #label then
      mark(#lines, #label, { end_col = #heading, hl_group = "CodeReviewNote" })
    end

    -- A configured type always carries one; `types.UNTYPED` is not a configured type and
    -- has none, and falls back to what the diff draws an unresolvable type's note in.
    local bar_hl = group.type.hl or "CodeReviewNote"

    for ei, entry in ipairs(group.items) do
      index = index + 1
      -- Between entries and nowhere else: this row belongs to neither of them, which is
      -- exactly what makes the boundary visible.
      if ei > 1 then
        lines[#lines + 1] = ""
      end

      local where, state = entry_state(entry)
      local right = table.concat(
        vim.tbl_map(function(chunk)
          return chunk.text
        end, state),
        " · "
      )
      local room = body - (right ~= "" and vim.fn.strdisplaywidth(right) + 2 or 0)
      where = render.truncate(where, math.max(8, room))
      local head = GUTTER .. bar .. ("%" .. digits .. "d"):format(index) .. "  " .. where
      if right ~= "" then
        head = head .. (" "):rep(math.max(1, room - vim.fn.strdisplaywidth(where) + 2)) .. right
      end

      local row = bar_row(entry.id, bar_hl, head)
      mark(row, bar_end, { end_col = bar_end + digits, hl_group = "CodeReviewQueueIndex" })
      mark(row, #indent, { end_col = #indent + #where, hl_group = "CodeReviewFileHeader" })
      -- From the right, chunk by chunk: the pad before it is display width and the columns
      -- an extmark wants are bytes, so the only offset that can be counted on is the end.
      local col = #head
      for i = #state, 1, -1 do
        mark(row, col - #state[i].text, { end_col = col, hl_group = state[i].hl })
        col = col - #state[i].text - #" · "
      end

      -- The code an entry carries travels inside its bar. `+`/`-` already say which side a
      -- line is, so they are drawn in the colours the diff gives them.
      if entry.inline and entry.lines then
        for _, code in ipairs(entry.lines) do
          local text = indent .. render.truncate(code, body)
          local r = bar_row(entry.id, bar_hl, text)
          local sign = code:sub(1, 1)
          if sign == "+" or sign == "-" then
            mark(r, #indent, { end_col = #text, hl_group = sign == "+" and "CodeReviewAdd" or "CodeReviewDel" })
          end
        end
      end

      -- Kept as the reviewer wrote it: newlines used to be replaced with spaces before
      -- rendering, so prose that was structured read back as a run-on. Wrapped by display
      -- width, which is why the renderer's helper is shared rather than copied -- splitting
      -- by byte passes every ASCII assertion and corrupts the first CJK or emoji note.
      for _, text in ipairs(render.wrap(entry.note, body)) do
        -- A blank line inside a note is a bar and nothing after it, which is what keeps the
        -- entry unbroken across one.
        bar_row(entry.id, bar_hl, text == "" and (GUTTER .. bar) or (indent .. text))
      end
    end
  end

  return { lines = lines, marks = marks, rows = rows }
end

---List the queued annotations, drop any of them, then submit the batch.
function M.review_queue()
  local queue = require("codereview.queue")
  ensure_queue()
  if queue.count() == 0 then
    info("Queue is empty — annotate something first")
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(100, math.max(50, math.floor(vim.o.columns * 0.8)))
  local height = math.min(28, math.max(10, math.floor(vim.o.lines * 0.7)))
  local cfg_win = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = "",
    title_pos = "center",
    footer = "",
    footer_pos = "center",
  }

  local win = vim.api.nvim_open_win(buf, true, cfg_win)
  -- The rows wrap themselves, to a width they know, so that a bar keeps running down the
  -- left of every one of them. Letting the window wrap instead would fold a long line back
  -- to column zero, where there is no bar and no gutter, and the entry would appear to end.
  vim.wo[win].wrap = false
  -- Recorded so `submit` can close the float no matter which window it was triggered
  -- from; a submitted batch must never leave a dialog listing it still on screen.
  if V then
    V.queue_win = win
  end

  ---The rows on screen, and which entry each of them belongs to.
  local painted = { lines = {}, marks = {}, rows = {} }

  local function close()
    if V and V.queue_win == win then
      V.queue_win = nil
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function paint_queue()
    local cfg = config.get()
    painted = build_queue(queue.all(), {
      types = cfg.types,
      -- The change-bar vocabulary the diff already speaks, including when a host has
      -- configured a glyph of its own, so an entry's bar reads as structure rather than as
      -- decoration this surface invented.
      bar = cfg.icons.change_bar,
      width = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or width,
    })

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, painted.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, NS_QUEUE, 0, -1)
    for _, m in ipairs(painted.marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, NS_QUEUE, m.row, m.col, m.opts)
    end

    local n, stale = queue.count(), queue.stale_count()
    local name = delivery.target_label()
    cfg_win.title = (" Review queue · %d annotation%s%s "):format(
      n,
      n == 1 and "" or "s",
      stale > 0 and (" · %d stale"):format(stale) or ""
    )
    cfg_win.footer = (" ^T %s · ⏎ jump · x drop · gy copy · ^S submit · q close "):format(
      #name > 24 and (name:sub(1, 23) .. "…") or name
    )
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, cfg_win)
    end
  end

  ---The entry the cursor is on. Exact, because every row of an entry is mapped to it --
  ---a group heading and the blank row between two entries belong to none, and answer nil.
  local function entry_at_cursor()
    return painted.rows[vim.api.nvim_win_get_cursor(win)[1]]
  end

  ---Put the cursor back on an entry after a repaint.
  ---
  ---Dropping the last entry of a group leaves the cursor on the blank row that separated it
  ---from the next one, or on a heading -- rows that deliberately belong to nothing now that
  ---resolving one is exact. Without this, the second `x` of a run would silently do nothing.
  local function settle_cursor()
    local row = math.min(vim.api.nvim_win_get_cursor(win)[1], math.max(#painted.lines, 1))
    for _, range in ipairs({ { row, #painted.lines, 1 }, { row, 1, -1 } }) do
      for r = range[1], range[2], range[3] do
        if painted.rows[r] then
          pcall(vim.api.nvim_win_set_cursor, win, { r, 0 })
          return
        end
      end
    end
  end

  ---That entry as it sits in the queue.
  ---@param id integer|nil
  ---@return CRAnnotation|nil
  local function queued(id)
    for _, item in ipairs(queue.all()) do
      if item.id == id then
        return item
      end
    end
  end

  vim.keymap.set("n", "<CR>", function()
    local entry = queued(entry_at_cursor())
    if not entry then
      return
    end
    -- Only a jump that happened costs the list: a reviewer who pressed a key that could
    -- not act did not ask to lose what they were reading.
    if M.jump_to_entry(entry) then
      close()
    end
  end, { buffer = buf, desc = "Jump to the annotation" })

  vim.keymap.set("n", "x", function()
    local id = entry_at_cursor()
    if not id then
      return
    end
    queue.remove(id)
    if M.current() then
      M.paint()
      M.persist()
    end
    if queue.count() == 0 then
      close()
      info("Queue is now empty")
      return
    end
    paint_queue()
    settle_cursor()
  end, { buffer = buf, desc = "Drop annotation" })

  vim.keymap.set("n", "<C-t>", function()
    M.pick_target(paint_queue)
  end, { buffer = buf, desc = "Choose target" })

  -- Leaves the float open, where submitting closes it: what is on screen still describes
  -- the queue exactly, because copying took nothing out of it.
  vim.keymap.set("n", "gy", M.copy, { buffer = buf, desc = "Copy the batch to the clipboard" })

  vim.keymap.set("n", "<C-s>", function()
    close()
    M.submit()
  end, { buffer = buf, desc = "Submit the batch" })

  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close (keeps the queue)" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Close (keeps the queue)" })

  paint_queue()
end

function M.close()
  if V and vim.api.nvim_tabpage_is_valid(V.tab) then
    -- Closing the tab takes both windows and both scratch buffers with it.
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(V.tab))
  end
  V = nil
end

--- Setup -----------------------------------------------------------------------

---@param buf integer
---@param maps table<string, function|table>
local function bind(buf, maps)
  for lhs, rhs in pairs(maps) do
    local fn, desc, mode = rhs, "", "n"
    if type(rhs) == "table" then
      fn, desc, mode = rhs[1], rhs[2] or "", rhs[3] or "n"
    end
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
end

---Bind the diff's keys. Every pane gets the same set: which pane a reviewer happens to be
---in decides what a key acts on, never whether it works.
---@param buf integer
local function setup_main_keymaps(buf)
  -- Annotation keys are prefixed with `a` rather than bound bare. Bare `b`/`f`/`s`/`n`
  -- would shadow back-word, find-char and next-search inside the buffer; `a` (append) is
  -- dead in a nomodifiable buffer, so it costs a keystroke and no motion.
  local annotate = require("codereview.annotate")
  for _, t in ipairs(config.get().types) do
    vim.keymap.set({ "n", "x" }, "a" .. t.key, function()
      annotate.annotate(t.name)
    end, { buffer = buf, nowait = true, silent = true, desc = "Annotate: " .. t.name })
  end
  vim.keymap.set({ "n", "x" }, "aa", annotate.annotate_pick, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Annotate: pick type",
  })

  bind(buf, {
    ["x"] = { annotate.drop, "Drop the annotation here" },
    ["]f"] = {
      function()
        M.jump("file", true)
      end,
      "Next file",
    },
    ["[f"] = {
      function()
        M.jump("file", false)
      end,
      "Previous file",
    },
    ["]h"] = {
      function()
        M.jump("hunk", true)
      end,
      "Next hunk",
    },
    ["[h"] = {
      function()
        M.jump("hunk", false)
      end,
      "Previous hunk",
    },
    ["]F"] = {
      function()
        M.jump_unreviewed(true)
      end,
      "Next unreviewed file",
    },
    ["[F"] = {
      function()
        M.jump_unreviewed(false)
      end,
      "Previous unreviewed file",
    },
    ["]a"] = {
      function()
        M.jump_annotation(true)
      end,
      "Next annotation",
    },
    ["[a"] = {
      function()
        M.jump_annotation(false)
      end,
      "Previous annotation",
    },
    ["<C-p>"] = { M.pick_file, "Jump to a file" },
    ["<Tab>"] = { M.toggle_focus, "Focus the file tree" },
    ["R"] = { M.toggle_reviewed, "Toggle reviewed" },
    ["za"] = { M.toggle_expand, "Toggle expansion" },
    ["gs"] = {
      function()
        M.set_scope(nil)
      end,
      "Cycle scope",
    },
    ["gr"] = { M.refresh, "Reload the diff" },
    ["gp"] = { M.toggle_panel, "Show or hide the file tree" },
    -- From the `g` family the other view-level commands come from, and clear of `gt`/`gT`,
    -- which are how `<CR>`'s new tab is returned from.
    ["gl"] = { M.toggle_layout, "Switch between the unified and split layouts" },
    ["<CR>"] = { M.open_file, "Open the real file here" },
    ["Q"] = { M.review_queue, "Review the queue" },
    -- `gy`, not `Y`: yank is not dead in this buffer the way append is, and pulling a code
    -- line out of the diff is something reviewers do. From the same `g` family as the
    -- commands above, where it shadows nothing.
    ["gy"] = { M.copy, "Copy the batch to the clipboard" },
    ["<C-t>"] = { M.pick_target, "Choose the delivery target" },
    ["<C-s>"] = { M.submit, "Submit the batch" },
    ["q"] = { M.close, "Close the review" },
  })

  -- Only once the adapter is injected. Every adapter is nil by default, and a key that
  -- silently does nothing is worse than no key at all -- it also keeps `gd` free for
  -- whatever a host that wired no diff tool would rather have there. From the same `g`
  -- family as the commands above, and clear of `gt`/`gT`.
  if config.get().open_diff then
    bind(buf, { ["gd"] = { M.open_diff, "Read this file in the host's diff tool" } })
  end
end

local function setup_panel_keymaps()
  bind(V.panel_buf, {
    ["<CR>"] = { M.panel_select, "Open the file / fold the directory" },
    ["o"] = { M.panel_select, "Open the file / fold the directory" },
    ["za"] = {
      function()
        M.panel_fold(nil)
      end,
      "Toggle the directory",
    },
    ["l"] = {
      function()
        M.panel_fold(false)
      end,
      "Expand the directory",
    },
    ["zo"] = {
      function()
        M.panel_fold(false)
      end,
      "Expand the directory",
    },
    ["h"] = {
      function()
        M.panel_fold(true)
      end,
      "Collapse the directory / go to the parent",
    },
    ["zc"] = {
      function()
        M.panel_fold(true)
      end,
      "Collapse the directory",
    },
    ["zM"] = {
      function()
        M.panel_fold_all(true)
      end,
      "Collapse every directory",
    },
    ["zR"] = {
      function()
        M.panel_fold_all(false)
      end,
      "Expand every directory",
    },
    ["]f"] = {
      function()
        M.panel_jump_file(true)
      end,
      "Next file in the tree",
    },
    ["[f"] = {
      function()
        M.panel_jump_file(false)
      end,
      "Previous file in the tree",
    },
    ["<C-p>"] = { M.pick_file, "Jump to a file" },
    ["<Tab>"] = { M.toggle_focus, "Focus the diff" },
    ["gp"] = { M.toggle_panel, "Hide the file tree" },
    ["gl"] = { M.toggle_layout, "Switch between the unified and split layouts" },
    ["R"] = { M.panel_toggle_reviewed, "Toggle reviewed (whole subtree on a directory)" },
    ["q"] = { M.close, "Close the review" },
  })

  if config.get().open_diff then
    bind(V.panel_buf, { ["gd"] = { M.panel_open_diff, "Read this file in the host's diff tool" } })
  end
end

---@param buf integer
---@param name string
local function scratch(buf, name)
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
---@param buf integer
local function attach_pane(buf)
  setup_main_keymaps(buf)

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

  -- Both the diff's own marks and its highlighting are bounded by the viewport, so
  -- scrolling into rows nothing has been emitted onto is what emits them, and scrolling
  -- into an un-parsed file is what triggers its parse. One trigger for the two of them:
  -- they share a margin, so they come due at the same moment. Cheap on every other scroll --
  -- a band already emitted is a lookup, an already-painted file is skipped, and an
  -- already-parsed one repaints from cache.
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved" }, {
    group = V.augroup,
    buffer = buf,
    callback = function()
      if not M.current() then
        return
      end
      paint_bands()
      if config.get().syntax then
        require("codereview.syntax").apply(V, NS)
      end
      -- Keeps the tree pointed at whatever the diff cursor is reading. Cheap: it returns
      -- immediately unless the cursor crossed into a different file.
      sync_panel()
    end,
  })
end

---@param win integer
local function window_opts(win)
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
local function show_before_pane()
  vim.api.nvim_set_current_win(V.win)
  vim.cmd("leftabove vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  scratch(buf, "codereview")
  window_opts(win)
  V.before_buf, V.before_win = buf, win

  -- Both window-local. `scrollopt`, which decides what a bound window keeps in step, is
  -- global -- a plugin that set it would reach outside its own windows -- so it is left
  -- alone. Its default gives vertical synchronisation only, and horizontal scrolling
  -- staying independent per pane is accepted.
  for _, w in ipairs({ V.win, win }) do
    vim.wo[w].scrollbind = true
    vim.wo[w].cursorbind = true
  end

  attach_pane(buf)
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
local function hide_before_pane()
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
local function balance_panes()
  if not has_before() then
    return
  end
  local total = vim.api.nvim_win_get_width(V.before_win) + vim.api.nvim_win_get_width(V.win)
  pcall(vim.api.nvim_win_set_width, V.before_win, math.floor(total / 2))
end

--- The panel window ------------------------------------------------------------

---Build the panel: its window, its buffer and its keymaps.
---
---An operation of its own rather than a step inside `open`, because the toggle has to be
---able to run it again. The panel buffer is `bufhidden = "wipe"`, so a dismissed panel
---leaves nothing to re-attach: the buffer is gone and every keymap bound to it with it.
local function show_panel()
  local cfg = config.get()
  vim.api.nvim_set_current_win(V.win)
  vim.cmd(cfg.panel.position == "right" and "botright vsplit" or "topleft vsplit")
  local pwin = vim.api.nvim_get_current_win()
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(pwin, pbuf)
  scratch(pbuf, "codereviewpanel")
  window_opts(pwin)
  vim.api.nvim_win_set_width(pwin, cfg.panel.width)
  vim.wo[pwin].winfixwidth = true
  V.panel_buf, V.panel_win = pbuf, pwin
  setup_panel_keymaps()
  vim.api.nvim_set_current_win(V.win)
end

---Dismiss the panel. Collapsed directories are untouched: they live on the review.
local function hide_panel()
  local win = V.panel_win
  V.panel_buf, V.panel_win, V.panel_render = nil, nil, nil
  -- The tree follows the diff by repainting only when the cursor crosses into a different
  -- file. With no tree to repaint, that latch would sit on whatever was being read when it
  -- was dismissed, and reading that file again once it is back would repaint nothing.
  V.panel_current = nil
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
function M.toggle_panel()
  if not M.current() then
    return
  end
  if V.panel_win and vim.api.nvim_win_is_valid(V.panel_win) then
    hide_panel()
  else
    show_panel()
  end
  -- With three windows competing for the terminal's columns, the panel's arrival or
  -- departure is taken out of, or given back to, whichever pane Neovim picked. Split the
  -- difference so the two panes stay comparable, which is the whole point of the layout.
  balance_panes()
  -- The diff just changed width and its file headers are padded to that width, so this has
  -- to repaint. The resize autocmd does not cover it: WinResized is fired from the main
  -- loop, so it lands after the toggle has returned -- and never at all if nothing else
  -- pumps the loop, which is exactly the headless case.
  M.paint()
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
---@param anchor CRAnchor
---@return boolean
local function belongs_to_before(anchor)
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
function M.toggle_layout()
  if not M.current() then
    return
  end
  -- Read before the rebuild, from whichever pane has focus. Asked from the tree it answers
  -- for the after pane, which is where the diff cursor is.
  local anchor = anchor_at_cursor()
  local in_panel = V.panel_win ~= nil and vim.api.nvim_get_current_win() == V.panel_win

  if has_before() then
    hide_before_pane()
  else
    show_before_pane()
  end
  V.layout = has_before() and "split" or "unified"
  session_layout = V.layout

  -- The panes have just taken columns from each other, or handed them all back to one
  -- window, and a file header is padded to the width of the window drawing it -- so this
  -- repaints rather than leaning on the resize autocommand, which fires from the main loop
  -- and therefore lands after the toggle has returned.
  --
  -- No balancing beside it: a `vsplit` halves the window it splits, and closing one half
  -- gives its columns back to the other, so the two panes are already comparable. What is
  -- not is the panel arriving or leaving beside them, which is where `balance_panes` lives.
  M.paint()

  if not anchor then
    return
  end
  local to_before = has_before() and belongs_to_before(anchor)
  local rendered = to_before and V.before_render or V.render
  -- Focus follows the code, unless it was never in the diff to begin with: a reviewer who
  -- toggled from the tree asked for a different layout, not for a different window. Set
  -- either way rather than only when it moves, because building a pane takes focus to
  -- split the window and the tree has to be handed it back.
  vim.api.nvim_set_current_win(in_panel and V.panel_win or (to_before and V.before_win or V.win))
  goto_row(row_carrying(rendered, anchor), "zz")
end

--- Opening --------------------------------------------------------------------

---@param spec string|nil
function M.open(spec)
  hl.setup()
  local cfg = config.get()

  local root = git.root(vim.fn.getcwd())
  if not root then
    warn("not inside a git repository")
    return
  end

  local scope, err = git.resolve_scope(spec or "branch", root)
  if not scope then
    warn(err or "could not resolve the review scope")
    return
  end

  local files, derr = git.collect(scope, root, { context = cfg.context, untracked = cfg.untracked, spans = cfg.spans })
  if not files then
    warn("git: " .. (derr or "diff failed"))
    return
  end
  if #files == 0 then
    info(("No changes in scope '%s'"):format(scope.label))
    return
  end

  if M.current() then
    M.close()
  end

  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local main_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(main_win, buf)
  scratch(buf, "codereview")
  window_opts(main_win)

  local key = scope_key(scope)
  -- Configuration decides this only until a reviewer has said otherwise; from then on their
  -- choice does, for the rest of the session.
  local layout = opening_layout()
  V = {
    root = root,
    scope = scope,
    files = files,
    per_scope = { [key] = { reviewed = {}, expanded = {} } },
    reviewed = {},
    expanded = {},
    notes = {},
    syntax_cache = {},
    collapsed = {},
    buf = buf,
    win = main_win,
    layout = layout,
    tab = tab,
    augroup = vim.api.nvim_create_augroup("CodeReviewView", { clear = true }),
  }
  V.reviewed = V.per_scope[key].reviewed
  V.expanded = V.per_scope[key].expanded
  require("codereview.state").restore(V, key)
  queue_restored = true
  M.reconcile()

  -- Before the panel, so the panel's `topleft`/`botright` split lands outside both panes
  -- rather than between them.
  if layout == "split" then
    show_before_pane()
  end
  if cfg.panel.enabled then
    show_panel()
  end
  balance_panes()

  -- The before pane, if there is one, was given its own by `show_before_pane` -- which is
  -- also what gives it back to a pane the layout toggle rebuilt.
  attach_pane(V.buf)

  -- Header padding is width-dependent, so a resize needs a full repaint.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = V.augroup,
    callback = function()
      if M.current() then
        M.paint()
      end
    end,
  })

  M.paint()
  place(1)
end

return M
