---The review surface: buffers, windows, navigation.
---
---One view exists at a time, in its own tab page. Everything it draws comes from
---`render.lua`; everything it knows about position comes from that render's anchor map;
---and the keys that drive the actions exported here are declared in `keymaps.lua`, which
---is handed this module rather than requiring it. The **queue** float is `queue_float.lua`,
---handed this module the same way; what stays here is the jump from a queued **entry** into
---the diff, and the window a float is open in. Where the review's windows *are* is
---`view_layout.lua`, handed this module the same way again: the **panes**, the before pane,
---and the toggle between the two layouts. The single `V` below is what it mutates, and the
---two names it took out from under `keymaps.lua` and `annotate.lua` are re-exported here.
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
local keymaps = require("codereview.keymaps")
local queue_float = require("codereview.queue_float")
local view_layout = require("codereview.view_layout")

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
---@field collapsed table<string, boolean> Directory path -> folded shut in the file tree
---@field notes table<string, table[]>     Line key -> queued annotations
---@field archived table<string, table[]>  Line key -> archived entries; empty when off
---@field touched table<integer, boolean>  Archived entry id -> whether its file has moved
---@field untouched integer|nil            How many of those have not; nil when none were judged
---@field judged integer|nil               `state.archive_writes` the two above were judged at
---@field buf integer                     The after pane
---@field win integer                     The after pane
---@field before_buf integer|nil          nil in the unified layout
---@field before_win integer|nil          nil in the unified layout
---@field layout "unified"|"split"
---@field panel_buf integer|nil
---@field panel_win integer|nil
---@field queue_win integer|nil           The window a queue float is open in
---@field tab integer
---@field augroup integer                 Autocommands belonging to this review
---@field render CRRender|nil             The after pane's render
---@field before_render CRRender|nil      nil in the unified layout
---@field panel_render CRPanelRender|nil
---@field panel_current integer|nil       File index the tree is following; its repaint latch
---@field painted_bands table<integer, boolean>|nil  Row bands whose marks have been emitted
---@field syntax_cache table<string, CRCapture[]|false>  `path|side` -> captures; false to skip it
---@field syntax_painted table<string, boolean>|nil      Path -> already replayed onto this render
---@field syntax_rows table<integer, CRFileRows>|nil     File index -> where its lines are drawn

---@type CRView|nil
local V = nil

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

-- The panes are `view_layout.lua`, which is handed this module and the view it mutates.
-- What is left here is the one name that was exported from this module before the split:
-- `annotate.lua` reads the focused pane to resolve a target, and it should not have to
-- learn that the body moved.

---@return integer win, CRRender|nil render
function M.focused_pane()
  return view_layout.focused_pane(V)
end

--- Painting --------------------------------------------------------------------

