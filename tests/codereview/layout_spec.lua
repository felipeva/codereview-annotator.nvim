-- Switching layout without losing your place.
--
-- Buffer rows mean nothing across layouts: the same line of the same hunk sits at a
-- different row in each, because only row placement changes. So every case here asserts the
-- **anchor** under the cursor -- file, hunk and line -- and never the row, and each one
-- starts somewhere the two layouts genuinely disagree about. A toggle from row 1, or from a
-- file the collapse of a deletion above it has not shifted, proves nothing: the row would
-- have survived a toggle that carried it across unchanged, which is the bug.
--
-- The window is deliberately short enough that the diff does not fit in it. Centring is
-- unobservable in a window taller than its buffer, and the assertion would pass with `zz`
-- deleted.
local h = require("tests.helpers")

h.ui(160, 24)
local fixture = h.cd_fixture("mkfixture")

local config = require("codereview.config")
local delivery = require("codereview.delivery")
local queue = require("codereview.queue")
local state = require("codereview.state")
local annotate = require("codereview.annotate")
local view = require("codereview.view")

local note_text = "a note"
require("codereview").setup({
  layout = "unified",
  syntax = false,
  compose = function(_, on_accept, _)
    on_accept(nil, note_text)
  end,
  pick_target = function(cb)
    cb({ short = "agent-7" })
  end,
})

local root = assert(vim.uv.fs_realpath(fixture))

--- Across a genuine restart ------------------------------------------------------

-- First, before this process has toggled anything: a session that chose the split layout
-- and exited, and then this one, which is the session after it.
describe("a session that chose the split layout and exited", function()
  -- Shares this process's throwaway XDG_STATE_HOME and nothing else, and runs with
  -- `--clean` so no user config and no minimal_init can hand it a different one.
  local child = vim
    .system({
      vim.v.progpath,
      "--clean",
      "-l",
      vim.fs.joinpath(h.root, "tests", "codereview", "layout_child.lua"),
    }, {
      cwd = fixture,
      text = true,
      env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = fixture },
    })
    :wait(60000)

  it("exits cleanly", function()
    assert.same(0, child.code, (child.stderr or "") .. (child.stdout or ""))
  end)

  -- Without this the case below is vacuous: "nothing about the layout came back" would be
  -- satisfied by there being no channel between the two sessions at all.
  it("leaves a state file behind, so the two sessions really do share a store", function()
    assert.same(1, vim.fn.filereadable(state.path(root)), "no state at " .. state.path(root))
  end)

  it("writes nothing about the layout into it", function()
    local text = table.concat(vim.fn.readfile(state.path(root)), "\n")
    assert.is_nil(text:find("layout", 1, true), text)
    assert.is_nil(text:find("split", 1, true), text)
  end)
end)

describe("the session after it", function()
  view.open("branch")
  local V = assert(view.current())

  it("restores what the store does carry", function()
    assert.same(1, vim.tbl_count(V.reviewed))
  end)

  -- Configuration is what decides at the start of every session, so a preference chosen in
  -- one cannot silently override a config that has changed since.
  it("opens in the configured layout, not the one that session chose", function()
    assert.same("unified", config.get().layout)
    assert.same("unified", V.layout)
    assert.is_nil(V.before_win)
  end)

  view.close()
  state.clear(root)
  queue.clear()
end)

--- In one session ----------------------------------------------------------------

view.open("branch")
queue.clear()

---@return CRView
local function current()
  return assert(view.current(), "no review view open")
end

---@param win integer
local function focus(win)
  vim.api.nvim_set_current_win(win)
end

---@param win integer
---@return integer
local function row_in(win)
  return vim.api.nvim_win_get_cursor(win)[1]
end

---@param win integer
---@return integer
local function topline(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)
end

---The anchor under the cursor, reduced to what a layout is not allowed to change.
---@return table
local function anchor_here()
  local a = assert(view.anchor_at_cursor(), "no anchor under the cursor")
  return { kind = a.kind, file = a.file, hunk = a.hunk, line = a.line }
