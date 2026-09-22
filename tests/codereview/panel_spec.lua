-- The folder-tree panel: how the tree is built, folded, reviewed and navigated.
--
-- These assertions are structural, so they depend on exactly which files the nested
-- fixture contains. Regenerate it with tests/fixtures/mktree.sh rather than hand-editing
-- a fixture repo -- adding or omitting one file changes what compacts.
local h = require("tests.helpers")

h.ui(120, 45)
-- Kept, because the footer bar's painted cells are read in child processes that open this
-- same review over this same repository.
local fixture = h.cd_fixture("mktree")

require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept, _)
    on_accept(nil, "n")
  end,
})

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")
local panel = require("codereview.panel")

view.open("branch")
local V = view.current()
queue.clear()

local function panel_lines()
  return vim.api.nvim_buf_get_lines(V.panel_buf, 0, -1, false)
end

local function pcur(row)
  vim.api.nvim_win_set_cursor(V.panel_win, { row, 0 })
end

local function row_of_dir(dir)
  for r, d in pairs(V.panel_render.row_dir) do
    if d == dir then
      return r
    end
  end
end

local function row_of_file(path)
  local i = h.file_index(V, path)
  return i and V.panel_render.file_row[i]
end

describe("tree structure", function()
  it("gives every file a row", function()
    assert.same(#V.files, #V.panel_render.file_rows)
  end)

  it("gives directories rows of their own", function()
    assert.is_true(vim.tbl_count(V.panel_render.row_dir) > 0)
  end)

  -- apps/api holds only src, which holds main.lua and routes/ -- so the chain compacts to
  -- a single row and the empty intermediate disappears.
  it("compacts single-child directory chains", function()
    assert.is_not_nil(row_of_dir("apps/api/src"))
    assert.is_not_nil(row_of_dir("packages/shared/src"))
    assert.is_nil(row_of_dir("apps/api"))
  end)

  it("does not compact a directory with two children", function()
    assert.is_not_nil(row_of_dir("apps"))
  end)

  it("sorts directories before files, alphabetically", function()
    local top = {}
    for i, l in ipairs(panel_lines()) do
      if (V.panel_render.row_depth[i] or 99) == 0 then
        -- What a row is *named*, with the right margin taken off it: a directory's tally, or
        -- a file's `+N -M` **stat**.
        top[#top + 1] = vim.trim((l:gsub("%s+%d+/%d+%s*$", ""):gsub("%s+%+%d+ %-%d+%s*$", "")))
      end
    end
    assert.same({ "▾ apps", "▾ docs", "▾ packages/shared/src", "○ README.md" }, top)
  end)

  it("shows basenames and lets the tree carry the path", function()
    local line = panel_lines()[row_of_file("apps/api/src/main.lua")]
    assert.is_truthy(line:find("main.lua", 1, true))
    assert.is_truthy(line:match("^%s+"))
  end)
end)

describe("directory tallies", function()
  -- Derived, not hardcoded: the tally must equal the files actually under that prefix.
  local apps_n = #panel.files_under(V.files, "apps")

  it("shows a subtree tally on a directory row", function()
    assert.same(("0/%d"):format(apps_n), panel_lines()[row_of_dir("apps")]:match("(%d+/%d+)%s*$"))
  end)

  -- The tally heads the footer row rather than being the whole of it: the progress bar
  -- takes the columns after it. What the bar draws is the last block in this file.
  it("shows the root tally in the footer", function()
    local lines = panel_lines()
    assert.same(("0/%d reviewed"):format(#V.files), lines[#lines]:match("^%d+/%d+ reviewed"))
  end)

  it("moves the footer when a file is reviewed", function()
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[1], 0 })
    view.toggle_reviewed()
    local lines = panel_lines()
    assert.same(("1/%d reviewed"):format(#V.files), lines[#lines]:match("^%d+/%d+ reviewed"))
    view.toggle_reviewed()
  end)
end)

describe("folding", function()
  local before = #panel_lines()

  it("<CR> on a directory collapses it", function()
    pcur(row_of_dir("apps"))
    view.panel_select()
    assert.is_true(#panel_lines() < before)
    assert.is_truthy(panel_lines()[row_of_dir("apps")]:find("▸", 1, true))
    assert.is_nil(row_of_file("apps/api/src/main.lua"))
  end)

  it("keeps the cursor on the directory", function()
    assert.same(row_of_dir("apps"), vim.api.nvim_win_get_cursor(V.panel_win)[1])
  end)

  it("<CR> again expands it", function()
    view.panel_select()
    assert.same(before, #panel_lines())
  end)

  it("h collapses and l expands", function()
    pcur(row_of_dir("apps"))
    view.panel_fold(true)
    assert.is_true(V.collapsed["apps"])
    view.panel_fold(false)
    assert.is_nil(V.collapsed["apps"])
  end)

  -- The parent of a file row has to be found by depth, not by proximity: the nearest
  -- directory row above a file is very often a sibling it has already scrolled past.
  it("h on a file folds its own parent, not the sibling above it", function()
    pcur(row_of_file("apps/web/src/index.lua"))
    view.panel_fold(true)
    assert.is_true(V.collapsed["apps/web/src"])
    assert.is_nil(V.collapsed["apps/web/src/components"])
    V.collapsed = {}
    view.panel_select() -- repaint
  end)

  it("zM collapses every directory and zR expands them", function()
    view.panel_fold_all(true)
    assert.is_nil(row_of_file("apps/api/src/main.lua"))
    view.panel_fold_all(false)
    assert.is_not_nil(row_of_file("apps/api/src/main.lua"))
  end)
end)

describe("reviewing a whole subtree", function()
  local under = panel.files_under(V.files, "apps")
  local apps_n = #under

  pcur(row_of_dir("apps"))
  view.panel_toggle_reviewed()

  it("marks every file under the directory", function()
    for _, i in ipairs(under) do
      assert.is_not_nil(V.reviewed[V.files[i].path], V.files[i].path .. " was not marked")
    end
  end)

  it("leaves files outside it untouched", function()
    assert.is_nil(V.reviewed["README.md"])
  end)

  it("reads as fully reviewed in the tally", function()
    assert.same(("%d/%d"):format(apps_n, apps_n), panel_lines()[row_of_dir("apps")]:match("(%d+/%d+)%s*$"))
  end)

  it("unmarks the subtree when pressed again", function()
    view.panel_toggle_reviewed()
    assert.same(0, vim.tbl_count(V.reviewed))
  end)
end)

describe("navigating the diff", function()
  it("]f walks every file, reviewed or not", function()
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    view.jump("file", true)
    assert.same(V.render.file_rows[2], vim.api.nvim_win_get_cursor(V.win)[1])
  end)

  it("]F skips reviewed files", function()
    for i = 1, 3 do
      V.reviewed[V.files[i].path] = V.files[i].blob
      V.expanded[V.files[i].path] = false
    end
    view.paint()

    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    view.jump_unreviewed(true)
    local anchor = V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]]
    assert.same(4, anchor.file)
    assert.same("file", anchor.kind)
  end)

  it("]F wraps rather than dead-ending on the last file", function()
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[#V.files], 0 })
    view.jump_unreviewed(true)
    assert.same(4, V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].file)

    V.reviewed = {}
    V.expanded = {}
    view.paint()
  end)

  it("]a jumps to an annotated line", function()
    queue.clear()
    local target = assert(h.line_row(V, "packages/shared/src/types.lua"))
    vim.api.nvim_win_set_cursor(V.win, { target, 0 })
    annotate.annotate("bug")

    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    view.jump_annotation(true)
    local anchor = V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]]
    assert.same("packages/shared/src/types.lua", V.files[anchor.file].path)
  end)

  -- The count itself left the file row with #242 and its columns went to the **stat**; what
  -- says a file holds something is the **state** mark, and what kind of thing is its colour.
  it("marks that file as annotated in the tree", function()
    local line = panel_lines()[row_of_file("packages/shared/src/types.lua")]
    assert.same("●", vim.trim(line):sub(1, #"●"))
  end)
end)

describe("panel and diff staying in sync", function()
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[5], 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })

  it("follows the diff cursor", function()
    assert.same(5, V.current_file)
  end)

  it("highlights exactly the current file's row", function()
    local sel = vim.tbl_filter(
      function(m)
        return m[4].line_hl_group == "CodeReviewPanelSel"
      end,
      vim.api.nvim_buf_get_extmarks(V.panel_buf, vim.api.nvim_create_namespace("codereview_panel"), 0, -1, {
        details = true,
      })
    )
    assert.same(1, #sel)
    assert.same(V.panel_render.file_row[5], sel[1][2] + 1)
  end)

  it("<Tab> moves focus to the tree and back", function()
    vim.api.nvim_set_current_win(V.win)
    view.toggle_focus()
    assert.same(V.panel_win, vim.api.nvim_get_current_win())
    assert.same(V.panel_render.file_row[5], vim.api.nvim_win_get_cursor(V.panel_win)[1])
    view.toggle_focus()
    assert.same(V.win, vim.api.nvim_get_current_win())
  end)

  it("]f inside the tree skips directory rows", function()
    pcur(1)
    view.panel_jump_file(true)
    assert.is_not_nil(V.panel_render.row_file[vim.api.nvim_win_get_cursor(V.panel_win)[1]])
  end)
end)

describe("the file picker", function()
  local offered
  vim.ui.select = function(items, _, cb)
    offered = items
    for i, s in ipairs(items) do
      if s:find("packages/shared/src/types.lua", 1, true) then
        return cb(s, i)
      end
    end
  end

  vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
  view.pick_file()

  it("offers every file", function()
    assert.same(#V.files, #offered)
  end)

  -- Full paths, not the basenames the tree shows: the picker is how you disambiguate
  -- files that share a name across packages.
  it("shows full paths, not basenames", function()
    local found = vim.tbl_filter(function(s)
      return s:find("apps/web/src/index.lua", 1, true) ~= nil
    end, offered)
    assert.is_true(#found > 0)
  end)

  it("jumps to the chosen file", function()
    local anchor = V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]]
    assert.same("packages/shared/src/types.lua", V.files[anchor.file].path)
  end)

  it("expands a collapsed file when you deliberately jump to it", function()
    local path = "packages/shared/src/types.lua"
    local i = assert(h.file_index(V, path))
    V.reviewed[path] = V.files[i].blob
    V.expanded[path] = false
    view.paint()

    view.pick_file()
    assert.is_true(V.expanded[path])
  end)
end)

-- Dismissing the panel wipes the buffer it was drawn into -- `bufhidden = "wipe"` -- so
-- bringing it back is a rebuild, not an unhide. What survives is what lives on the review:
-- the collapsed directories, the reviewed marks, the queue.
describe("dismissing and summoning the tree", function()
  local function shown()
    return V.panel_win ~= nil and vim.api.nvim_win_is_valid(V.panel_win)
  end

  ---Normal-mode mappings bound to a buffer, by their lhs.
  local function maps_of(buf)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      out[#out + 1] = m.lhs
    end
    table.sort(out)
    return out
  end

  ---The diff's file headers are padded to the diff window's width, which is exactly what
  ---changes when the tree appears or goes away.
  local function header_width()
    local row = V.render.file_rows[1]
    return vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(V.buf, row - 1, row, false)[1])
  end

  ---Row carrying the current-file highlight.
  local function selected_row()
    local sel = vim.tbl_filter(
      function(m)
        return m[4].line_hl_group == "CodeReviewPanelSel"
      end,
      vim.api.nvim_buf_get_extmarks(V.panel_buf, vim.api.nvim_create_namespace("codereview_panel"), 0, -1, {
        details = true,
      })
    )
    assert.same(1, #sel)
    return sel[1][2] + 1
  end

  -- Collapsed *before* the tree goes away. Collapsed state belongs to the review; the
  -- buffer it was drawn into does not survive.
  vim.api.nvim_set_current_win(V.win)
  pcur(row_of_dir("apps"))
  view.panel_fold(true)
  local folded = panel_lines()
  local maps_before = maps_of(V.panel_buf)
  local buf_before = V.panel_buf
  local narrow = vim.api.nvim_win_get_width(V.win)

  it("hides the tree", function()
    view.toggle_panel()
    assert.is_false(shown())
  end)

  it("wipes the buffer the tree was drawn into", function()
    assert.is_false(vim.api.nvim_buf_is_valid(buf_before))
  end)

  it("repaints the diff against the width it now has", function()
    assert.is_true(vim.api.nvim_win_get_width(V.win) > narrow)
    assert.same(vim.api.nvim_win_get_width(V.win), header_width())
  end)

  it("brings it back on the same keystroke", function()
    view.toggle_panel()
    assert.is_true(shown())
    assert.same(narrow, vim.api.nvim_win_get_width(V.win))
    assert.same(narrow, header_width())
  end)

  it("brings it back in a buffer of its own", function()
    assert.is_true(vim.api.nvim_buf_is_valid(V.panel_buf))
    assert.is_true(V.panel_buf ~= buf_before, "the wiped buffer came back")
  end)

  it("leaves collapsed directories exactly as they were", function()
    assert.is_true(V.collapsed["apps"])
    assert.same(folded, panel_lines())
  end)

  it("rebinds every panel keymap", function()
    assert.same(maps_before, maps_of(V.panel_buf))
  end)

  -- Bound is not the same as working: assert through the keys themselves.
  it("rebinds them as live mappings", function()
    vim.api.nvim_set_current_win(V.panel_win)
    pcur(row_of_dir("apps"))
    h.feed("za")
    assert.is_nil(V.collapsed["apps"])
    h.feed("za")
    assert.is_true(V.collapsed["apps"])
    vim.api.nvim_set_current_win(V.win)
  end)

  it("does not shadow the tab-switching keys", function()
    for _, buf in ipairs({ V.buf, V.panel_buf }) do
      assert.is_false(vim.tbl_contains(maps_of(buf), "gt"))
      assert.is_false(vim.tbl_contains(maps_of(buf), "gT"))
    end
  end)

  it("is the same keystroke in the diff and in the tree", function()
    vim.api.nvim_set_current_win(V.win)
    h.feed("gp")
    assert.is_false(shown())
    h.feed("gp")
    assert.is_true(shown())

    vim.api.nvim_set_current_win(V.panel_win)
    h.feed("gp")
    assert.is_false(shown())
    assert.same(V.win, vim.api.nvim_get_current_win())
    h.feed("gp")
    assert.is_true(shown())
  end)

  it("hands focus back to the diff when dismissed from inside the tree", function()
    vim.api.nvim_set_current_win(V.panel_win)
    view.toggle_panel()
    assert.is_false(shown())
    assert.same(V.win, vim.api.nvim_get_current_win())
  end)

  it("shows what changed while it was hidden", function()
    view.panel_fold_all(false)
    local path = "apps/web/src/index.lua"
    local i = assert(h.file_index(V, path))
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[i], 0 })
    view.toggle_reviewed()

    view.toggle_panel()
    assert.is_truthy(panel_lines()[row_of_file(path)]:find("✓", 1, true))
    view.toggle_reviewed()
  end)

  -- The tree repaints only when the diff cursor crosses into a different file, and the
  -- crossing is judged with no tree to repaint -- so the latch tracks a reviewer through a
  -- dismissed tree rather than freezing on the file that was being read when it went away.
  -- The crossing *back* at the end is what pins that: against a latch that had frozen, it
  -- would not read as a crossing at all, and the highlight would stay where it was.
  it("follows the diff cursor again once it is back", function()
    local function look_at(index)
      vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index], 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
    end

    look_at(3)
    look_at(1)
    assert.same(V.panel_render.file_row[1], selected_row())

    view.toggle_panel()
    look_at(3)
    view.toggle_panel()
    assert.same(V.panel_render.file_row[3], selected_row())

    look_at(1)
    assert.same(V.panel_render.file_row[1], selected_row())
  end)
end)

-- Last: this reopens the review, so every `V` above it is gone.
describe("a review configured to start without a tree", function()
  require("codereview").setup({
    syntax = false,
    panel = { enabled = false },
    compose = function(_, on_accept, _)
      on_accept(nil, "n")
    end,
  })
  view.open("branch")
  local W = assert(view.current())

  it("opens with none", function()
    assert.is_nil(W.panel_win)
  end)

  -- The crossing is the diff's, not the tree's, so it is judged where there has never been
  -- a tree to repaint -- the case the tree's own highlight can say nothing about. Two
  -- crossings rather than one: a latch that never moved off its first value would pass a
  -- single absolute assertion.
  it("notices a file crossing with no tree to repaint", function()
    local function look_at(index)
      vim.api.nvim_win_set_cursor(W.win, { W.render.file_rows[index], 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = W.buf })
    end

    assert.is_nil(W.panel_win)
    look_at(3)
    assert.same(3, W.current_file)
    look_at(1)
    assert.same(1, W.current_file)
  end)

  it("summons one on the keystroke", function()
    view.toggle_panel()
    assert.is_not_nil(W.panel_win)
    assert.is_true(vim.api.nvim_win_is_valid(W.panel_win))
    assert.same(#W.files, #W.panel_render.file_rows)
  end)
end)

--- The state mark's colour -------------------------------------------------------
--
-- A file's **state** mark -- the leftmost thing after the indent, already three-valued for
-- reviewed, annotated and unreviewed -- is drawn in the highlight group of that file's
-- **leading type**: the first annotation type in the *configured* order that has an **entry**
-- in the file. So a file holding a bug stops looking like a file holding a nitpick.
--
-- Appended as blocks of their own rather than woven into the ones above, and each opens the
-- review it reads: the block before this one reopened the review, so every `V` above it is
-- gone.
--
-- **What these cases cannot see.** A group named by an extmark is not a colour on a screen.
-- Two line-wide groups already land on tree rows -- `CodeReviewFileReviewed` over a reviewed
-- file's whole row and `CodeReviewPanelSel` over the row the diff cursor is in -- and a
-- line-wide group replaces every attribute it sets on the marks beneath it, at every
-- priority. Everything below would stay green with the colour invisible on both. The cells at
-- the foot of this file are what answer that.

local config = require("codereview.config")
local render = require("codereview.render")

local NS_PANEL = vim.api.nvim_create_namespace("codereview_panel")

---@param W CRView
---@param path string
---@return integer row 1-indexed
local function tree_row(W, path)
  local i = assert(h.file_index(W, path), path .. " is not in this review")
  return assert(W.panel_render.file_row[i], path .. " has no tree row")
end

---@param W CRView
---@param row integer 1-indexed
---@return string
local function tree_text(W, row)
  return vim.api.nvim_buf_get_lines(W.panel_buf, row - 1, row, false)[1]
end

---Every *range* mark on a tree row, ascending. The line-wide marks carry no `end_col` and
---are not ranges, so they are not here.
---@param W CRView
---@param row integer 1-indexed
---@return { col: integer, end_col: integer, group: string }[]
local function ranges(W, row)
  local out = {}
  for _, m in
    ipairs(vim.api.nvim_buf_get_extmarks(W.panel_buf, NS_PANEL, { row - 1, 0 }, { row - 1, -1 }, { details = true }))
  do
    if m[4].end_col then
      out[#out + 1] = { col = m[3], end_col = m[4].end_col, group = m[4].hl_group }
    end
  end
  table.sort(out, function(a, b)
    return a.col < b.col
  end)
  return out
end

---Where a file's state mark sits, taken off the row the tree really drew rather than
---respelled out of the arithmetic the builder used: the indent is spaces, and the mark is the
---first thing after it and is one of the three configured glyphs.
---@param W CRView
---@param path string
---@return integer row, integer col 0-indexed byte, integer end_col, string glyph
local function state_extent(W, path)
  local row = tree_row(W, path)
  local text = tree_text(W, row)
  local col = #text:match("^ *")
  for _, key in ipairs({ "reviewed", "annotated", "unreviewed" }) do
    local glyph = config.get().icons[key]
    if text:sub(col + 1, col + #glyph) == glyph then
      return row, col, col + #glyph, glyph
    end
  end
  error(("no state mark at the head of %s's row: %q"):format(path, text))
end

---The group of the range covering a file's state mark. Containment rather than an exact
---extent, so a range of the wrong width answers here with its group and is caught by the case
---that is about width.
---@param W CRView
---@param path string
---@return string
local function state_group(W, path)
  local row, col = state_extent(W, path)
  for _, r in ipairs(ranges(W, row)) do
    if r.col <= col and col < r.end_col then
      return r.group
    end
  end
  error(("no range covers the state mark on %s's row"):format(path))
end

---@param W CRView
---@param path string
---@param type_name string
local function annotate_in(W, path, type_name)
  vim.api.nvim_win_set_cursor(W.win, { assert(h.line_row(W, path), path .. " has no diff line"), 0 })
  annotate.annotate(type_name)
end

---Every file expanded and none of them reviewed, so a block reads a review whose state it set
---rather than one an earlier block persisted: a reviewed file is drawn collapsed, and a file
---with no rows on the diff has no line to annotate.
---@param W CRView
local function fresh(W)
  W.reviewed, W.expanded = {}, {}
  view.paint()
end

--- With the shipped annotation types ---------------------------------------------

require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept, _)
    on_accept(nil, "n")
  end,
})
view.open("branch")
local P = assert(view.current(), "no review view opened")
queue.clear()
fresh(P)

-- One file per claim, so no case has to undo another's queue. Six of the seven changed files
-- of the nested fixture are spoken for; the seventh is the clean row.
local BUG = "apps/api/src/main.lua"
local NIT = "docs/guide.md"
local NIT_THEN_BUG = "apps/web/src/index.lua"
local BUG_THEN_NIT = "packages/shared/src/types.lua"
local NIT_THEN_SUG = "apps/web/src/components/button.lua"
local REVIEWED = "README.md"
local CLEAN = "apps/api/src/routes/users.lua"

annotate_in(P, BUG, "bug")
annotate_in(P, NIT, "nitpick")
annotate_in(P, NIT_THEN_BUG, "nitpick")
annotate_in(P, NIT_THEN_BUG, "bug")
annotate_in(P, BUG_THEN_NIT, "bug")
annotate_in(P, BUG_THEN_NIT, "nitpick")
annotate_in(P, NIT_THEN_SUG, "nitpick")
annotate_in(P, NIT_THEN_SUG, "suggestion")
annotate_in(P, REVIEWED, "bug")
vim.api.nvim_win_set_cursor(P.win, { P.render.file_rows[assert(h.file_index(P, REVIEWED))], 0 })
view.toggle_reviewed()
-- The diff cursor is parked on a file no case below reads, so no row under test carries
-- `CodeReviewPanelSel` as well as the group it is being asked about.
vim.api.nvim_win_set_cursor(P.win, { P.render.file_rows[assert(h.file_index(P, CLEAN))], 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = P.buf })

describe("a file's state mark in its leading type's colour", function()
  it("draws a file holding a bug in the bug type's group", function()
    assert.same("CodeReviewBug", state_group(P, BUG))
  end)

  it("draws a file holding only a nitpick in the nitpick type's group", function()
    assert.same("CodeReviewNitpick", state_group(P, NIT))
  end)

  -- Whichever order the entries were made in, and the type that leads is neither the first
  -- of the configured list nor the last entry queued -- so a private ordering and a
  -- last-one-wins rule are both red here.
  it("takes the first configured type present, whichever order the entries were made in", function()
    assert.same("CodeReviewBug", state_group(P, NIT_THEN_BUG))
    assert.same("CodeReviewBug", state_group(P, BUG_THEN_NIT))
    assert.same("CodeReviewSuggestion", state_group(P, NIT_THEN_SUG))
  end)

  it("keeps the reviewed group on a file that is reviewed and holds a bug", function()
    local _, _, _, glyph = state_extent(P, REVIEWED)
    assert.same(config.get().icons.reviewed, glyph)
    assert.same("CodeReviewStatAdd", state_group(P, REVIEWED))
  end)

  it("keeps the group a file with no queued entry has today", function()
    local _, _, _, glyph = state_extent(P, CLEAN)
    assert.same(config.get().icons.unreviewed, glyph)
    assert.same("CodeReviewNoteCount", state_group(P, CLEAN))
  end)

  -- The row the diff cursor is in gets the colour too, said at the mark level. It is said
  -- again on a painted cell at the foot of this file, and only there can it be believed.
  it("gives the row the diff cursor is in its own type's group", function()
    local i = assert(h.file_index(P, BUG))
    vim.api.nvim_win_set_cursor(P.win, { P.render.file_rows[i], 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = P.buf })

    local row = tree_row(P, BUG)
    local lit = vim.tbl_filter(function(m)
      return m[4].line_hl_group == "CodeReviewPanelSel"
    end, vim.api.nvim_buf_get_extmarks(P.panel_buf, NS_PANEL, 0, -1, { details = true }))
    assert.same(1, #lit)
    assert.same(row, lit[1][2] + 1)
    assert.same("CodeReviewBug", state_group(P, BUG))

    vim.api.nvim_win_set_cursor(P.win, { P.render.file_rows[assert(h.file_index(P, CLEAN))], 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = P.buf })
  end)

  -- **The extent, as a property of the row the tree drew.** Not three offsets: three offset
  -- assertions once passed on a directory row while a byte was covered by no range at all.
  -- A file row leaves its name to the row's own foreground on purpose, so the claim that
  -- holds here is that the ranges run in order, never overlap, never run past the row, and
  -- that exactly one of them covers the state mark and covers exactly it.
  it("colours the state mark's own bytes and nothing beside them", function()
    local row, col, end_col = state_extent(P, BUG)
    local text = tree_text(P, row)
    local rs = ranges(P, row)

    local last = 0
    for _, r in ipairs(rs) do
      assert.is_true(r.col >= last, ("range at %d overlaps the one ending at %d"):format(r.col, last))
      assert.is_true(r.end_col > r.col, ("empty range at %d"):format(r.col))
      assert.is_true(r.end_col <= #text, ("range ends at %d, past a row of %d bytes"):format(r.end_col, #text))
      last = r.end_col
    end

    local over = vim.tbl_filter(function(r)
      return r.col < end_col and r.end_col > col
    end, rs)
    assert.same(1, #over, "the state mark is covered by " .. #over .. " ranges")
    assert.same({ col = col, end_col = end_col, group = "CodeReviewBug" }, over[1])
  end)

  -- The number is gone and its columns are the **stat**'s. What it said -- which type is
  -- waiting -- is the colour asserted above, which is what let it go. A file holding one
  -- entry and a file holding two now draw the same row, and the row says how big the change
  -- is instead.
  it("prints no note count number on the row", function()
    local one = tree_text(P, tree_row(P, BUG))
    local two = tree_text(P, tree_row(P, NIT_THEN_BUG))
    assert.same("+1 -1", one:match("%+%d+ %-%d+%s*$"), one)
    assert.same("+1 -1", two:match("%+%d+ %-%d+%s*$"), two)
    -- Nothing between the name and the stat but spaces, which is where the count sat.
    assert.same("● main.lua              +1 -1", vim.trim(one))
    assert.same("● index.lua             +1 -1", vim.trim(two))
  end)

  -- A guard rather than a red case: a directory row must come out of this unchanged, so
  -- nothing here can be red before the change. The comparison is the builder against itself
  -- with the type order withheld, which is the only pre-image a spec can hold.
  it("leaves every directory row byte-for-byte what it was", function()
    local cfg = config.get()
    local opts = {
      width = 34,
      icons = cfg.icons,
      reviewed = P.reviewed,
      notes = P.notes,
      collapsed = {},
    }
    local without = panel.build(P.files, opts)
    local with = panel.build(P.files, vim.tbl_extend("force", opts, { types = cfg.types }))

    local function dir_rows(r)
      local out = {}
      for row in pairs(r.row_dir) do
        out[#out + 1] = row
      end
      table.sort(out)
      local text, dir_marks = {}, {}
      for _, row in ipairs(out) do
        text[#text + 1] = r.lines[row]
      end
      for _, m in ipairs(r.marks) do
        if r.row_dir[m.row + 1] then
          dir_marks[#dir_marks + 1] = m
        end
      end
      return { text = text, marks = dir_marks }
    end

    assert.is_true(#dir_rows(without).text > 0, "the fixture drew no directory row")
    assert.same(dir_rows(without), dir_rows(with))
  end)

  -- A guard, and green before the change by construction. The builder is pure and stays
  -- pure: the configured order arrives as an argument, the way the glyph table and the icon
  -- adapters already do.
  it("reaches the configuration module for nothing", function()
    local src = table.concat(vim.fn.readfile(vim.fs.joinpath(h.root, "lua", "codereview", "panel.lua")), "\n")
    assert.is_nil(src:find("codereview.config", 1, true), "panel.lua names the configuration module")
  end)
end)

--- A host that replaced the annotation types outright ----------------------------

describe("a tree drawn under a host's own annotation types", function()
  require("codereview").setup({
    syntax = false,
    compose = function(_, on_accept, _)
      on_accept(nil, "n")
    end,
    types = {
      { name = "blocker", key = "B", hl = "HostBlocker" },
      { name = "chore", key = "c", hl = "HostChore" },
    },
  })
  view.open("branch")
  local Q = assert(view.current(), "no review view opened")
  queue.clear()
  fresh(Q)

  local BLOCKER = "apps/api/src/main.lua"
  local CHORE = "docs/guide.md"
  local STRANGER = "apps/web/src/index.lua"
  local BOTH = "packages/shared/src/types.lua"
  local PARK = "apps/api/src/routes/users.lua"

  annotate_in(Q, BLOCKER, "blocker")
  annotate_in(Q, CHORE, "chore")
  annotate_in(Q, BOTH, "chore")
  -- A queue written under an older configuration: `annotate` refuses a type the host does not
  -- have, so these go in as entries, which is what a restored queue holds.
  for _, path in ipairs({ STRANGER, BOTH }) do
    queue.add({
      type = "bug",
      kind = "file",
      path = path,
      abs_path = vim.fs.joinpath(Q.root, path),
      key = render.file_key(path),
      note = "n",
      inline = false,
    })
  end
  vim.api.nvim_win_set_cursor(Q.win, { Q.render.file_rows[assert(h.file_index(Q, PARK))], 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = Q.buf })
  view.paint()

  it("draws the host's own groups on the tree", function()
    assert.same("HostBlocker", state_group(Q, BLOCKER))
    assert.same("HostChore", state_group(Q, CHORE))
  end)

  -- The number left the file row with #242, so what *counted* looks like here is the **state**
  -- mark: a file whose only entry is of a type the host has dropped still reads as annotated
  -- rather than clean, and still takes the colour it had rather than that type's.
  it("counts an entry of a type it no longer has, and never lets it lead", function()
    local _, _, _, stranger = state_extent(Q, STRANGER)
    assert.same(config.get().icons.annotated, stranger)
    assert.same("CodeReviewNoteCount", state_group(Q, STRANGER))

    local _, _, _, both = state_extent(Q, BOTH)
    assert.same(config.get().icons.annotated, both)
    assert.same("HostChore", state_group(Q, BOTH))
  end)

  -- The *configured* order and no other: the same queue, read again under a list turned
  -- around, hands the lead to the other type. A private ordering is red here.
  it("takes its order from the configuration and not from a list of its own", function()
    annotate_in(Q, BLOCKER, "chore")
    view.paint()
    assert.same("HostBlocker", state_group(Q, BLOCKER))

    require("codereview").setup({
      syntax = false,
      compose = function(_, on_accept, _)
        on_accept(nil, "n")
      end,
      types = {
        { name = "chore", key = "c", hl = "HostChore" },
        { name = "blocker", key = "B", hl = "HostBlocker" },
      },
    })
    view.paint()
    assert.same("HostChore", state_group(Q, BLOCKER))
  end)
end)

--- A host's file glyph beside it --------------------------------------------------

describe("a host's file glyph beside a coloured state mark", function()
  local LUA = "λ"
  local AZURE = "MiniIconsAzure"

  require("codereview").setup({
    syntax = false,
    compose = function(_, on_accept, _)
      on_accept(nil, "n")
    end,
    file_icon = function(_)
      return LUA, AZURE
    end,
  })
  view.open("branch")
  local R = assert(view.current(), "no review view opened")
  queue.clear()
  fresh(R)

  local BUGGY = "apps/api/src/main.lua"
  local PARK = "apps/api/src/routes/users.lua"
  annotate_in(R, BUGGY, "bug")
  vim.api.nvim_win_set_cursor(R.win, { R.render.file_rows[assert(h.file_index(R, PARK))], 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = R.buf })

  it("keeps its own colour, on its own bytes, beside the state mark", function()
    local row, col, end_col = state_extent(R, BUGGY)
    local text = tree_text(R, row)
    local rs = ranges(R, row)

    local mark = vim.tbl_filter(function(r)
      return r.col < end_col and r.end_col > col
    end, rs)
    assert.same(1, #mark)
    assert.same({ col = col, end_col = end_col, group = "CodeReviewBug" }, mark[1])

    local glyph_col = assert(text:find(LUA, end_col + 1, true), "the host's glyph is not on that row") - 1
    local glyph = vim.tbl_filter(function(r)
      return r.group == AZURE
    end, rs)
    assert.same(1, #glyph)
    assert.same({ col = glyph_col, end_col = glyph_col + #LUA, group = AZURE }, glyph[1])
    assert.is_true(glyph[1].col >= end_col, "the host's group reaches into the state mark")
  end)
end)

--- The cells a reviewer's screen holds --------------------------------------------

-- One child per reading, because `nvim__inspect_cell` is only honest on the first call a
-- process makes. Each opens the same review over a fixture of this block's own, in the
-- unified layout at 80x24, and reads the cell the state mark is drawn on -- found by the mark
-- the tree really emitted rather than at an offset this spec expects it at.
--
-- `00ee00` is the bug type's group, `ee0000` the nitpick's, and `0000ee` the background
-- `CursorLine` carries -- which is what `CodeReviewPanelSel` resolves to on the row the diff
-- cursor is in. The fourth reading gives that background a foreground as well, which is the
-- one thing this plugin cannot answer: see the assertion.
describe("the cell a reviewer's eye lands on", function()
  local fixture = h.fixture("mktree")

  ---@param mode string
  ---@return string
  local function child(mode)
    local run = vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "leading_type_child.lua"),
      }, {
        cwd = fixture,
        text = true,
        env = {
          FIXTURE = fixture,
          MODE = mode,
          XDG_STATE_HOME = vim.fn.tempname() .. "-state",
          GIT_CONFIG_GLOBAL = "/dev/null",
          GIT_CONFIG_SYSTEM = "/dev/null",
        },
      })
      :wait(60000)
    -- `nvim -l` sends print to stderr, so read both streams rather than guessing.
    local out = (run.stdout or "") .. (run.stderr or "")
    assert(run.code == 0, out)
    -- The child queues annotations to have something to colour, and a **notification** lands
    -- on the same stream `print` does -- so the reading is picked out of that stream by name.
    -- Trimming the whole of it instead reads the notifications as part of the answer, and
    -- every case below then fails on text no cell ever held.
    local reading = assert(out:match("cell [^\n]*"), out)
    return (reading:gsub(" at %d+,%d+$", ""))
  end

  local bug = child("bug")
  local nitpick = child("nitpick")
  local current = child("current")
  local flatten = child("flatten")

  it("draws the mark of a file holding a bug in the bug type's colour", function()
    assert.same('cell "●" fg=00ee00 bg=none', bug)
  end)

  -- A different colour on a screen, and not merely a different name in a table.
  it("draws the mark of a file holding only a nitpick in another colour", function()
    assert.same('cell "●" fg=ee0000 bg=none', nitpick)
  end)

  -- **The reading this seam exists for.** The background says the line-wide group really
  -- painted this row, so the case cannot pass on a row that never had one; the foreground
  -- says the leading type's colour survived it.
  it("keeps the colour on the row the diff cursor is in", function()
    assert.same('cell "●" fg=00ee00 bg=0000ee', current)
  end)

  -- **And the row that loses it.** A line-wide foreground replaces a range's at every
  -- priority -- measured, not assumed -- so a colourscheme whose `CursorLine` carries one
  -- takes the leading type off the row the reviewer is on, and no priority the tree could
  -- choose answers it. Here so that the reading above says *why* it holds.
  it("loses it to a line-wide group that carries a foreground of its own", function()
    assert.same('cell "●" fg=eeee00 bg=0000ee', flatten)
  end)
end)

-- The footer's progress bar.
--
-- Appended at the end, and it opens a review of its own: the block above reopened the review
-- and `V` went with it, so nothing here reads a tree any earlier block left behind.
--
-- **Two seams, because one of them cannot see colour.** The counts are read off
-- `panel.build`, which is pure -- files and options in, lines and marks out -- on file lists
-- built by hand rather than on the nested fixture, so a review of exactly twelve files and a
-- review of exactly one are both available and every expected cell count is a literal. The
-- colour is read off a painted cell in a child process, because the footer row carries a
-- line-wide `CodeReviewTitle` and a line-wide group with a foreground replaces the
-- foreground of every column mark under it: no table over group names can say what colour
-- the bar's cells came out.
--
-- **Every count below is spelled as a number.** A count computed from the same expression
-- the panel divides with agrees with the panel whatever that expression is, which is the
-- one general cause of an assertion in this suite that cannot fail.
describe("the footer's progress bar", function()
  -- The shipped glyphs, spelled here rather than read off the configuration, as
  -- `file_icon_spec` spells the state marks: what a case asserts must not be taken from what
  -- it is asserting about. That the shipped pair is what a review really draws is the child
  -- process's to say -- it opens a review with nothing overridden and searches for these two.
  local FULL, EMPTY = "█", "░"
  local ICONS = {
    reviewed = "✓",
    annotated = "●",
    unreviewed = "○",
    collapsed = "▸",
    expanded = "▾",
    progress_full = FULL,
    progress_empty = EMPTY,
  }

  ---A file list of `count` files. Each carries line counts as well as a path, because the
  ---builder draws a file row's `+N -M` from them and a `CRFile` has always had both.
  ---@param count integer
  ---@return table[]
  local function files_of(count)
    local out = {}
    for i = 1, count do
      out[i] = { path = ("src/f%02d.lua"):format(i), added = 1, removed = 1, binary = false }
    end
    return out
  end

  ---A tree of `count` files with the first `done` of them reviewed.
  ---@param count integer
  ---@param done integer
  ---@param width integer|nil
  ---@param icons table|nil
  ---@return CRPanelRender
  local function tree_of(count, done, width, icons)
    local files = files_of(count)
    local reviewed = {}
    for i = 1, done do
      reviewed[files[i].path] = "blob"
    end
    return panel.build(files, {
      width = width or 34,
      icons = icons or ICONS,
      reviewed = reviewed,
      notes = {},
      collapsed = {},
    })
  end

  ---@param rendered CRPanelRender
  ---@return string
  local function footer_of(rendered)
    return rendered.lines[#rendered.lines]
  end

  ---How many cells of one kind the bar holds.
  ---@param line string
  ---@param glyph string
  ---@return integer
  local function cells(line, glyph)
    local _, found = line:gsub(glyph, "")
    return found
  end

  it("draws the tally and a bar on one row, inside the panel width", function()
    local rendered = tree_of(12, 0)
    local lines = rendered.lines
    -- One row, with the blank row above it left alone.
    assert.same("", lines[#lines - 1])
    assert.is_nil(lines[#lines - 2]:match("reviewed"))
    -- The same columns every other row of this tree spends, and 33 of them at width 34.
    assert.same(33, vim.fn.strdisplaywidth(footer_of(rendered)))
    assert.same(vim.fn.strdisplaywidth(lines[1]), vim.fn.strdisplaywidth(footer_of(rendered)))
  end)

  it("puts the bar after the tally and a separating space, and nothing else on the row", function()
    local line = footer_of(tree_of(12, 6))
    assert.same("6/12 reviewed", line:match("^%d+/%d+ reviewed"))
    local bar = line:match("^%d+/%d+ reviewed +(.*)$")
    assert.is_truthy(bar, line)
    assert.same("", (bar:gsub(FULL, ""):gsub(EMPTY, "")))
  end)

  it("draws an empty bar for a review with nothing reviewed", function()
    local line = footer_of(tree_of(12, 0))
    assert.same(0, cells(line, FULL))
    assert.same(18, cells(line, EMPTY))
  end)

  it("draws a full bar for a review that is entirely reviewed", function()
    local line = footer_of(tree_of(12, 12))
    assert.same(18, cells(line, FULL))
    assert.same(0, cells(line, EMPTY))
  end)

  -- Two points rather than one: a bar that divided by the wrong number agrees with a single
  -- part-way reading often enough to pass it.
  it("draws a proportional bar part-way through", function()
    local one = footer_of(tree_of(12, 1))
    assert.same(1, cells(one, FULL))
    assert.same(17, cells(one, EMPTY))

    local half = footer_of(tree_of(12, 6))
    assert.same(9, cells(half, FULL))
    assert.same(9, cells(half, EMPTY))
  end)

  -- The end state has to be unmistakable, so a full bar means a finished review and nothing
  -- else. One file short of the end is one cell short of full at least.
  it("keeps the full bar for a finished review alone", function()
    local line = footer_of(tree_of(12, 11))
    assert.same(16, cells(line, FULL))
    assert.same(2, cells(line, EMPTY))
  end)

  it("draws a review of one file", function()
    local none = footer_of(tree_of(1, 0))
    assert.same(0, cells(none, FULL))
    assert.same(20, cells(none, EMPTY))

    local done = footer_of(tree_of(1, 1))
    assert.same(20, cells(done, FULL))
    assert.same(0, cells(done, EMPTY))
  end)

  -- The bar is measured against the widest tally the review can print and never against the
  -- one it prints now. `N/M reviewed` grows a column when the reviewed count grows a digit, so
  -- a bar taking whatever is left over is re-laid-out twice while it fills: at a hundred files
  -- on this 33-column row it would be 18 cells below ten reviewed, 17 below a hundred and 16
  -- at a hundred. The reviewed counts below straddle both of those steps, and each is asserted
  -- as a length rather than as a fill, because the length is the half that must not move.
  it("spends the same columns on the bar however the tally reads", function()
    for _, done in ipairs({ 0, 9, 10, 99, 100 }) do
      local line = footer_of(tree_of(100, done))
      assert.same(16, cells(line, FULL) + cells(line, EMPTY))
    end
    for _, done in ipairs({ 0, 9, 10, 12 }) do
      local line = footer_of(tree_of(12, done))
      assert.same(18, cells(line, FULL) + cells(line, EMPTY))
    end
  end)

  -- **A review that has been started draws a cell.** The count is a floor, and at three
  -- hundred files a floor alone reaches its first cell at nineteen reviewed -- so a reviewer
  -- finishes eighteen files and the bar still reads as untouched, on the review size the bar
  -- is most use on. The clamp cannot reach the other end: only `reviewed == total` fills the
  -- last cell, with it or without it.
  it("draws one cell for a review barely started", function()
    local line = footer_of(tree_of(100, 1))
    assert.same(1, cells(line, FULL))
    assert.same(15, cells(line, EMPTY))
  end)

  -- **The last file reviewed adds a cell**, which is the sharpest thing the fixed length buys
  -- and the reason it is asserted here rather than only as a width. Measured against the
  -- ticket's own wording at this width: 99 of 100 would leave 17 cells and fill 16 of them,
  -- and 100 of 100 leaves 16 and fills 16 -- the review is finished and the filled run is the
  -- length it already was.
  it("leaves the last cell empty one file short of the end", function()
    local line = footer_of(tree_of(100, 99))
    assert.same(15, cells(line, FULL))
    assert.same(1, cells(line, EMPTY))

    local done = footer_of(tree_of(100, 100))
    assert.same(16, cells(done, FULL))
    assert.same(0, cells(done, EMPTY))
  end)

  -- **The multiplication happens before the division**, and only a case naming its width can
  -- say so. `reviewed / total * cells` is two roundings: at a panel 38 columns wide a review
  -- of 22 files with 15 of them reviewed is a 22-cell bar, and that form lands on
  -- 14.999999999999998 and floors to 14 -- one cell short of the 15 the exact form gives. The
  -- shipped width agrees either way, so swapping the two operations reds nothing without
  -- this. Found by mutation-checking the rule rather than by reading it.
  it("counts the filled cells with no rounding of its own", function()
    local line = footer_of(tree_of(22, 15, 38))
    assert.same(15, cells(line, FULL))
    assert.same(7, cells(line, EMPTY))
  end)

  -- The glyphs are the host's to replace, as the state marks and the change bar are. Two
  -- glyphs neither of which the plugin ships, so a bar drawn from the defaults cannot pass.
  it("draws the glyphs the host configured", function()
    local icons = vim.tbl_extend("force", ICONS, { progress_full = "#", progress_empty = "." })
    local line = footer_of(tree_of(12, 6, nil, icons))
    assert.same(9, cells(line, "#"))
    assert.same(9, cells(line, "%."))
    assert.same(0, cells(line, FULL))
    assert.same(0, cells(line, EMPTY))
  end)

  -- A scope with nothing in it draws no bar. A row of empty cells over `0/0 reviewed` says
  -- there is everything left to read, which is the opposite of true -- the same lie the clamp
  -- above stops telling from the other end. It is also what `file_icon_spec` has always
  -- asserted of an empty scope, byte for byte.
  it("draws no bar for a review of no files at all", function()
    assert.same("0/0 reviewed", footer_of(tree_of(0, 0)))
  end)

  it("leaves the bar out when the row has no columns left for one", function()
    assert.same("0/12 reviewed", footer_of(tree_of(12, 0, 14)))
  end)

  -- **The bar is not green.** Green is a finished directory's count in this tree, and the
  -- stat on a file row brings it in again for added lines. The bar carries no range of its
  -- own at all, so it draws in the group the footer's own text draws in -- which is the row's
  -- one line-wide group and the whole of what the row emits.
  it("draws the bar in the group the footer's own text takes, and in no other", function()
    local rendered = tree_of(12, 6)
    local row = #rendered.lines - 1
    local on_footer = vim.tbl_filter(function(m)
      return m.row == row
    end, rendered.marks)
    assert.same(1, #on_footer)
    assert.same(0, on_footer[1].col)
    assert.same({ line_hl_group = "CodeReviewTitle" }, on_footer[1].opts)
  end)

  -- A review of its own, so this block reads a tree it opened rather than whatever the block
  -- above left behind.
  require("codereview").setup({
    syntax = false,
    compose = function(_, on_accept, _)
      on_accept(nil, "n")
    end,
  })
  view.open("branch")
  local X = assert(view.current())

  it("repaints the bar when a file is marked reviewed", function()
    -- The counts below are literal, so what they are counted out of is stated here. The
    -- window is taken into a local first: luassert's `assert` returns three values, and a
    -- call position keeps all three.
    local panel_win = assert(X.panel_win)
    assert.same(7, #X.files)
    assert.same(34, vim.api.nvim_win_get_width(panel_win))

    X.reviewed, X.expanded = {}, {}
    view.paint()
    local before = footer_of(X.panel_render)
    assert.same("0/7 reviewed", before:match("^%d+/%d+ reviewed"))
    assert.same(0, cells(before, FULL))
    assert.same(20, cells(before, EMPTY))

    vim.api.nvim_win_set_cursor(X.win, { X.render.file_rows[1], 0 })
    view.toggle_reviewed()

    local after = footer_of(X.panel_render)
    assert.same("1/7 reviewed", after:match("^%d+/%d+ reviewed"))
    assert.same(2, cells(after, FULL))
    assert.same(18, cells(after, EMPTY))
  end)
end)

-- The cells a reviewer's screen really holds.
--
-- One child per reading, because `nvim__inspect_cell` is honest only on the first call a
-- process makes. Each opens this spec's review at 80x24, marks three of the seven files
-- reviewed so the row holds both kinds of cell, and reads one cell of the footer bar -- found
-- by searching the row the tree really drew rather than at an offset this spec expects.
--
-- `Normal` is white on black in the child and `Title` -- which `CodeReviewTitle` links to --
-- is `00ee00`, so each reading is an absolute number.
describe("the cell the footer bar is drawn on", function()
  ---@param env table<string, string>
  ---@return string
  local function child(env)
    local run = vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "footer_bar_child.lua"),
      }, {
        cwd = fixture,
        text = true,
        env = vim.tbl_extend("force", {
          FIXTURE = fixture,
          XDG_STATE_HOME = vim.fn.tempname() .. "-state",
          GIT_CONFIG_GLOBAL = "/dev/null",
          GIT_CONFIG_SYSTEM = "/dev/null",
        }, env),
      })
      :wait(60000)
    -- `nvim -l` sends print to stderr, so read both streams rather than guessing.
    local out = (run.stdout or "") .. (run.stderr or "")
    assert(run.code == 0, out)
    return (vim.trim(out):gsub(" at %d+,%d+$", ""))
  end

  local filled = child({ CELL = "filled" })
  local empty = child({ CELL = "empty" })
  local flattened = child({ CELL = "flattened" })

  it("draws a filled cell in the group the footer's own text takes", function()
    assert.same('cell "█" fg=00ee00 bg=none', filled)
  end)

  -- One colour and two glyphs, said as a reading rather than as an intention: an empty cell
  -- comes back in the same foreground a filled one does, so what tells them apart on a screen
  -- is the glyph.
  it("draws an empty cell in that same group", function()
    assert.same('cell "░" fg=00ee00 bg=none', empty)
  end)

  -- Why the bar was not given two colours, pinned rather than remembered. A range over a
  -- filled cell in a group of its own reads the row's foreground and not its own, because the
  -- row's line-wide group replaces it. A two-colour bar would draw in one colour, and no
  -- assertion over marks could see it.
  it("flattens a range that tries to colour a filled cell on its own", function()
    assert.same('cell "█" fg=00ee00 bg=none', flattened)
  end)
end)

--- A file row's `+N -M` stat -------------------------------------------------------
--
-- Every file row carries the two counts its file record already holds, at the right margin,
-- so a reviewer reads change sizes down a column instead of opening a file to find out
-- whether it is a rename or a rewrite. They are the same two numbers the file's header row
-- draws in the **review view**, in the same two groups: one file, one set of facts, wherever
-- the file is named. The note count number leaves the row and pays for the columns -- what
-- mattered about it, which type is waiting, is on the state mark's colour since #244.
--
-- **Two seams, because one of them cannot see colour.** Everything structural is read off
-- `panel.build`, which is pure -- files and options in, lines and marks out -- on file lists
-- built by hand, so counts of two, three and one digit are all available and every expected
-- column is a literal. The colours are read off painted cells in child processes at the foot
-- of this file, because a reviewed row carries a line-wide `CodeReviewFileReviewed` and a
-- line-wide group with a foreground replaces the foreground of every mark beneath it.
--
-- **Every column below is spelled as a number.** A width computed from the same expression
-- the builder pads with agrees with the builder whatever that expression is, which is the one
-- general cause of an assertion in this suite that cannot fail.
describe("a file row's +N -M stat", function()
  -- The shipped glyphs, spelled here rather than read off the configuration, for the reason
  -- the footer bar's block spells them: what a case asserts must not be taken from what it is
  -- asserting about.
  local ICONS = {
    reviewed = "✓",
    annotated = "●",
    unreviewed = "○",
    collapsed = "▸",
    expanded = "▾",
    progress_full = "█",
    progress_empty = "░",
  }

  ---@param files table[]
  ---@param opts table|nil
  ---@return CRPanelRender
  local function build_of(files, opts)
    return panel.build(
      files,
      vim.tbl_extend("force", {
        width = 34,
        icons = ICONS,
        reviewed = {},
        notes = {},
        collapsed = {},
      }, opts or {})
    )
  end

  ---The row a file was drawn on, by its place in the list handed to the builder.
  ---@param rendered CRPanelRender
  ---@param index integer
  ---@return string
  local function line_of(rendered, index)
    return rendered.lines[assert(rendered.file_row[index], "file " .. index .. " has no row")]
  end

  ---Every *range* mark on one row of a build, ascending. The line-wide marks carry no
  ---`end_col` and are not ranges, so they are not here.
  ---@param rendered CRPanelRender
  ---@param row integer 1-indexed
  ---@return { col: integer, end_col: integer, group: string }[]
  local function ranges_on(rendered, row)
    local out = {}
    for _, m in ipairs(rendered.marks) do
      if m.row == row - 1 and m.opts.end_col then
        out[#out + 1] = { col = m.col, end_col = m.opts.end_col, group = m.opts.hl_group }
      end
    end
    table.sort(out, function(a, b)
      return a.col < b.col
    end)
    return out
  end

  -- Three files whose counts are one, three and two digits wide, so the padding is real on
  -- two rows of the three and a build that spent every row's own width would draw a ragged
  -- edge here.
  local SIZED = {
    { path = "a.lua", added = 1, removed = 1, binary = false },
    { path = "b.lua", added = 120, removed = 3, binary = false },
    { path = "c.lua", added = 7, removed = 45, binary = false },
  }
  -- What that stat costs a row: `+120` is four columns, `-45` is three, and one space
  -- separates them. A literal, because it is what the case is about.
  local SIZED_STAT = 8

  it("draws every file row's two counts at the right margin", function()
    local r = build_of(SIZED)
    assert.same("○ a.lua                    +1  -1", line_of(r, 1))
    assert.same("○ b.lua                  +120  -3", line_of(r, 2))
    assert.same("○ c.lua                    +7 -45", line_of(r, 3))
  end)

  -- The column, said as a property rather than left to three row literals: every file row
  -- spends the same columns on its stat and ends in the same column, which is the whole of
  -- what makes the sizes readable down the page.
  it("spends the same columns on every row's stat, however the counts read", function()
    local r = build_of(SIZED)
    for index = 1, 3 do
      local text = line_of(r, index)
      assert.same(33, vim.fn.strdisplaywidth(text))
      assert.is_truthy(text:sub(-SIZED_STAT):match("^%s*%+%d+%s+%-%d+$"), ("row %d: %q"):format(index, text))
    end
  end)

  -- **The counts' own bytes and nothing beside them.** Not two offsets: an offset spelled out
  -- of the arithmetic the builder pads with agrees with the builder whatever that arithmetic
  -- is. The counts are found in the row the builder really drew, and the ranges are then
  -- asserted against where they were found -- in order, never overlapping, never past the
  -- row, and leaving nothing but spaces uncovered inside the field.
  it("colours each count over its own bytes, and neither the padding nor the space between", function()
    local r = build_of(SIZED)
    for index = 1, 3 do
      local row = assert(r.file_row[index])
      local text = line_of(r, index)
      local plus_at, plus_to = text:find("%+%d+")
      local minus_at, minus_to = text:find("%-%d+")
      local rs = ranges_on(r, row)

      local last = 0
      for _, x in ipairs(rs) do
        assert.is_true(x.col >= last, ("range at %d overlaps the one ending at %d"):format(x.col, last))
        assert.is_true(x.end_col > x.col, ("empty range at %d"):format(x.col))
        assert.is_true(x.end_col <= #text, ("range ends at %d, past a row of %d bytes"):format(x.end_col, #text))
        last = x.end_col
      end

      assert.same({ col = plus_at - 1, end_col = plus_to, group = "CodeReviewStatAdd" }, rs[#rs - 1])
      assert.same({ col = minus_at - 1, end_col = minus_to, group = "CodeReviewStatDel" }, rs[#rs])

      -- What the two ranges leave uncovered in the field is padding and the one space
      -- between the counts. Said here rather than left to be discovered: a hole in a range
      -- is invisible on a space today and is a one-column hole the day either group grows a
      -- background.
      for at = #text - SIZED_STAT + 1, #text do
        local covered = false
        for _, x in ipairs(rs) do
          covered = covered or (x.col < at and x.end_col >= at)
        end
        assert.is_true(covered or text:sub(at, at) == " ", ("byte %d of %q is covered by nothing"):format(at, text))
      end
    end
  end)

  -- The number is gone from the row. It is still produced and still totalled onto the
  -- directory nodes; what left is the printing of it, and what it said -- which type is
  -- waiting -- is on the state mark's colour.
  it("prints no note count number on a file row", function()
    local r = build_of(SIZED, {
      notes = {
        ["a.lua:n:2"] = { { type = "bug" }, { type = "nitpick" }, { type = "bug" } },
      },
      types = { { name = "bug", hl = "CodeReviewBug" }, { name = "nitpick", hl = "CodeReviewNitpick" } },
    })
    -- The state mark says a file holds something, and its colour says what.
    assert.same("● a.lua                    +1  -1", line_of(r, 1))
    local row = assert(r.file_row[1])
    assert.same("CodeReviewBug", ranges_on(r, row)[1].group)
  end)

  --- The name's budget ------------------------------------------------------------
  --
  -- **A number with its conditions, and never a number.** The budget moves with the indent,
  -- with what the stat costs *this* review, and with whether a host wired a glyph. The
  -- ticket quoted seventeen columns with all three dropped, which is true of one row of one
  -- mockup and of nothing else -- so each case below names its three conditions, measures the
  -- ones a runner could disagree about, and spells its figure as a literal.
  --
  -- Each is a pair: a name of exactly the budget, drawn whole, and a name one column wider,
  -- cut from the left. One alone says nothing -- a builder that truncated everything would
  -- pass the second and a builder that truncated nothing would pass the first.

  ---A one-column glyph and its separator: the two columns a wired adapter costs a name.
  local GLYPH = "λ"

  ---@param names string[]
  ---@param dir string
  ---@param added integer
  ---@param removed integer
  ---@return table[]
  local function named(names, dir, added, removed)
    local out = {}
    for i, name in ipairs(names) do
      out[i] = { path = dir .. name, added = added, removed = removed, binary = false }
    end
    return out
  end

  ---@param rendered CRPanelRender
  ---@param index integer
  ---@param name string
  local function drawn_whole(rendered, index, name)
    local text = line_of(rendered, index)
    assert.is_truthy(text:find(name, 1, true), ("%q does not hold %q"):format(text, name))
    assert.is_nil(text:find("…", 1, true), text)
  end

  ---@param rendered CRPanelRender
  ---@param index integer
  ---@param name string
  ---@param keeps integer Columns of the name the row is expected to keep, the ellipsis included
  local function cut_from_the_left(rendered, index, name, keeps)
    local text = line_of(rendered, index)
    local tail = name:sub(#name - (keeps - 2) + 1)
    assert.is_truthy(text:find("…" .. tail, 1, true), ("%q does not hold %q"):format(text, "…" .. tail))
  end

  -- Conditions: the top of the tree, no glyph wired, and a review whose widest counts make
  -- the stat five columns. Twenty-five.
  it("gives a top-level name twenty-five columns with no glyph and a five-column stat", function()
    local r = build_of(named({ ("f"):rep(25), ("g"):rep(26) }, "", 1, 1))
    -- The condition the figure rests on, read off the row rather than assumed.
    assert.same("+1 -1", line_of(r, 1):match("%+%d+ %-%d+$"))

    drawn_whole(r, 1, ("f"):rep(25))
    cut_from_the_left(r, 2, ("g"):rep(26), 25)
  end)

  -- Conditions: two levels down, a glyph wired, the same five-column stat. Nineteen. `top`
  -- holds two directories so it cannot compact, which is what keeps these rows at depth two.
  it("gives a name two levels down nineteen columns with a glyph and a five-column stat", function()
    assert.same(2, vim.fn.strdisplaywidth(GLYPH .. " "), "this glyph and its separator are not two columns")
    local files = named({ ("f"):rep(19), ("g"):rep(20) }, "top/one/", 1, 1)
    files[#files + 1] = { path = "top/two/z.lua", added = 1, removed = 1, binary = false }
    local r = build_of(files, {
      file_icon = function()
        return GLYPH
      end,
    })
    assert.same("+1 -1", line_of(r, 1):match("%+%d+ %-%d+$"))
    assert.is_truthy(line_of(r, 1):find(GLYPH, 1, true), "no glyph on the row the budget is read from")

    drawn_whole(r, 1, ("f"):rep(19))
    cut_from_the_left(r, 2, ("g"):rep(20), 19)
  end)

  -- Conditions: the same two levels and the same glyph, and a review holding a file whose
  -- counts make the stat seven. Seventeen -- which is the ticket's figure, true here and
  -- nowhere it was quoted.
  it("gives that same name seventeen columns once the review's widest counts make the stat seven", function()
    local files = named({ ("f"):rep(17), ("g"):rep(18) }, "top/one/", 1, 1)
    files[#files + 1] = { path = "top/two/z.lua", added = 99, removed = 99, binary = false }
    local r = build_of(files, {
      file_icon = function()
        return GLYPH
      end,
    })
    assert.same(" +1  -1", line_of(r, 1):sub(-7))

    drawn_whole(r, 1, ("f"):rep(17))
    cut_from_the_left(r, 2, ("g"):rep(18), 17)
  end)

  -- A **binary** file has no line counts to give. Two zeroes would be a size it never had,
  -- and the row keeps the columns clear instead -- which is what the commit list already does
  -- one surface over for a commit git answered nothing for, rather than pulling every row
  -- under it out of line.
  it("leaves a file with no line counts blank rather than claiming two zeroes", function()
    local r = build_of({
      { path = "a.lua", added = 1, removed = 1, binary = false },
      { path = "logo.png", added = 0, removed = 0, binary = true },
    })

    assert.same("○ a.lua                     +1 -1", line_of(r, 1))
    local blank = line_of(r, 2)
    assert.same("○ logo.png", vim.trim(blank))
    assert.same(33, vim.fn.strdisplaywidth(blank))
    assert.is_nil(blank:match("[+%-]%d"), blank)
    -- One range: the state mark. No colour is spent on a field with nothing in it.
    local row = assert(r.file_row[2])
    assert.same(1, #ranges_on(r, row))
  end)

  -- **Read on the name's budget and not on the trimmed row**, because a field of blanks and
  -- no field at all trim to the same string: the columns *are* the claim here, so the columns
  -- are what is read. Found by mutation-checking this case -- counting a binary file's zeroes
  -- into the column widths left a five-column blank gutter on every row and took five columns
  -- off every name, and the trimmed rows below saw none of it.
  --
  -- Conditions, as for every budget here: the top of the tree, no glyph, and no file in the
  -- review with line counts to give. Thirty.
  it("spends no columns at all on a review with no line counts anywhere in it", function()
    local fits, cut = ("f"):rep(30), ("g"):rep(31)
    local r = build_of({
      { path = fits, added = 0, removed = 0, binary = true },
      { path = cut, added = 0, removed = 0, binary = true },
      { path = "logo.png", added = 0, removed = 0, binary = true },
    })
    drawn_whole(r, 1, fits)
    cut_from_the_left(r, 2, cut, 30)
    assert.same("○ logo.png", vim.trim(line_of(r, 3)))
  end)

  -- **A reviewed row keeps the two numbers and is given no colour.** `CodeReviewFileReviewed`
  -- resolves to `Comment`, which carries a foreground, and a line-wide group with a
  -- foreground replaces the foreground of every range beneath it at every priority --
  -- measured, and read again on a painted cell at the foot of this file. A range emitted here
  -- would be named by an extmark on every paint and would reach no cell on any screen, which
  -- is a dead mark a later reader has no way of discovering is dead. The row is meant to be
  -- recessive anyway: the tree answers what to read next, and a file already read is not a
  -- candidate.
  it("keeps the counts on a reviewed row and spends no colour on them", function()
    local r = build_of(SIZED, { reviewed = { ["b.lua"] = "blob" } })
    assert.same("✓ b.lua                  +120  -3", line_of(r, 2))
    local row = assert(r.file_row[2])
    local rs = ranges_on(r, row)
    assert.same(1, #rs)
    assert.same("CodeReviewStatAdd", rs[1].group)
    assert.same(0, rs[1].col)
  end)
end)

--- The stat on the review this spec opened ----------------------------------------
--
-- The block above reads a builder on file lists of its own. This one reads the tree a real
-- review really drew over the nested fixture, where every changed file is a one-line change
-- and the stat is therefore `+1 -1` on every row.
--
-- A review of its own, so it reads a tree it opened rather than whatever the blocks above
-- left behind.
require("codereview").setup({
  syntax = false,
  compose = function(_, on_accept, _)
    on_accept(nil, "n")
  end,
})
view.open("branch")
local S = assert(view.current(), "no review view opened")
queue.clear()
S.reviewed, S.expanded = {}, {}
view.paint()

describe("the stat on a real review's tree", function()
  ---@param path string
  ---@return string
  local function row_text(path)
    local i = assert(h.file_index(S, path), path .. " is not in this review")
    local row = assert(S.panel_render.file_row[i], path .. " has no tree row")
    return vim.api.nvim_buf_get_lines(S.panel_buf, row - 1, row, false)[1]
  end

  it("draws the stat on every file row", function()
    assert.same(7, #S.files)
    for _, row in ipairs(S.panel_render.file_rows) do
      local text = vim.api.nvim_buf_get_lines(S.panel_buf, row - 1, row, false)[1]
      assert.same("+1 -1", text:match("%+%d+ %-%d+%s*$"), text)
    end
  end)

  -- The annotated file draws its mark and its stat, and no number between them. Spelled as
  -- the whole row, because what is being asserted is what the row now is.
  it("draws a mark, a name and a stat on an annotated row, and nothing else", function()
    local path = "apps/api/src/main.lua"
    vim.api.nvim_win_set_cursor(S.win, { assert(h.line_row(S, path)), 0 })
    annotate.annotate("bug")
    assert.same("    ● main.lua              +1 -1", row_text(path))
    queue.clear()
    view.paint()
  end)

  -- A guard rather than a red case: a directory row must come out of this unchanged. The
  -- pre-image is spelled out, because the builder has no switch that turns the stat off and
  -- so cannot be compared against itself.
  it("leaves every directory row byte-for-byte what it was", function()
    local rows = {}
    for row, _ in pairs(S.panel_render.row_dir) do
      rows[#rows + 1] = row
    end
    table.sort(rows)
    local text = {}
    for _, row in ipairs(rows) do
      text[#text + 1] = vim.api.nvim_buf_get_lines(S.panel_buf, row - 1, row, false)[1]
    end
    assert.same({
      "▾ apps                        0/4",
      "  ▾ api/src                   0/2",
      "    ▾ routes                  0/1",
      "  ▾ web/src                   0/2",
      "    ▾ components              0/1",
      "▾ docs                        0/1",
      "▾ packages/shared/src         0/1",
    }, text)
  end)

  -- A guard: no basename of this fixture is wide enough to be cut at the default width, on
  -- any row of it. What the deepest row's budget really is, is measured by the case above --
  -- this one only says that nothing here reaches it.
  it("cuts no name at the default panel width", function()
    -- The window is taken into a local first: luassert's `assert` returns three values, and
    -- a call position keeps all three.
    local panel_win = assert(S.panel_win)
    assert.same(34, vim.api.nvim_win_get_width(panel_win))
    for _, row in ipairs(S.panel_render.file_rows) do
      local text = vim.api.nvim_buf_get_lines(S.panel_buf, row - 1, row, false)[1]
      assert.is_nil(text:find("…", 1, true), text)
    end
  end)
end)

--- The cells a reviewer's screen holds, for the stat -------------------------------
--
-- One child per reading, because `nvim__inspect_cell` is honest only on the first call a
-- process makes. Each opens the same review over a fixture of this block's own, in the
-- unified layout at 80x24, and reads one cell of a file row's stat -- found by the range the
-- tree really emitted, except on the reviewed row, where the point is that there is none.
--
-- `00ee00` is what `CodeReviewStatAdd` resolves to, `00eeee` what `CodeReviewStatDel` does,
-- `ee0000` what both `CodeReviewNoteCount` and `CodeReviewFileReviewed` do, and `0000ee` the
-- background `CursorLine` carries -- which is what `CodeReviewPanelSel` resolves to on the row
-- the diff cursor is in.
describe("the cell a file row's stat is drawn on", function()
  local fixture = h.fixture("mktree")

  ---@param mode string
  ---@return string
  local function child(mode)
    local run = vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "row_stat_child.lua"),
      }, {
        cwd = fixture,
        text = true,
        env = {
          FIXTURE = fixture,
          MODE = mode,
          XDG_STATE_HOME = vim.fn.tempname() .. "-state",
          GIT_CONFIG_GLOBAL = "/dev/null",
          GIT_CONFIG_SYSTEM = "/dev/null",
        },
      })
      :wait(60000)
    -- `nvim -l` sends print to stderr, so read both streams rather than guessing.
    local out = (run.stdout or "") .. (run.stderr or "")
    assert(run.code == 0, out)
    -- A **notification** lands on the same stream `print` does, so the reading is picked out
    -- of that stream by name rather than by trimming the whole of it.
    local reading = assert(out:match("cell [^\n]*"), out)
    return (reading:gsub(" at %d+,%d+$", ""))
  end

  local added = child("added")
  local removed = child("removed")
  local current = child("current")
  local reviewed = child("reviewed")

  it("draws the added count in the added group's colour", function()
    assert.same('cell "+" fg=00ee00 bg=none', added)
  end)

  -- A second colour on a screen, and not merely a second name in a table.
  it("draws the removed count in another", function()
    assert.same('cell "-" fg=00eeee bg=none', removed)
  end)

  -- **The reading that says the stat survives the row a reviewer is looking at.** The
  -- background says the line-wide group really painted this row, so the case cannot pass on a
  -- row that never had one; the foreground says the stat's colour came through it.
  -- `CodeReviewPanelSel` resolves to `CursorLine`, which carries a background and no
  -- foreground, and a line-wide background leaves a range's foreground alone.
  it("keeps the colour on the row the diff cursor is in", function()
    assert.same('cell "+" fg=00ee00 bg=0000ee', current)
  end)

  -- **And the row the tree gives no colour at all.** `CodeReviewFileReviewed` resolves to
  -- `Comment`, which carries a foreground, and a line-wide foreground replaces a range's at
  -- every priority. So the two counts draw here in the comment colour whatever the tree asks
  -- for, and the tree asks for nothing: this reading is why that row is given no range rather
  -- than one that costs a paint and reaches no cell.
  it("draws the counts in the reviewed row's own colour, which no range could change", function()
    assert.same('cell "+" fg=ee0000 bg=none', reviewed)
  end)
end)
