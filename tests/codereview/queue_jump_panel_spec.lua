-- The queue float's jump and the file tree, together.
--
-- Neither slice could cover this. The jump was written against a base where the tree was
-- constant for the life of a review -- always there or never -- and the toggle against one
-- where the float could not move the cursor at all. What their combination implies is that
-- `V.panel_win` now transitions at runtime *underneath* a jump, which drives the tree twice
-- on its way: once through the repaint that expands a collapsed file, and once through the
-- cursor move that follows it.
local h = require("tests.helpers")

-- The nested fixture, as panel_spec uses: a tree whose rows are compacted directory chains
-- rather than one row per file, so "which row is highlighted" is a real question.
h.ui(120, 45)
h.cd_fixture("mktree")

---@param panel table|nil Panel options, or nil for the default: enabled, on the left
local function setup(panel)
  require("codereview").setup({
    syntax = false,
    panel = panel,
    compose = function(_, on_accept)
      on_accept(nil, "a note")
    end,
  })
end

setup(nil)

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")

view.open("branch")
local V = view.current()
queue.clear()

local NS_PANEL = vim.api.nvim_create_namespace("codereview_panel")

---@param kind "file"|"line"
---@param path string|nil
---@return integer|nil
local function row_of(kind, path)
  for row = 1, vim.api.nvim_buf_line_count(V.buf) do
    local a = V.render.anchors[row]
    if a and a.kind == kind and (not path or V.files[a.file].path == path) then
      return row
    end
  end
end

---@param row integer
---@return integer row
local function annotate_row(row)
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  annotate.annotate("bug")
  return row
end

local function park()
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
end

---@return integer win
local function open_float()
  view.review_queue()
  return vim.api.nvim_get_current_win()
end

---Put the float's cursor on the only entry it is listing, and press the jump key.
---@param win integer
local function jump_from(win)
  for row, text in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)) do
    if text:match("^1%. ") then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      h.feed("<CR>")
      return
    end
  end
  error("nothing listed in the float")
end

local function shown()
  return V.panel_win ~= nil and vim.api.nvim_win_is_valid(V.panel_win)
end

---Tree row carrying the current-file highlight, as panel_spec reads it.
---@return integer
local function selected_row()
  local sel = vim.tbl_filter(function(m)
    return m[4].line_hl_group == "CodeReviewPanelSel"
  end, vim.api.nvim_buf_get_extmarks(V.panel_buf, NS_PANEL, 0, -1, { details = true }))
  assert.same(1, #sel)
  return sel[1][2] + 1
end

---Read a file in the diff the way a reviewer does, autocmd and all -- which is what moves
---the tree's latch, and the only thing that does.
---@param path string
---@return integer index
local function look_at(path)
  local index = assert(h.file_index(V, path))
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index], 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
  return index
end

describe("jumping with the tree dismissed", function()
  local path = "apps/api/src/main.lua"
  local index = assert(h.file_index(V, path))
  annotate_row(assert(row_of("line", path)))

  -- Reviewed, so the file collapses and the row the annotation is about stops being
  -- rendered at all. The jump therefore has to repaint before it can land, and that
  -- repaint now runs with no tree beside it to repaint.
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index], 0 })
  view.toggle_reviewed()
  view.toggle_panel()

  local dismissed = shown()
  local while_collapsed = row_of("line", path)

  park()
  local win = open_float()
  jump_from(win)

  local landed = vim.api.nvim_win_get_cursor(V.win)[1]
  local reopened = row_of("line", path)

  -- Guards the test itself: with a tree still up, or a file still expanded, neither half
  -- of what this is about would be exercised.
  it("really had no tree, and nothing to land on", function()
    assert.is_false(dismissed)
    assert.is_nil(while_collapsed)
  end)

  it("expands the file and lands on its code", function()
    assert.is_true(V.expanded[path])
    assert.is_truthy(reopened)
    assert.same(reopened, landed)
  end)

  it("leaves focus in the diff and closes the float", function()
    assert.same(V.win, vim.api.nvim_get_current_win())
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("conjures no tree on the way", function()
    assert.is_false(shown())
    assert.is_nil(V.panel_render)
  end)
end)

describe("summoning the tree after that jump", function()
  local index = assert(h.file_index(V, "apps/api/src/main.lua"))
  view.toggle_panel()

  it("comes back", function()
    assert.is_true(shown())
  end)

  it("highlights the file the jump landed in", function()
    assert.same(V.panel_render.file_row[index], selected_row())
  end)
end)

-- The sharp one. The tree repaints only when the diff cursor crosses into a *different*
-- file than the one it last painted for, so the file being read when the tree is dismissed
-- is precisely the file a latch left behind would refuse to repaint for. Reaching it by a
-- jump rather than by scrolling is what neither slice tested: the jump moves the cursor
-- itself and syncs the tree itself, without waiting for CursorMoved.
describe("jumping into the file the tree was dismissed on", function()
  queue.clear()
  view.paint()

  local home, away = "apps/web/src/index.lua", "docs/guide.md"
  local hi = look_at(home)
  annotate_row(assert(row_of("line", home)))
  look_at(home)

  local home_row = V.panel_render.file_row[hi]
  local selected_before = selected_row()

  view.toggle_panel()
  local ai = look_at(away)
  view.toggle_panel()

  local away_row = V.panel_render.file_row[ai]
  local selected_on_return = selected_row()

  local win = open_float()
  jump_from(win)

  local selected_after = selected_row()
  local panel_cursor = vim.api.nvim_win_get_cursor(V.panel_win)[1]
  local home_row_now = V.panel_render.file_row[hi]

  it("was following the diff before the tree went away", function()
    assert.same(home_row, selected_before)
  end)

  -- Guards the test itself: if the tree came back already pointing at the jump's
  -- destination, the assertion below would pass with nothing having moved it.
  it("comes back pointing at what was read while it was gone", function()
    assert.is_true(home_row ~= away_row)
    assert.same(away_row, selected_on_return)
  end)

  it("follows the jump back into the file it was dismissed on", function()
    assert.same(home_row_now, selected_after)
  end)

  it("takes the tree's own cursor there too", function()
    assert.same(home_row_now, panel_cursor)
  end)
end)

-- Last: this reopens the review, so every `V` above it is gone.
describe("a review that opens with no tree at all", function()
  view.close()
  setup({ enabled = false })
  view.open("branch")
  V = view.current()
  queue.clear()

  local target = annotate_row(assert(row_of("line", "packages/shared/src/types.lua")))
  park()
  local win = open_float()
  jump_from(win)

  it("never had a tree", function()
    assert.is_false(shown())
    assert.is_nil(V.panel_render)
  end)

  it("jumps anyway", function()
    assert.same(target, vim.api.nvim_win_get_cursor(V.win)[1])
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
end)