end

---@param want "unified"|"split"
local function in_layout(want)
  if (current().before_win ~= nil) ~= (want == "split") then
    view.toggle_layout()
  end
  assert(current().layout == want, "could not reach the " .. want .. " layout")
end

---Row in a pane holding a diff line of `path` on the given side.
---@param rendered CRRender
---@param path string
---@param side "add"|"del"|"ctx"
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

---@param path string
---@return integer
local function index_of(path)
  return assert(h.file_index(current(), path), path .. " is not in this scope")
end

-- `src/newname.lua` and `src/routes.lua` both sit *below* `src/main.lua`, whose deletion and
-- its replacement collapse onto one row in the split layout. Every row in them therefore
-- moves when the layout changes, which is what gives the cases below their teeth.
local NEWNAME, ROUTES = "src/newname.lua", "src/routes.lua"

---Put the cursor on a diff line in whichever layout is showing, and report where it is.
---@param path string
---@param side "add"|"del"|"ctx"
---@return table anchor, integer row, integer win
local function start_on(path, side)
  local V = current()
  local before = side == "del" and V.before_win ~= nil
  local win = before and V.before_win or V.win
  local row = side_row(before and V.before_render or V.render, path, side)
  focus(win)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  return anchor_here(), row, win
end

describe("the keystroke", function()
  ---@param buf integer
  ---@return table<string, boolean>
  local function bound(buf)
    local lhs = {}
    -- Through `vim.keycode` on both sides: the API reports a key in its own notation rather
    -- than the one it was bound with, so comparing the strings as written can silently
    -- never match.
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      lhs[vim.keycode(m.lhs)] = true
    end
    return lhs
  end

  it("sits alongside the other view-level commands, in both panes and in the tree", function()
    in_layout("split")
    local V = current()
    for _, buf in ipairs({ V.buf, V.before_buf, V.panel_buf }) do
      local lhs = bound(buf)
      assert.is_true(lhs[vim.keycode("gl")] == true, "gl is not bound")
      -- The company it keeps: the other `g` commands this one was chosen to sit beside.
      assert.is_true(lhs[vim.keycode("gp")] == true)
    end
  end)

  -- `<CR>` opens the real file in a new tab, and `gT` is how a reviewer comes back from it.
  it("shadows neither of the tab-switching keys anywhere in the view", function()
    local V = current()
    for _, buf in ipairs({ V.buf, V.before_buf, V.panel_buf }) do
      local lhs = bound(buf)
      assert.is_falsy(lhs[vim.keycode("gt")], "gt is shadowed")
      assert.is_falsy(lhs[vim.keycode("gT")], "gT is shadowed")
    end
  end)

  -- Driven through the keys rather than by calling the action: a mapping that was never
  -- bound, or bound to a buffer that has since been rebuilt, passes every other assertion.
  it("switches the layout when it is actually pressed in the after pane", function()
    in_layout("split")
    focus(current().win)
    h.feed("gl")
    assert.same("unified", current().layout)
    assert.is_nil(current().before_win)

    h.feed("gl")
    assert.same("split", current().layout)
    assert.is_truthy(current().before_win)
  end)

  it("switches it from the before pane too", function()
    in_layout("split")
    focus(current().before_win)
    h.feed("gl")
    assert.same("unified", current().layout)
    -- The pane the key was pressed in is gone, so focus cannot have been left in it.
    assert.same(current().win, vim.api.nvim_get_current_win())
  end)

  it("switches it from the file tree too", function()
    in_layout("unified")
    focus(assert(current().panel_win, "no tree to press it in"))
    h.feed("gl")
    assert.same("split", current().layout)
    assert.same(current().panel_win, vim.api.nvim_get_current_win())
  end)
end)

