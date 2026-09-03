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

  ---@param count integer
  ---@return table[]
  local function files_of(count)
    local out = {}
    for i = 1, count do
      out[i] = { path = ("src/f%02d.lua"):format(i) }
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
