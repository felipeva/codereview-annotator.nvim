-- The `open_diff` adapter: what a host is handed, and whether the key exists at all.
--
-- The adapter is a stub here, as every adapter in this suite is -- the seam is the point,
-- and there is no diff tool to drive. What is asserted is therefore what the adapter
-- *receives*: the absolute path, the two refs the scope is between, and the line.
--
-- The two halves have to run in this order. Whether `gd` is bound is decided when a review
-- opens, from whether the adapter is configured, so "nothing is bound" can only be asserted
-- by a process that has not yet injected one.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local view = require("codereview.view")

local root = assert(vim.uv.fs_realpath(fixture))

---Normal-mode mappings bound to a buffer, as a set.
---
---Through `vim.keycode` on both sides: the API reports a key in its own notation rather
---than the one it was bound with, so comparing the strings as written can silently never
---match.
---@param buf integer
---@return table<string, boolean>
local function bound(buf)
  local lhs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    lhs[vim.keycode(m.lhs)] = true
  end
  return lhs
end

---@return CRView
local function current()
  return assert(view.current(), "no review view open")
end

---@param path string
---@param pred fun(anchor: table): boolean
---@return integer
local function row_of(path, pred)
  return assert(h.row_of(current(), path, pred), "no such row for " .. path)
end

---@param path string
---@return integer
local function index_of(path)
  return assert(h.file_index(current(), path), path .. " is not in this scope")
end

--- With nothing injected -------------------------------------------------------

require("codereview").setup({ syntax = false })

describe("with no open_diff adapter wired", function()
  view.open("branch")
  local V = current()

  -- A key that silently does nothing is worse than no key: a reviewer who presses it
  -- learns nothing, and `gd` stays free for whatever else the host wants it for.
  it("binds nothing to gd, in the diff or in the tree", function()
    assert.is_nil(bound(V.buf)[vim.keycode("gd")], "gd is bound in the diff")
    assert.is_nil(bound(assert(V.panel_buf))[vim.keycode("gd")], "gd is bound in the tree")
  end)

  it("leaves the keys it sits beside alone", function()
    assert.is_true(bound(V.buf)[vim.keycode("gl")] == true)
    assert.is_true(bound(V.buf)[vim.keycode("gp")] == true)
  end)

  -- The action is exported, so a host can bind it itself. On that path the same silence
  -- would be the same defect, so it says what is missing instead.
  it("says what is missing when the action is called anyway", function()
    local msgs, restore = h.capture_notify()
    view.open_diff()
    restore()
    assert.is_true(h.notified(msgs, "open_diff"), "nothing said that the adapter is absent")
  end)

  view.close()
end)

--- With one injected -----------------------------------------------------------

---@type table[]
local handed = {}