describe("a deleted line", function()
  it("really starts somewhere the two layouts disagree about", function()
    in_layout("unified")
    local V = current()
    local unified_row = side_row(V.render, NEWNAME, "del")
    in_layout("split")
    local split_row = side_row(current().before_render, NEWNAME, "del")
    assert.is_true(
      unified_row ~= split_row,
      ("row %d in both layouts -- this case cannot tell an anchor from a row"):format(unified_row)
    )
  end)

  it("lands in the before pane, on the same line of the same hunk", function()
    in_layout("unified")
    local start = start_on(NEWNAME, "del")
    view.toggle_layout()

    local V = current()
    assert.same(V.before_win, vim.api.nvim_get_current_win())
    assert.same(start, anchor_here())
    assert.same("del", V.files[start.file].hunks[start.hunk].lines[start.line].side)
  end)

  it("comes back to exactly the row it started on", function()
    in_layout("unified")
    local start, row = start_on(NEWNAME, "del")
    view.toggle_layout()
    local moved = row_in(vim.api.nvim_get_current_win())
    view.toggle_layout()

    assert.same("unified", current().layout)
    assert.same(current().win, vim.api.nvim_get_current_win())
    assert.same(start, anchor_here())
    assert.same(row, row_in(current().win))
    -- And the round trip was not a row surviving unchanged.
    assert.is_true(moved ~= row, ("the anchor never moved rows (%d)"):format(row))
  end)
end)

describe("an added line", function()
  it("lands in the after pane, on the same line of the same hunk", function()
    in_layout("unified")
    local start, row = start_on(NEWNAME, "add")
    view.toggle_layout()

    local V = current()
    assert.same(V.win, vim.api.nvim_get_current_win())
    assert.same(start, anchor_here())
    assert.is_true(row_in(V.win) ~= row, "the anchor never moved rows")
  end)

  it("comes back to exactly where it started", function()
    in_layout("unified")
    local start, row = start_on(NEWNAME, "add")
    view.toggle_layout()
    view.toggle_layout()
    assert.same(start, anchor_here())
    assert.same(row, row_in(current().win))
  end)
end)

-- A context line exists in both images and its key prefers the post-image, which is why it
-- reads in the after pane -- the same rule that decides where its notes are drawn.
describe("a context line", function()
  it("lands in the after pane", function()
    in_layout("unified")
    local start, row = start_on(ROUTES, "ctx")
    view.toggle_layout()

    assert.same(current().win, vim.api.nvim_get_current_win())
    assert.same(start, anchor_here())
    assert.is_true(row_in(current().win) ~= row, "the anchor never moved rows")
  end)
end)

describe("a cursor on filler", function()
  ---Filler in the before pane with real code above it in the same pane -- so a walk upward
  ---would have found a line the reviewer was not looking at, which is the whole reason
  ---filler carries an anchor of its own.
  ---@return integer row, integer above
  local function filler_row()
    local V = current()
    local fi = index_of(ROUTES)
    local above
    for row = 1, #V.before_render.lines do
      local a = V.before_render.anchors[row]
      if a.file == fi and a.kind == "line" then
        above = row
      elseif a.file == fi and a.kind == "fill" and above then
        return row, above
      end
    end
    error("no filler with code above it in " .. ROUTES)
  end

  it("really starts on filler, with unrelated code above it", function()
    in_layout("split")
    local row, above = filler_row()
    local V = current()
    assert.same("fill", V.before_render.anchors[row].kind)
    assert.same("line", V.before_render.anchors[above].kind)
    assert.is_true(row > above)
  end)

  -- It has no counterpart in the unified layout at all, so it means the file: the same
  -- reading target resolution already gives it.
  it("falls back to that file's header", function()
    in_layout("split")
    local row, above = filler_row()
    local V = current()
    local above_anchor = V.before_render.anchors[above]
    focus(V.before_win)
    vim.api.nvim_win_set_cursor(V.before_win, { row, 0 })

    view.toggle_layout()
    local after = current()
    assert.same({ kind = "file", file = index_of(ROUTES) }, anchor_here())
    assert.same(after.render.file_rows[index_of(ROUTES)], row_in(after.win))
    -- Not the line above it, which is what a walk upward would have carried across.
    assert.is_true(anchor_here().line ~= above_anchor.line)
  end)
end)