---Index of the file the diff cursor is currently inside, for the panel's highlight.
---@return integer|nil
local function current_file_index()
  local win, rendered = view_layout.focused_pane(V)
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
  -- Read rather than computed: this runs on every paint, and a paint runs on every resize.
  -- The git behind the number is paid where the archive is judged, which is where the diff
  -- is read -- see `judge_archive`.
  if V.untouched then
    bar = bar .. (" · %d untouched"):format(V.untouched)
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
  if not view_layout.has_before(V) then
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
  -- And the archive is the source of truth for what has already gone, projected the same
  -- way onto the same anchors. Asked for on every paint rather than cached here, because
  -- the answer changes on a dispatch this view need not have made -- an **immediate send**
  -- archives a batch of one without emptying anything -- and the read behind it is a
  -- comparison until something has written.
  V.archived = cfg.archived and require("codereview.archive").by_key(V.root) or {}
  -- What was judged against an archive that has since been overtaken describes something
  -- else now: an **immediate send** archives a batch of one with no repaint of its own, so
  -- the entries below may belong to a batch nothing has judged. Dropped rather than
  -- recomputed, because judging is two git invocations and this runs on every resize --
  -- saying nothing until the next reconcile is the honest answer, and the winbar's segment
  -- goes with it.
  if V.judged ~= require("codereview.state").archive_writes() then
    V.touched, V.untouched = {}, nil
  end
  -- Both panes from one walk: their row counts and their anchors agree by construction
  -- rather than because two calls happened to be handed the same arguments.
  V.render, V.before_render = render.build(V.files, {
    width = vim.api.nvim_win_get_width(V.win),
    before_width = view_layout.has_before(V) and vim.api.nvim_win_get_width(V.before_win) or nil,
    layout = view_layout.has_before(V) and "split" or "unified",
    icons = cfg.icons,
    expanded = V.expanded,
    reviewed = V.reviewed,
    notes = V.notes,
    archived = V.archived,
    touched = V.touched,
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
    view_layout.place(V, V.render.file_rows[keep_file])
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

  view_layout.resync(V)
end

---Everything a moved cursor comes due for, in the order it comes due.
---
---Both the diff's own marks and its highlighting are bounded by the viewport, so
---scrolling into rows nothing has been emitted onto is what emits them, and scrolling
---into an un-parsed file is what triggers its parse. One trigger for the two of them:
---they share a margin, so they come due at the same moment. Cheap on every other scroll --
---a band already emitted is a lookup, an already-painted file is skipped, and an
---already-parsed one repaints from cache.
---
---Exported so that the autocommand driving it wires one name rather than reaching into
---three internals at once. It runs on every keystroke a reviewer holds, so the guards
---here are what keep it cheap rather than decoration around it.
function M.cursor_moved()
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

--- Cursor queries --------------------------------------------------------------

---Row the cursor is on, in whichever pane has focus. The two agree row for row, so this
---is a question about the cursor rather than about the layout.
---@return integer
local function cursor_row()
  local win = view_layout.focused_pane(V)
  return vim.api.nvim_win_get_cursor(win)[1]
end

---@return CRAnchor|nil
local function anchor_at_cursor()
  local win, rendered = view_layout.focused_pane(V)
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
---
---Exported because the layout toggle lands a cursor the same way every jump here does, and
---it is the one arrival the two halves of this share: placing the panes is
---`view_layout.lua`'s and following the diff with the tree is this module's, so the pair is
---glued where the view that owns both is.
---@param row integer
---@param cmd string|nil `zt`, `zz`, or nil to leave the window where it is
local function goto_row(row, cmd)
  view_layout.place(V, row, cmd)
  sync_panel()
end

M.goto_row = goto_row

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
  if view_layout.has_before(V) and owner[row] and vim.api.nvim_get_current_win() ~= V.before_win then
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

---Ask which of the last batch's files the agent has been in since it went.
---
---Kept apart from the reconciliation below, and reported through the winbar rather than a
---sentence, because it says nothing a reviewer has to act on: *stale* means a note may now
---be wrong, *untouched* only means a file has not moved. The computation is `state`'s,
---beside the staleness rule it parallels rather than joins.
---
---Called where the diff is read -- opening, refreshing, changing scope, and this view's own
---submit -- and never from a paint, which also runs on every resize.
local function judge_archive()
  -- Submitting reaches here with nothing open: a batch is not a window, and it can go out
  -- of a session that never opened a review at all.
  if not V then
    return
  end
  if not config.get().archived then
    -- One switch turns the archive off in the review view outright: nothing drawn, nothing
    -- tallied, and no git spent deciding either.
    V.touched, V.untouched, V.judged = {}, nil, nil
    return
  end
  local state = require("codereview.state")
  V.touched, V.untouched = state.reconcile_archive(V.root, V.files)
  V.judged = state.archive_writes()
end

---Re-check reviewed marks and annotations against the diff now on screen, reporting what
---the blob comparison invalidated.
function M.reconcile()
  if not V then
    return
  end
  judge_archive()
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
  M.reconcile()

  if #files == 0 then
    info(("No changes in scope '%s'"):format(scope.label))
  end
  M.paint()
  view_layout.place(V, 1)
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
    -- The batch that just went was snapshotted a moment ago, so every one of its entries is
    -- untouched and the winbar should say so immediately. Judged here rather than left to
    -- the next reconcile because a submit is the one moment a reviewer looks for that
    -- number, and because the archive underneath it has certainly moved.
    judge_archive()
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

--- The queue float --------------------------------------------------------------

-- The float itself is `queue_float.lua`, which is handed this module. What is left here is
-- what is about the view rather than about the queue: the jump into the diff, and the
-- window a float is open in.

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
  local to_before = view_layout.has_before(V) and render.is_before_key(entry.key)
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

---Record the window a queue float has opened in.
---
---Kept here rather than on the float because closing it on a submit is a rule about this
---module's windows: `submit` runs from either pane as readily as from the float, and a
---batch that has gone must never leave a dialog listing it on screen.
---
---Against whatever view there is rather than `M.current()`, which answers nil once the
---review's own window has gone: the float outlives that, and is still a window to close.
---@param win integer
function M.hold_queue_float(win)
  if V then
    V.queue_win = win
  end
end

---Forget that window, if it is still the one recorded.
---
---Guarded rather than cleared outright: a float that closes after a later one opened would
---otherwise leave the view holding nothing while a float is still on screen.
---@param win integer
function M.release_queue_float(win)
  if V and V.queue_win == win then
    V.queue_win = nil
  end
end

---List the queued annotations, drop any of them, then submit the batch.
---
---The surface is `queue_float`'s; what stays here is the name a host's command and the `Q`
---key already bind, and this module handing itself in for the actions the float drives.
function M.review_queue()
  queue_float.open(M)
end

function M.close()
  if V and vim.api.nvim_tabpage_is_valid(V.tab) then
    -- Closing the tab takes both windows and both scratch buffers with it.
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(V.tab))
  end
  V = nil
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
  view_layout.scratch(pbuf, "codereviewpanel")
  view_layout.window_opts(pwin)
  vim.api.nvim_win_set_width(pwin, cfg.panel.width)
  vim.wo[pwin].winfixwidth = true
  V.panel_buf, V.panel_win = pbuf, pwin
  keymaps.panel(pbuf, M)
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
  view_layout.balance_panes(V)
  -- The diff just changed width and its file headers are padded to that width, so this has
  -- to repaint. The resize autocmd does not cover it: WinResized is fired from the main
  -- loop, so it lands after the toggle has returned -- and never at all if nothing else
  -- pumps the loop, which is exactly the headless case.
  M.paint()
end

--- The layout ------------------------------------------------------------------

-- The layouts, and everything the switch between them carries across, are
-- `view_layout.lua`. What is left here is the name `keymaps.lua` binds to `gl` in both the
-- diff and the tree, so that the key table does not learn where the body moved to.

function M.toggle_layout()
  view_layout.toggle_layout(V, M)
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
  view_layout.scratch(buf, "codereview")
  view_layout.window_opts(main_win)

  local key = scope_key(scope)
  -- Configuration decides this only until a reviewer has said otherwise; from then on their
  -- choice does, for the rest of the session.
  local layout = view_layout.opening_layout()
  V = {
    root = root,
    scope = scope,
    files = files,
    per_scope = { [key] = { reviewed = {}, expanded = {} } },
    reviewed = {},
    expanded = {},
    notes = {},
    archived = {},
    touched = {},
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
  M.reconcile()

  -- Before the panel, so the panel's `topleft`/`botright` split lands outside both panes
  -- rather than between them.
  if layout == "split" then
    view_layout.show_before_pane(V, M)
  end
  if cfg.panel.enabled then
    show_panel()
  end
  view_layout.balance_panes(V)

  -- The before pane, if there is one, was given its own by `show_before_pane` -- which is
  -- also what gives it back to a pane the layout toggle rebuilt.
  view_layout.attach_pane(V, M, V.buf)

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
  view_layout.place(V, 1)
end

return M
