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

  -- The tree repaints only when the diff cursor crosses into a different file, and while
  -- there is no tree to repaint that latch is holding a file nobody is reading any more.
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