describe("a collapsed file's header", function()
  it("stays on that file's header", function()
    in_layout("unified")
    local V = current()
    local fi = index_of(NEWNAME)
    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
    view.toggle_expand()
    assert.is_false(V.expanded[NEWNAME], "the file never collapsed")

    view.toggle_layout()
    assert.same({ kind = "file", file = fi }, anchor_here())
    assert.same(current().render.file_rows[fi], row_in(current().win))
    -- Collapse is layout-independent, so it is still collapsed on the other side.
    assert.is_false(current().expanded[NEWNAME])

    view.toggle_expand()
    assert.is_true(current().expanded[NEWNAME])
  end)
end)

describe("the landing line", function()
  it("is far enough down that centring is observable at all", function()
    in_layout("unified")
    local V = current()
    local row = side_row(V.render, "src/untracked.lua", "add")
    assert.is_true(
      row > vim.api.nvim_win_get_height(V.win),
      ("row %d fits in a %d-row window, so nothing can scroll"):format(row, vim.api.nvim_win_get_height(V.win))
    )
  end)

  it("is centred", function()
    in_layout("unified")
    start_on("src/untracked.lua", "add")
    view.toggle_layout()

    local win = vim.api.nvim_get_current_win()
    local was = topline(win)
    -- Centred is exactly "a `zz` here would change nothing".
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zz")
    end)
    assert.same(was, topline(win))
    assert.is_true(was > 1, "the window never scrolled, so this measured nothing")
  end)

  it("leaves both panes reading the same rows", function()
    in_layout("unified")
    start_on("src/untracked.lua", "add")
    view.toggle_layout()

    local V = current()
    assert.same(row_in(V.win), row_in(V.before_win))
    assert.same(topline(V.win), topline(V.before_win))
  end)
end)

-- Putting a row on screen runs the same view command in both panes, and the toggle's
-- centring shares that with every jump. Asserted here rather than in `split_spec`, whose
-- window is taller than the whole diff: nothing scrolls there, so nothing can come apart.
describe("a jump in a window shorter than the diff", function()
  it("leaves both panes on the same row and the same top line", function()
    in_layout("split")
    local V = current()
    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    for _ = 1, #V.files do
      view.jump("file", true)
    end

    assert.is_true(topline(V.win) > 1, "no jump ever scrolled, so this measured nothing")
    assert.same(row_in(V.win), row_in(V.before_win))
    assert.same(topline(V.win), topline(V.before_win))
  end)
end)

describe("toggling from the file tree", function()
  it("keeps focus in the tree and moves the diff underneath it", function()
    in_layout("unified")
    local start, row = start_on(NEWNAME, "add")
    local V = current()
    focus(assert(V.panel_win, "no tree to toggle from"))

    view.toggle_layout()
    assert.same("split", current().layout)
    assert.same(current().panel_win, vim.api.nvim_get_current_win())
    -- The diff cursor moved even though focus did not: `anchor_at_cursor` answers for the
    -- after pane when it is asked from neither.
    assert.same(start, anchor_here())
    assert.is_true(row_in(current().win) ~= row)
  end)

  it("comes back the same way", function()
    focus(assert(current().panel_win))
    view.toggle_layout()
    assert.same("unified", current().layout)
    assert.same(current().panel_win, vim.api.nvim_get_current_win())
  end)
end)

