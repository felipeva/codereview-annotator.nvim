-- The folder-tree panel: how the tree is built, folded, reviewed and navigated.
--
-- These assertions are structural, so they depend on exactly which files the nested
-- fixture contains. Regenerate it with tests/fixtures/mktree.sh rather than hand-editing
-- a fixture repo -- adding or omitting one file changes what compacts.
local h = require("tests.helpers")

h.ui(120, 45)
h.cd_fixture("mktree")

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
        top[#top + 1] = vim.trim(l):gsub("%s+%d+/%d+$", ""):gsub("%s+$", "")
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

  it("shows the root tally in the footer", function()
    local lines = panel_lines()
    assert.same(("0/%d reviewed"):format(#V.files), lines[#lines])
  end)

  it("moves the footer when a file is reviewed", function()
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[1], 0 })
    view.toggle_reviewed()
    local lines = panel_lines()
    assert.same(("1/%d reviewed"):format(#V.files), lines[#lines])
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

  it("counts that file's notes in the tree", function()
    local line = panel_lines()[row_of_file("packages/shared/src/types.lua")]
    assert.same("1", line:match("(%d)%s*$"))
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

  -- The number stays on the row for now. It is redundant once the colour is there, and the
  -- ticket that removes it and spends its columns on the `+N -M` stat is blocked by this one:
  -- taking it out here ships a row that lost information and gained none.
  it("leaves the note count number on the row", function()
    assert.same("1", tree_text(P, tree_row(P, BUG)):match("(%d+)%s*$"))
    assert.same("2", tree_text(P, tree_row(P, NIT_THEN_BUG)):match("(%d+)%s*$"))
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

  it("counts an entry of a type it no longer has, and never lets it lead", function()
    assert.same("1", tree_text(Q, tree_row(Q, STRANGER)):match("(%d+)%s*$"))
    assert.same("CodeReviewNoteCount", state_group(Q, STRANGER))
    assert.same("2", tree_text(Q, tree_row(Q, BOTH)):match("(%d+)%s*$"))
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