require("codereview").setup({
  syntax = false,
  open_diff = function(spec)
    handed[#handed + 1] = spec
  end,
})

---The one spec the adapter was handed since the last call, and nothing else.
---@return table
local function only()
  assert.same(1, #handed)
  return handed[1]
end

local function reset()
  handed = {}
end

view.open("branch")

describe("the keystroke", function()
  local V = current()

  it("is bound in the diff and in the tree once the adapter is there", function()
    assert.is_true(bound(V.buf)[vim.keycode("gd")] == true, "gd is not bound in the diff")
    assert.is_true(bound(assert(V.panel_buf))[vim.keycode("gd")] == true, "gd is not bound in the tree")
  end)

  -- Opening a file from the review is a new tab, and `gt`/`gT` are how a reviewer comes
  -- back from it. Nothing added here may take them.
  it("shadows neither of the tab-switching keys", function()
    for _, buf in ipairs({ V.buf, assert(V.panel_buf) }) do
      assert.is_nil(bound(buf)[vim.keycode("gt")], "gt is shadowed")
      assert.is_nil(bound(buf)[vim.keycode("gT")], "gT is shadowed")
    end
  end)

  it("reaches the adapter when it is actually pressed", function()
    reset()
    local V2 = current()
    vim.api.nvim_set_current_win(V2.win)
    vim.api.nvim_win_set_cursor(V2.win, {
      row_of("src/fresh.lua", function(a)
        return a.kind == "line"
      end),
      0,
    })
    h.feed("gd")
    assert.same("src/fresh.lua", only().path:sub(#root + 2))
  end)
end)

--- What the adapter receives ---------------------------------------------------

describe("a scope whose post-image is the working tree", function()
  local base = h.git_lines(root, { "merge-base", "master", "HEAD" })[1]

  before_each(reset)

  it("hands over an absolute path and the ref the scope is against", function()
    vim.api.nvim_set_current_win(current().win)
    vim.api.nvim_win_set_cursor(current().win, {
      row_of("src/fresh.lua", function(a)
        return a.kind == "line"
      end),
      0,
    })
    view.open_diff()
    local spec = only()
    assert.same(vim.fs.joinpath(root, "src/fresh.lua"), spec.path)
    assert.same(base, spec.before)
  end)

  -- Not an error and not worth a sentinel: nil says the post-image is the file on disk,
  -- which is exactly what a diff tool would open anyway.
  it("says the post-image is the working tree with nil, not a sentinel", function()
    vim.api.nvim_win_set_cursor(current().win, {
      row_of("src/fresh.lua", function(a)
        return a.kind == "line"
      end),
      0,
    })
    view.open_diff()
    assert.is_nil(only().after)
  end)

  it("passes the post-image line the cursor is on", function()
    vim.api.nvim_win_set_cursor(current().win, {
      row_of("src/main.lua", function(a)
        return a.kind == "line" and a.line == 3
      end),
      0,
    })
    view.open_diff()
    assert.same(2, only().line)
  end)

  -- The rule `<CR>` already uses, reused rather than written a second time: a deletion
  -- exists in no post-image, so it resolves to the nearest preceding line that does --
  -- line 1 here, not the 2 the deleted line held in the pre-image.
  it("resolves a deleted line to the nearest preceding line that exists", function()
    vim.api.nvim_win_set_cursor(current().win, {
      row_of("src/main.lua", function(a)
        return a.kind == "line" and a.line == 2
      end),
      0,
    })
    view.open_diff()
    assert.same(1, only().line)
  end)

  -- A file header knows which file, and nothing about where in it.
  it("passes no line from a file header", function()
    vim.api.nvim_win_set_cursor(current().win, { current().render.file_rows[index_of("src/main.lua")], 0 })
    view.open_diff()
    assert.is_nil(only().line)
  end)
end)

describe("a scope whose post-image is a ref", function()
  before_each(reset)

  it("hands over both refs", function()
    view.set_scope("staged")
    vim.api.nvim_set_current_win(current().win)
    vim.api.nvim_win_set_cursor(current().win, {
      row_of("src/routes.lua", function(a)
        return a.kind == "line"
      end),
      0,
    })
    view.open_diff()
    local spec = only()
    assert.same({ "HEAD", ":0" }, { spec.before, spec.after })
    assert.same(vim.fs.joinpath(root, "src/routes.lua"), spec.path)
  end)

  view.set_scope("branch")
end)

--- From the tree ---------------------------------------------------------------

describe("from the file tree", function()
  before_each(reset)

  ---Put the tree's cursor on a file's row and take focus there.
  ---@param path string
  local function on_tree_row(path)
    local V = current()
    local win = assert(V.panel_win, "the tree is not showing")
    local want = index_of(path)
    for row, fi in pairs(assert(V.panel_render).row_file) do
      if fi == want then
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { row, 0 })
        return
      end
    end
    error("no tree row for " .. path)
  end

  -- The tree knows a file, not a position, so there is no line to invent.
  it("hands over the file with no line", function()
    on_tree_row("src/main.lua")
    h.feed("gd")
    local spec = only()
    assert.same(vim.fs.joinpath(root, "src/main.lua"), spec.path)
    assert.is_nil(spec.line)
  end)

  it("does nothing on a directory row", function()
    local V = current()
    local win = assert(V.panel_win, "the tree is not showing")
    local dir_row
    for row, dir in pairs(assert(V.panel_render).row_dir) do
      if dir then
        dir_row = row
        break
      end
    end
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { assert(dir_row, "the tree has no directory row"), 0 })
    h.feed("gd")
    assert.same(0, #handed)
  end)
end)

--- In the split layout ---------------------------------------------------------

-- Last, because toggling the layout is remembered for the rest of the session.
describe("in the split layout", function()
  before_each(reset)

  ---Row in a pane holding a diff line of `path` on the given side.
  ---@param rendered CRRender
  ---@param path string
  ---@param side "add"|"del"
  ---@return integer
  local function side_row(rendered, path, side)
    local V = current()
    for row = 1, #rendered.lines do
      local a = rendered.anchors[row]
      if a and a.kind == "line" and V.files[a.file].path == path then
        if V.files[a.file].hunks[a.hunk].lines[a.line].side == side then
          return row
        end
      end
    end
    error(("no %s line for %s"):format(side, path))
  end

  vim.api.nvim_set_current_win(current().win)
  view.toggle_layout()

  it("is bound in the before pane too", function()
    assert.is_true(bound(assert(current().before_buf))[vim.keycode("gd")] == true)
  end)

  -- `src/main.lua`'s deletion and its replacement collapse onto one row here, so the two
  -- panes genuinely disagree about that row: the before pane holds the deleted line and
  -- the after pane the line that replaced it. Which pane has focus is the whole answer.
  it("resolves from the pane that has focus", function()
    local V = current()
    local after_row = side_row(V.render, "src/main.lua", "add")
    local before_row = side_row(assert(V.before_render), "src/main.lua", "del")
    assert.same(after_row, before_row, "the two panes do not share the row this case is about")

    vim.api.nvim_set_current_win(V.win)
    vim.api.nvim_win_set_cursor(V.win, { after_row, 0 })
    view.open_diff()
    assert.same(2, only().line)

    reset()
    local before_win = assert(V.before_win, "there is no before pane")
    vim.api.nvim_set_current_win(before_win)
    vim.api.nvim_win_set_cursor(before_win, { before_row, 0 })
    view.open_diff()
    assert.same(1, only().line)
  end)
end)