describe("with the tree dismissed", function()
  it("really dismissed it", function()
    in_layout("unified")
    focus(current().win)
    view.toggle_panel()
    assert.is_nil(current().panel_win)
  end)

  it("switches layout with no tree beside it, keeping the anchor", function()
    local start = start_on(NEWNAME, "del")
    view.toggle_layout()

    local V = current()
    assert.same("split", V.layout)
    assert.is_nil(V.panel_win)
    assert.same(V.before_win, vim.api.nvim_get_current_win())
    assert.same(start, anchor_here())
  end)

  it("gives the columns the tree is not using to both panes", function()
    local V = current()
    local before, after = vim.api.nvim_win_get_width(V.before_win), vim.api.nvim_win_get_width(V.win)
    assert.is_true(math.abs(before - after) <= 1, ("%d vs %d"):format(before, after))
    assert.same(vim.o.columns, before + after + 1)
  end)

  it("summons the tree back beside two panes", function()
    view.toggle_panel()
    local V = current()
    assert.is_truthy(V.panel_win and vim.api.nvim_win_is_valid(V.panel_win))
    local before, after = vim.api.nvim_win_get_width(V.before_win), vim.api.nvim_win_get_width(V.win)
    assert.is_true(math.abs(before - after) <= 1, ("%d vs %d"):format(before, after))
  end)
end)

describe("annotations queued before a toggle", function()
  ---Every extmark in `buf` carrying virtual lines, and the text of the first of them.
  ---@param buf integer
  ---@return table<integer, string> by 0-indexed row
  local function notes_on(buf)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, h.NS, 0, -1, { details = true })) do
      if m[4].virt_lines then
        local text = ""
        for _, line in ipairs(m[4].virt_lines) do
          for _, chunk in ipairs(line) do
            text = text .. chunk[1]
          end
        end
        out[m[2]] = text
      end
    end
    return out
  end

  in_layout("unified")
  queue.clear()
  do
    note_text = "about the deletion"
    start_on(NEWNAME, "del")
    annotate.annotate("bug")
    note_text = "about the addition"
    start_on(NEWNAME, "add")
    annotate.annotate("bug")
    note_text = "a note"
  end

  it("really queued both, in the layout that has one pane", function()
    assert.same("unified", current().layout)
    assert.same(2, queue.count())
  end)

  it("draws both in the one buffer before the toggle", function()
    local drawn = notes_on(current().buf)
    local text = table.concat(vim.tbl_values(drawn), "|")
    assert.is_truthy(text:find("about the deletion", 1, true))
    assert.is_truthy(text:find("about the addition", 1, true))
  end)

  it("re-draws each on the pane its line belongs to", function()
    view.toggle_layout()
    local V = current()
    local del_row = side_row(V.before_render, NEWNAME, "del")
    local add_row = side_row(V.render, NEWNAME, "add")

    assert.is_truthy(notes_on(V.before_buf)[del_row - 1], "the deletion's note is not in the before pane")
    assert.is_truthy(
      notes_on(V.before_buf)[del_row - 1]:find("about the deletion", 1, true),
      notes_on(V.before_buf)[del_row - 1]
    )
    assert.is_truthy(
      notes_on(V.buf)[add_row - 1] and notes_on(V.buf)[add_row - 1]:find("about the addition", 1, true),
      "the addition's note is not in the after pane"
    )
    -- Neither note reached the pane it is not about.
    assert.is_falsy(notes_on(V.buf)[del_row - 1]:find("about the deletion", 1, true))
  end)

  it("keeps every note through a round trip", function()
    view.toggle_layout()
    local drawn = table.concat(vim.tbl_values(notes_on(current().buf)), "|")
    assert.same(2, queue.count())
    assert.is_truthy(drawn:find("about the deletion", 1, true))
    assert.is_truthy(drawn:find("about the addition", 1, true))
  end)

  queue.clear()
  view.paint()
end)

