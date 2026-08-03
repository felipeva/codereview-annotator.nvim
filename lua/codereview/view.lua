---The review surface: buffers, windows, keymaps, navigation.
---
---One view exists at a time, in its own tab page. Everything it draws comes from
---`render.lua`; everything it knows about position comes from that render's anchor map.
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
---@field buf integer
---@field win integer
---@field panel_buf integer|nil
---@field panel_win integer|nil
---@field tab integer
---@field render CRRender|nil
---@field panel_render CRPanelRender|nil

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

--- Painting --------------------------------------------------------------------

---Index of the file the diff cursor is currently inside, for the panel's highlight.
---@return integer|nil
local function current_file_index()
  if not (V.render and vim.api.nvim_win_is_valid(V.win)) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(V.win)[1]
  for r = row, 1, -1 do
    if V.render.anchors[r] then
      return V.render.anchors[r].file
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
  V.render = render.build(V.files, {
    width = vim.api.nvim_win_get_width(V.win),
    icons = cfg.icons,
    expanded = V.expanded,
    reviewed = V.reviewed,
    notes = V.notes,
    types = cfg.types,
  })

  vim.bo[V.buf].modifiable = true
  vim.api.nvim_buf_set_lines(V.buf, 0, -1, false, V.render.lines)
  vim.bo[V.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(V.buf, NS, 0, -1)
  for _, m in ipairs(V.render.marks) do
    -- An end_col past the end of a line is a hard error; a mis-measured header should
    -- lose its colour, not abort the whole repaint.
    pcall(vim.api.nvim_buf_set_extmark, V.buf, NS, m.row, m.col, m.opts)
  end

  paint_panel()
  update_winbar()

  if keep_file and V.render.file_rows[keep_file] then
    pcall(vim.api.nvim_win_set_cursor, V.win, { V.render.file_rows[keep_file], 0 })
  end

  if config.get().syntax then
    local syntax = require("codereview.syntax")
    -- The namespace was just cleared, so nothing is painted any more -- but the parsed
    -- captures behind it are still good.
    syntax.reset_painted(V)
    syntax.apply(V, NS)
  end
end

---The repository the queue belongs to when no view is open.
---@return string|nil
local function ambient_root()
  return git.root(vim.fn.getcwd())
end

---Write progress to disk. Called from every mutation rather than from `paint`, which
---also runs on resize and would turn a window drag into a stream of file writes.
---
---With a view, that means the reviewed marks and the queue together. Without one, only
---the queue -- there are no marks to write, and writing the document anyway would blank
---the ones a review left behind.
function M.persist()
  if V then
    require("codereview.state").persist(V)
    return
  end
  -- Passed even when nil: there may still be annotations with no repository to write, and
  -- skipping would leave a submitted batch's entries on disk to come back next start.
  require("codereview.state").persist_queue(ambient_root())
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
    info(("%d annotation%s now stale"):format(staled, staled == 1 and "" or "s"))
  end
end

--- Cursor queries --------------------------------------------------------------

---@return CRAnchor|nil
local function anchor_at_cursor()
  if not V.render then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(V.win)[1]
  -- Walk upward: a blank padding row still belongs to the file above it, so a cursor
  -- resting in whitespace resolves to something sensible rather than nothing.
  for r = row, 1, -1 do
    if V.render.anchors[r] then
      return V.render.anchors[r], r
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
---@param row integer
---@param top boolean
local function goto_row(row, top)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  if top then
    vim.api.nvim_win_call(V.win, function()
      vim.cmd("normal! zt")
    end)
  end
  sync_panel()
end

---@param what "file"|"hunk"
---@param forward boolean
function M.jump(what, forward)
  if not M.current() or not V.render then
    return
  end
  local rows = what == "file" and V.render.file_rows or V.render.hunk_rows
  local cur = vim.api.nvim_win_get_cursor(V.win)[1]
  local row = nearest(rows, cur, forward)
  if not row then
    info(("No %s %s here"):format(forward and "next" or "previous", what))
    return
  end
  goto_row(row, what == "file")
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

  local cur = vim.api.nvim_win_get_cursor(V.win)[1]
  local row = nearest(rows, cur, forward)
  if not row then
    -- Wrap: with the reviewed files skipped there are few targets left, and stopping dead
    -- at the last one means scrolling back by hand.
    row = forward and rows[1] or rows[#rows]
    info(forward and "Wrapped to the first unreviewed file" or "Wrapped to the last unreviewed file")
  end
  goto_row(row, true)
end

---Jump to the next or previous annotated line.
---@param forward boolean
function M.jump_annotation(forward)
  if not M.current() or not V.render then
    return
  end
  local render = require("codereview.render")
  local rows = {}
  for row, a in pairs(V.render.anchors) do
    local file = V.files[a.file]
    local key
    if a.kind == "line" then
      key = render.line_key(file.path, file.hunks[a.hunk].lines[a.line])
    elseif a.kind == "file" then
      key = render.file_key(file.path)
    end
    if key and V.notes[key] then
      rows[#rows + 1] = row
    end
  end
  if #rows == 0 then
    info("No annotations yet")
    return
  end
  table.sort(rows)

  local cur = vim.api.nvim_win_get_cursor(V.win)[1]
  local row = nearest(rows, cur, forward) or (forward and rows[1] or rows[#rows])
  goto_row(row, false)
  vim.api.nvim_win_call(V.win, function()
    vim.cmd("normal! zz")
  end)
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
      goto_row(V.render.file_rows[index], true)
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
  local files, err = git.collect(V.scope, V.root, { context = cfg.context, untracked = cfg.untracked })
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
    parts[#parts + 1] = ("%d annotation%s now stale"):format(staled, staled == 1 and "" or "s")
  end
  if #parts > 0 then
    info(table.concat(parts, ", "))
  end
end

---@param spec string|nil nil cycles to the next scope in git.CYCLE
function M.set_scope(spec)
  if not M.current() then
    return
  end
  if not spec then
    local at = 1
    for i, name in ipairs(git.CYCLE) do
      if name == V.scope.name then
        at = i
        break
      end
    end
    spec = git.CYCLE[(at % #git.CYCLE) + 1]
  end

  local scope, err = git.resolve_scope(spec, V.root)
  if not scope then
    warn(err or ("cannot resolve scope: " .. spec))
    return
  end

  local cfg = config.get()
  local files, derr = git.collect(scope, V.root, { context = cfg.context, untracked = cfg.untracked })
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
  pcall(vim.api.nvim_win_set_cursor, V.win, { 1, 0 })
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
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
  vim.api.nvim_win_call(V.win, function()
    vim.cmd("normal! zt")
  end)
  sync_panel()
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

---Render the queue and hand it to the send adapter.
function M.submit()
  local queue = require("codereview.queue")

  ensure_queue()
  if queue.count() == 0 then
    info("Queue is empty — annotate something first")
    return
  end

  -- Submitting empties the queue, so any open queue float is now describing nothing.
  if V and V.queue_win and vim.api.nvim_win_is_valid(V.queue_win) then
    vim.api.nvim_win_close(V.queue_win, true)
    V.queue_win = nil
  end

  local V_ = M.current()
  local reviewed = 0
  if V_ then
    for _ in pairs(V_.reviewed) do
      reviewed = reviewed + 1
    end
  end

  local count = queue.count()
  -- Read unconditionally: the target outlives any view, and there may not be one.
  local target = delivery.target()
  if
    not delivery.deliver(queue.all(), target, {
      -- Handed over rather than read back: delivery knows nothing about views, and a batch
      -- submitted with none open is answered from the working directory instead.
      root = V_ and V_.root or nil,
      scope_label = V_ and V_.scope.label or nil,
      files = V_ and #V_.files or nil,
      reviewed = reviewed,
    })
  then
    return
  end
  queue.clear()
  if M.current() then
    M.paint()
  end
  -- Outside the `M.current()` guard: a batch submitted with no view still has to write the
  -- emptied queue, or the entries it just sent come back on the next start.
  M.persist()
  info(
    ("Submitted %d annotation%s to %s"):format(
      count,
      count == 1 and "" or "s",
      target and (target.short or "agent") or "local"
    )
  )
end

--- The queue review float ------------------------------------------------------

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
  vim.bo[buf].filetype = "markdown"

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
  vim.wo[win].wrap = true
  -- Recorded so `submit` can close the float no matter which window it was triggered
  -- from; a submitted batch must never leave a dialog listing it still on screen.
  if V then
    V.queue_win = win
  end

  ---Rendered row of each entry's heading, so `x` can map a cursor position back to it.
  local anchors = {}

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
    local lines = {}
    anchors = {}
    local index = 0
    -- The same helper the payload renders through, handed the same list: what the float
    -- shows and what the batch says have to be the one grouping, not two that agree today.
    for _, group in ipairs(require("codereview.types").group(queue.all(), cfg.types)) do
      local heading = ("## %s"):format(group.type.label)
      if group.type.directive and group.type.directive ~= "" then
        heading = heading .. (" — %s"):format(group.type.directive)
      end
      lines[#lines + 1] = heading
      for _, entry in ipairs(group.items) do
        index = index + 1
        anchors[#lines + 1] = entry.id
        local where = require("codereview.annotate").describe(entry)
        lines[#lines + 1] = ("%d. %s%s %s"):format(index, entry.stale and "⚠ " or "", group.type.icon, where)
        if entry.inline and entry.lines then
          for _, d in ipairs(entry.lines) do
            lines[#lines + 1] = "   " .. d
          end
        end
        lines[#lines + 1] = "   > " .. entry.note:gsub("\n", " ")
      end
      lines[#lines + 1] = ""
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local n, stale = queue.count(), queue.stale_count()
    local name = delivery.target_label()
    cfg_win.title = (" Review queue · %d annotation%s%s "):format(
      n,
      n == 1 and "" or "s",
      stale > 0 and (" · %d stale"):format(stale) or ""
    )
    cfg_win.footer = (" ^T %s · x drop · ^S submit · q close "):format(
      #name > 24 and (name:sub(1, 23) .. "…") or name
    )
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, cfg_win)
    end
  end

  ---The entry the cursor is inside: the nearest heading at or above it.
  local function entry_at_cursor()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local best
    for anchor, id in pairs(anchors) do
      if anchor <= row and (not best or anchor > best.anchor) then
        best = { anchor = anchor, id = id }
      end
    end
    return best and best.id or nil
  end

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
  end, { buffer = buf, desc = "Drop annotation" })

  vim.keymap.set("n", "<C-t>", function()
    M.pick_target(paint_queue)
  end, { buffer = buf, desc = "Choose target" })

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

local function setup_main_keymaps()
  -- Annotation keys are prefixed with `a` rather than bound bare. Bare `b`/`f`/`s`/`n`
  -- would shadow back-word, find-char and next-search inside the buffer; `a` (append) is
  -- dead in a nomodifiable buffer, so it costs a keystroke and no motion.
  local annotate = require("codereview.annotate")
  for _, t in ipairs(config.get().types) do
    vim.keymap.set({ "n", "x" }, "a" .. t.key, function()
      annotate.annotate(t.name)
    end, { buffer = V.buf, nowait = true, silent = true, desc = "Annotate: " .. t.name })
  end
  vim.keymap.set({ "n", "x" }, "aa", annotate.annotate_pick, {
    buffer = V.buf,
    nowait = true,
    silent = true,
    desc = "Annotate: pick type",
  })

  bind(V.buf, {
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
    ["<CR>"] = { M.open_file, "Open the real file here" },
    ["Q"] = { M.review_queue, "Review the queue" },
    ["<C-t>"] = { M.pick_target, "Choose the delivery target" },
    ["<C-s>"] = { M.submit, "Submit the batch" },
    ["q"] = { M.close, "Close the review" },
  })
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
    ["R"] = { M.panel_toggle_reviewed, "Toggle reviewed (whole subtree on a directory)" },
    ["q"] = { M.close, "Close the review" },
  })
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

  local files, derr = git.collect(scope, root, { context = cfg.context, untracked = cfg.untracked })
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
    tab = tab,
  }
  V.reviewed = V.per_scope[key].reviewed
  V.expanded = V.per_scope[key].expanded
  require("codereview.state").restore(V, key)
  queue_restored = true
  M.reconcile()

  if cfg.panel.enabled then
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
    vim.api.nvim_set_current_win(main_win)
  end

  setup_main_keymaps()

  local augroup = vim.api.nvim_create_augroup("CodeReviewView", { clear = true })

  -- Header padding is width-dependent, so a resize needs a full repaint.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = augroup,
    callback = function()
      if M.current() then
        M.paint()
      end
    end,
  })

  -- The review buffer is nomodifiable, so insert mode is never meaningful in it. It can
  -- still be arrived at while already inserting: a composer opened with `startinsert` and
  -- submitted from an insert-mode mapping closes its window without ending insert, and
  -- focus lands here mid-insert -- no InsertEnter fires, because insert never ended.
  -- Every navigation key is then a failed edit rather than a motion.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "InsertEnter" }, {
    group = augroup,
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

  -- Highlighting is bounded by the viewport, so scrolling into an un-parsed file is what
  -- triggers its parse. Cheap on every other scroll: already-painted files are skipped
  -- and already-parsed ones repaint from cache.
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved" }, {
    group = augroup,
    buffer = buf,
    callback = function()
      if not M.current() then
        return
      end
      if config.get().syntax then
        require("codereview.syntax").apply(V, NS)
      end
      -- Keeps the tree pointed at whatever the diff cursor is reading. Cheap: it returns
      -- immediately unless the cursor crossed into a different file.
      sync_panel()
    end,
  })

  M.paint()
  vim.api.nvim_win_set_cursor(main_win, { 1, 0 })
end

return M