-- The queue float's jump landed before the layout could be switched, and it resolves an
-- entry's key back to a row -- so a toggle after one is a question about the row the jump
-- chose and the pane it chose it in.
describe("jumping from the queue float and then toggling", function()
  it("carries the jump's anchor across the toggle", function()
    in_layout("split")
    queue.clear()
    start_on(NEWNAME, "del")
    annotate.annotate("bug")
    local entry = queue.all()[1]

    -- Somewhere else entirely, in the other pane.
    local V = current()
    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
    assert.is_true(view.jump_to_entry(entry))
    assert.same(V.before_win, vim.api.nvim_get_current_win())
    local landed = anchor_here()
    assert.same("line", landed.kind)

    view.toggle_layout()
    assert.same("unified", current().layout)
    assert.same(landed, anchor_here())
    assert.same(current().win, vim.api.nvim_get_current_win())

    queue.clear()
    view.paint()
  end)
end)

describe("what a toggle leaves alone", function()
  in_layout("unified")
  queue.clear()
  -- Cleared as well as emptied: changing scope restores the persisted queue when the
  -- in-memory one is empty, which would hand back what an earlier case queued and make the
  -- count below two.
  state.clear(root)

  ---@return table
  local function everything()
    local V = current()
    return {
      reviewed = vim.deepcopy(V.reviewed),
      expanded = vim.deepcopy(V.expanded),
      collapsed = vim.deepcopy(V.collapsed),
      scope = V.scope.name,
      queued = queue.count(),
      key = queue.all()[1] and queue.all()[1].key,
      target = delivery.target_label(),
    }
  end

  -- Every one of these set deliberately, so that "unchanged" is not "empty on both sides".
  -- The scope first: reviewed marks and expansion are tracked per scope, so anything set
  -- before a scope change belongs to the scope it was set in and is not what a toggle would
  -- have to preserve.
  view.set_scope("worktree")
  start_on(ROUTES, "add")
  annotate.annotate("bug")
  local V = current()
  focus(V.win)
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index_of("src/untracked.lua")], 0 })
  view.toggle_reviewed()
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index_of(ROUTES)], 0 })
  view.toggle_expand()
  view.pick_target()
  focus(current().panel_win)
  do
    local row
    for r, dir in pairs(current().panel_render.row_dir) do
      if dir == "src" then
        row = r
      end
    end
    vim.api.nvim_win_set_cursor(current().panel_win, { assert(row, "no src directory row"), 0 })
    view.panel_fold(true)
  end
  focus(current().win)

  local before_toggle = everything()

  it("really had something to leave alone", function()
    assert.is_truthy(before_toggle.reviewed["src/untracked.lua"], "nothing was marked reviewed")
    assert.is_false(before_toggle.expanded[ROUTES])
    assert.is_true(before_toggle.collapsed["src"] == true, "the tree's src directory never collapsed")
    assert.same(1, before_toggle.queued)
    assert.same("worktree", before_toggle.scope)
    assert.same("agent-7", before_toggle.target)
  end)

  it("changes none of it", function()
    view.toggle_layout()
    assert.same("split", current().layout)
    assert.same(before_toggle, everything())
  end)

  it("changes none of it coming back either", function()
    view.toggle_layout()
    assert.same("unified", current().layout)
    assert.same(before_toggle, everything())
  end)

  it("still keeps the tree's collapsed directories off the screen", function()
    local drawn = table.concat(current().panel_render.lines, "\n")
    assert.is_falsy(drawn:find("main.lua", 1, true), drawn)
  end)

  view.set_scope("branch")
  queue.clear()
  state.clear(root)
end)

describe("the choice, for the rest of the session", function()
  it("is not the configured default, which is untouched", function()
    in_layout("split")
    assert.same("unified", config.get().layout)
    assert.same("split", current().layout)
  end)

  it("survives closing a review and opening another", function()
    in_layout("split")
    view.close()
    assert.is_nil(view.current())

    view.open("branch")
    assert.same("split", current().layout)
    assert.is_truthy(current().before_win and vim.api.nvim_win_is_valid(current().before_win))
  end)

  it("survives opening a review in a different scope", function()
    view.close()
    view.open("staged")
    assert.same("split", current().layout)
  end)

  it("switches back the same way", function()
    in_layout("unified")
    view.close()
    view.open("branch")
    assert.same("unified", current().layout)
    assert.is_nil(current().before_win)
  end)

  -- That store is per repository and a layout preference is not; and a persisted preference
  -- would silently override a later configuration change.
  it("reaches no state file, even after a write that does", function()
    in_layout("split")
    local V = current()
    focus(V.win)
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[1], 0 })
    view.toggle_reviewed()

    assert.same(1, vim.fn.filereadable(state.path(root)), "nothing was written to compare against")
    local text = table.concat(vim.fn.readfile(state.path(root)), "\n")
    assert.is_nil(text:find("layout", 1, true), text)
    assert.is_nil(text:find("split", 1, true), text)

    view.toggle_reviewed()
    state.clear(root)
  end)
end)

-- The pane the toggle rebuilt is a *new* buffer: its predecessor was `bufhidden = "wipe"`,
-- so closing the window took the buffer, its keymaps and its autocommands with it. Nothing
-- that drives the view's exported actions can notice.
describe("the pane a toggle rebuilt", function()
  it("is not the buffer it was before", function()
    in_layout("split")
    local first = current().before_buf
    in_layout("unified")
    in_layout("split")
    assert.is_true(current().before_buf ~= first, "the before pane came back in the same buffer")
    assert.is_false(vim.api.nvim_buf_is_valid(first), "the dismissed pane's buffer was never wiped")
  end)

  it("carries the diff's keys again", function()
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(current().before_buf, "n")) do
      lhs[vim.keycode(m.lhs)] = true
    end
    for _, key in ipairs({ "ab", "aa", "x", "]f", "]a", "R", "za", "gp", "gl", "<C-p>", "Q" }) do
      assert.is_true(lhs[vim.keycode(key)] == true, ("%s is not bound in the rebuilt pane"):format(key))
    end
  end)

  it("annotates a deleted line from it, through the keys", function()
    queue.clear()
    note_text = "from the rebuilt pane"
    start_on(NEWNAME, "del")
    h.feed("ab")
    note_text = "a note"

    assert.same(1, queue.count())
    local entry = queue.all()[1]
    assert.same(NEWNAME, entry.path)
    -- Keyed to the pre-image, which is what makes it the deleted line and not its
    -- replacement.
    assert.is_truthy(entry.key:find(":o:", 1, true), entry.key)
    queue.clear()
    view.paint()
  end)

  it("is still bound to the after pane for scrolling", function()
    local V = current()
    focus(V.win)
    vim.api.nvim_win_call(V.win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
    end)
    vim.api.nvim_win_call(V.before_win, function()
      vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
    end)
    assert.same({ 1, 1 }, { row_in(V.win), row_in(V.before_win) })

    -- Driven with `normal!`: the binding follows cursor motions and not the API, so an
    -- assertion made through `nvim_win_set_cursor` passes whether or not it exists.
    vim.api.nvim_win_call(V.win, function()
      vim.cmd("normal! 12j")
    end)
    assert.same(13, row_in(V.win))
    assert.same(13, row_in(V.before_win))
  end)
end)

-- The unified layout is the one every existing reviewer has, and a toggle back to it must
-- leave a window indistinguishable from one that was never split.
describe("coming back to one pane", function()
  it("lifts the binding from the window that is left", function()
    in_layout("split")
    in_layout("unified")
    local V = current()
    assert.is_false(vim.wo[V.win].scrollbind)
    assert.is_false(vim.wo[V.win].cursorbind)
  end)

  it("leaves the global scroll-options setting alone throughout", function()
    assert.same(vim.go.scrollopt, vim.api.nvim_get_option_value("scrollopt", { scope = "global" }))
    in_layout("split")
    local during = vim.go.scrollopt
    in_layout("unified")
    assert.same(during, vim.go.scrollopt)
  end)

  it("gives the whole width back to the diff", function()
    local V = current()
    assert.same(vim.o.columns - vim.api.nvim_win_get_width(V.panel_win) - 1, vim.api.nvim_win_get_width(V.win))
  end)
end)
