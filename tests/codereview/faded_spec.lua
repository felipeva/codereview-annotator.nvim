-- Every file except the one the cursor is in is **faded**.
--
-- Asserted at the altitude a reviewer's diff really holds it: the marks the review draws in
-- the plugin's namespace, read off the buffer with the helper `render_spec`, `spans_spec` and
-- `bounded_spec` already use, and filtered by the group each mark carries. Movement is the
-- cursor and the `CursorMoved` autocommand a keystroke raises, never a call to the function
-- that emits.
--
-- Only this plugin's own groups are judged bright or faded. A treesitter capture the active
-- theme gives no colour of its own is emitted as itself by design -- `@spell` is one in this
-- fixture -- and counting that as "left bright" would be counting the nil contract as a
-- defect. What the replay does under the fade is asserted on the captures that do have a
-- colour, by name.
--
-- Two blocks exist for traps rather than for behaviour. One opens a review with
-- `syntax = false`, which fails for a fade that took its row spans from the replay's row map:
-- that map is built only when highlighting is on. One scrolls into rows no paint had reached
-- at the moment of the crossing, which fails for a fade that renamed the rows it could see
-- once instead of renaming a row as it is emitted.
--
-- Lower still, the cells the reviewer's screen really holds. Those are in `faded_child.lua`,
-- one process per reading, because `nvim__inspect_cell` tells the truth only on the first
-- call a process makes -- see the header there. A group name cannot tell a faded row from a
-- bright one, so nothing above this line can.
local h = require("tests.helpers")

local fade = require("codereview.fade")
local hl = require("codereview.hl")
local syntax = require("codereview.syntax")
local view = require("codereview.view")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

-- Colours with even channels, so a blend a quarter of the way to a black background has no
-- rounding in it and the numbers below can be read at a glance.
vim.o.termguicolors = true
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x004400 })
-- A group with a name and no colour at all: the one thing the blend cannot compute, and the
-- case it must hand back nothing for. Defined before any review has blended anything.
vim.api.nvim_set_hl(0, "FadedSpecColourless", {})

---What the name of every blended group in the fade's family starts with.
local FADED = "CodeReviewFaded."

---@param group string
---@return boolean
local function is_faded(group)
  return group:sub(1, #FADED) == FADED
end

---Every highlight group the diff drew on rows `first`..`last` of `buf`, as a set.
---@param buf integer
---@param first integer 1-indexed
---@param last integer 1-indexed, inclusive
---@return table<string, boolean>
local function drawn(buf, first, last)
  local out = {}
  last = math.min(last, vim.api.nvim_buf_line_count(buf))
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, h.NS, { first - 1, 0 }, { last - 1, -1 }, { details = true })) do
    local group = m[4].hl_group or m[4].line_hl_group
    if group then
      out[group] = true
    end
  end
  return out
end

---Those of `groups` that this plugin defines, split by whether the fade renamed them.
---@param groups table<string, boolean>
---@return string[] faded, string[] bright
local function own(groups)
  local faded, bright = {}, {}
  for group in pairs(groups) do
    if is_faded(group) then
      faded[#faded + 1] = group
    elseif group:sub(1, #"CodeReview") == "CodeReview" then
      bright[#bright + 1] = group
    end
  end
  table.sort(faded)
  table.sort(bright)
  return faded, bright
end

---The rows one file's body occupies, taken from the render and from nothing else.
---
---Written out here rather than asked of `fade.lua`: the span is the trap, and a case that
---asked the code under test where a file starts would agree with it whatever it answered.
---@param V CRView
---@param fi integer
---@return integer first, integer last
local function body(V, fi)
  local next_header = V.render.file_rows[fi + 1]
  return V.render.file_rows[fi] + 1, (next_header and next_header - 1) or #V.render.lines
end

---Every plugin group on one file's body, split the same way.
---@param V CRView
---@param fi integer
---@param buf integer|nil Defaults to the after pane
---@return string[] faded, string[] bright
local function file_groups(V, fi, buf)
  return own(drawn(buf or V.buf, body(V, fi)))
end

---Put the cursor on `row` and raise the event a reviewer's keystroke would.
---
---Neither `nvim_win_set_cursor` nor a `normal!` motion raises `CursorMoved` under a headless
---Neovim -- see tests/README.md -- so a case that only moved the cursor would be asserting
---against a crossing that never happened.
---@param V CRView
---@param row integer
local function move_to(V, row)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
end

--- What a review draws when it opens ----------------------------------------------

require("codereview").setup({
  layout = "unified",
  syntax = true,
  muted = { enabled = true, strength = 0.5 },
  faded = { enabled = true, strength = 0.25 },
})
view.open("branch")

describe("a review opened with the cursor in its first file", function()
  local V = assert(view.current(), "no review view open")

  it("is on by default", function()
    assert.is_true(require("codereview.config").defaults.faded.enabled)
  end)

  it("has more than one file to tell apart", function()
    assert.is_true(#V.files > 1, ("%d file(s)"):format(#V.files))
    assert.same(1, view.current_file())
  end)

  it("draws the file the cursor is in at full strength", function()
    local faded, bright = file_groups(V, 1)
    assert.same({}, faded)
    assert.is_true(#bright > 0, "the first file's body carries no marks at all")
  end)

  it("fades the body of every other file", function()
    for fi = 2, #V.files do
      local faded, bright = file_groups(V, fi)
      assert.same({}, bright, ("file %d, %s"):format(fi, V.files[fi].path))
      assert.is_true(#faded > 0, ("file %d, %s, carries no marks at all"):format(fi, V.files[fi].path))
    end
  end)

  -- The header row is the one row that names the file, and the fade exists to help a reviewer
  -- find a place rather than to hide the map.
  it("keeps every file's header row bright, with its path, its stat and its note count", function()
    for fi = 1, #V.files do
      local row = V.render.file_rows[fi]
      local faded, bright = own(drawn(V.buf, row, row))
      assert.same({}, faded, ("file %d, %s"):format(fi, V.files[fi].path))
      assert.is_true(vim.tbl_contains(bright, "CodeReviewFileHeader"), table.concat(bright, ", "))
    end
    -- The stat and the note count ride on the after pane's header rows, and this fixture has
    -- both. Read across the file headers rather than one, since not every file carries them.
    local seen = {}
    for fi = 1, #V.files do
      local row = V.render.file_rows[fi]
      for group in pairs(drawn(V.buf, row, row)) do
        seen[group] = true
      end
    end
    assert.is_true(seen.CodeReviewStatAdd, "no file header carries its stat")
  end)

  it("fades a faded file's hunk headers with its body", function()
    local main = assert(h.file_index(V, "src/main.lua"))
    local groups = drawn(V.buf, body(V, main))
    assert.is_true(groups[FADED .. "CodeReviewHunkHeader"], "the hunk header is not faded")
    assert.is_nil(groups.CodeReviewHunkHeader)
  end)

  -- The replay sits at a higher priority band than the diff's own marks, and it is what
  -- carries the structure of the code. A fade that reached the line background and not the
  -- tokens would leave a faded file's code as loud as the file being read.
  it("fades the tokens the treesitter replay painted, and no others", function()
    local main = assert(h.file_index(V, "src/main.lua"))
    assert.is_true(drawn(V.buf, body(V, main))[FADED .. "@keyword"], "the replay's tokens are not faded")
    assert.is_true(drawn(V.buf, body(V, 1))["@keyword"], "the file being read has no replayed token")
    assert.is_nil(drawn(V.buf, body(V, 1))[FADED .. "@keyword"])
  end)
end)

--- The crossing ------------------------------------------------------------------

describe("the cursor crossing into another file", function()
  local V = assert(view.current(), "no review view open")
  local main = assert(h.file_index(V, "src/main.lua"))

  move_to(V, assert(h.line_row(V, "src/main.lua")))

  it("really crossed", function()
    assert.same(main, view.current_file())
    assert.same(main, V.current_file)
  end)

  it("clears the fade from the file entered", function()
    local faded, bright = file_groups(V, main)
    assert.same({}, faded)
    assert.is_true(#bright > 0, "the file entered carries no marks at all")
  end)

  it("fades the file left", function()
    local faded, bright = file_groups(V, 1)
    assert.same({}, bright)
    assert.is_true(#faded > 0, "the file left carries no marks at all")
  end)

  it("leaves every file it did not cross faded", function()
    for fi = 2, #V.files do
      if fi ~= main then
        local faded, bright = file_groups(V, fi)
        assert.same({}, bright, ("file %d, %s"):format(fi, V.files[fi].path))
        assert.is_true(#faded > 0, ("file %d, %s"):format(fi, V.files[fi].path))
      end
    end
  end)
end)

describe("the cursor moving from one hunk to the next inside one file", function()
  local V = assert(view.current(), "no review view open")

  ---Every mark the diff carries, id and all: what is drawn, and what emitted it.
  ---@return table[]
  local function marks()
    return vim.api.nvim_buf_get_extmarks(V.buf, h.NS, 0, -1, { details = true })
  end

  local was = marks()
  local from = vim.api.nvim_win_get_cursor(V.win)[1]
  local routes = assert(h.file_index(V, "src/routes.lua"))
  -- Two rows inside one file, which is what makes this a claim about the fade rather than
  -- about a cursor that never moved. The window is taller than this fixture, so neither row
  -- scrolls it and no new band comes due.
  local first, last = body(V, routes)
  move_to(V, first)
  local inside = marks()
  move_to(V, last)

  it("moved the cursor, twice, without leaving the file", function()
    assert.is_true(first ~= from and last ~= first, ("%d, %d, %d"):format(from, first, last))
    assert.same(routes, view.current_file())
  end)

  it("changes nothing that is drawn", function()
    assert.same(inside, marks())
  end)

  -- The extmark ids are what says nothing was emitted again: a fade that re-emitted on every
  -- `CursorMoved` would draw the same groups on the same rows under new ids.
  it("emits nothing again to do it", function()
    local ids = {}
    for _, m in ipairs(inside) do
      ids[#ids + 1] = m[1]
    end
    local now = {}
    for _, m in ipairs(marks()) do
      now[#now + 1] = m[1]
    end
    assert.same(ids, now)
  end)

  it("did emit again for the crossing that got here", function()
    local ids = {}
    for _, m in ipairs(was) do
      ids[m[1]] = true
    end
    local fresh = 0
    for _, m in ipairs(inside) do
      fresh = fresh + (ids[m[1]] and 0 or 1)
    end
    assert.is_true(fresh > 0, "the crossing into this file emitted nothing")
  end)
end)

--- Both panes --------------------------------------------------------------------

describe("the split layout", function()
  local V = assert(view.current(), "no review view open")
  view.toggle_layout()
  local main = assert(h.file_index(V, "src/main.lua"))
  move_to(V, assert(h.line_row(V, "src/main.lua")))

  it("holds two panes of the same height, and the same header rows", function()
    assert.is_not_nil(V.before_render)
    assert.same(#V.render.lines, #V.before_render.lines)
    assert.same(V.render.file_rows, V.before_render.file_rows)
  end)

  it("fades the same files in both panes, so the two images stay comparable", function()
    for fi = 1, #V.files do
      local after_faded, after_bright = file_groups(V, fi, V.buf)
      local before_faded, before_bright = file_groups(V, fi, V.before_buf)
      assert.same({}, fi == main and after_faded or after_bright, ("after pane, file %d"):format(fi))
      assert.same({}, fi == main and before_faded or before_bright, ("before pane, file %d"):format(fi))
    end
  end)

  -- The guard the case above is worth little without. The before pane draws filler wherever a
  -- file exists on the after side only, so "nothing bright in it" holds for a pane that drew
  -- nothing at all -- and this fixture has three such files. `src/routes.lua` is carried by
  -- both images, and it is not the file being read.
  it("really drew the before pane that was read", function()
    local routes = assert(h.file_index(V, "src/routes.lua"))
    assert.is_true(routes ~= main, "the guard is reading the file the cursor is in")
    local faded, bright = file_groups(V, routes, V.before_buf)
    assert.is_true(#faded > 0, "the before pane drew nothing for a file it holds")
    assert.same({}, bright)
  end)

  view.toggle_layout()

  it("comes back to one pane with the fade where it was", function()
    assert.is_nil(V.before_win)
    local faded, bright = file_groups(V, main)
    assert.same({}, faded)
    assert.is_true(#bright > 0, "the file being read carries no marks at all")
  end)
end)

--- A repaint that moves the rows --------------------------------------------------

describe("a file collapsed above the one being read", function()
  local V = assert(view.current(), "no review view open")
  local routes = assert(h.file_index(V, "src/routes.lua"))
  local before_collapse = V.render.file_rows[routes]

  -- Collapse `src/main.lua`, which is above it, and then read `src/routes.lua` at the row it
  -- has now. Every row below the collapse has moved, so a fade left over from the render it
  -- was emitted from would now be sitting on somebody else's code.
  move_to(V, assert(h.line_row(V, "src/main.lua")))
  view.toggle_expand()
  move_to(V, V.render.file_rows[routes] + 1)

  it("moved the rows below it", function()
    assert.is_true(V.render.file_rows[routes] < before_collapse, "nothing moved, so nothing is being measured")
    assert.same(routes, view.current_file())
  end)

  it("draws the file being read at full strength at its new rows", function()
    local faded, bright = file_groups(V, routes)
    assert.same({}, faded)
    assert.is_true(#bright > 0, "the file being read carries no marks at all")
  end)

  it("leaves the collapsed file needing no rule of its own", function()
    local main = assert(h.file_index(V, "src/main.lua"))
    local _, bright = file_groups(V, main)
    assert.same({}, bright)
  end)

  view.toggle_expand()
end)

--- A review with nothing in it -----------------------------------------------------

describe("a review with no files", function()
  local V = assert(view.current(), "no review view open")
  -- A revspec whose two ends are the same commit: a review that opened on a real scope and
  -- has nothing in it, which is the only way to reach an empty one -- `open` refuses.
  view.set_scope("HEAD..HEAD")

  it("really has no files, and no file under the cursor", function()
    assert.same(0, #V.files)
    assert.is_nil(view.current_file())
  end)

  it("fades nothing", function()
    local faded = own(drawn(V.buf, 1, math.max(1, #V.render.lines)))
    assert.same({}, faded)
  end)

  view.set_scope("branch")
end)

--- The colours behind it ------------------------------------------------------------

describe("the two families of blended groups", function()
  it("gives the fade a strength of its own", function()
    local faded = assert(hl.blended("faded", "CodeReviewAdd"), "the fade has no blend of a changed line")
    local muted = assert(hl.blended("muted", "CodeReviewAdd"), "the window rule has no blend of a changed line")
    local theme = vim.api.nvim_get_hl(0, { name = "CodeReviewAdd", link = false }).bg
    local one = vim.api.nvim_get_hl(0, { name = faded, link = false }).bg
    local other = vim.api.nvim_get_hl(0, { name = muted, link = false }).bg
    assert.is_true(one ~= other, ("both families blend a changed line to %s"):format(tostring(one)))
    -- Both pulled from the same colour toward the same background, and the fade less far:
    -- it covers every file but one, where the window rule covers a pane.
    assert.is_true(one < theme and other < one, ("theme %s, faded %s, muted %s"):format(theme, one, other))
  end)

  -- Nobody is to "fix" this by giving the fade a palette of its own. A group with no blend
  -- emitted as itself is what keeps an unrecognised theme merely less faded instead of
  -- wrongly coloured, and there is no higher place to say it: the render carries no mark in
  -- a colourless group, so no reading of the buffer can reach this.
  it("hands back nothing for a group the theme gives no colour", function()
    assert.is_nil(hl.blended("faded", "FadedSpecColourless"))
    assert.same("FadedSpecColourless", fade.group("FadedSpecColourless"))
  end)

  it("hands back a blend for a group it does colour, beside it", function()
    assert.same(FADED .. "CodeReviewAdd", fade.group("CodeReviewAdd"))
  end)
end)

--- With highlighting off ------------------------------------------------------------

-- The trap case. The replay builds a row map that holds a span per file, and it is built
-- only when highlighting is on -- so a fade taking its spans from there does nothing at all
-- here, and every case above still passes.
describe("a review opened with syntax off", function()
  require("codereview").setup({ layout = "unified", syntax = false, faded = { enabled = true, strength = 0.25 } })
  view.close()
  view.open("branch")
  local V = assert(view.current(), "no review view open")
  local main = assert(h.file_index(V, "src/main.lua"))
  move_to(V, assert(h.line_row(V, "src/main.lua")))

  it("really has no highlighting, and no row map behind it", function()
    assert.same({}, h.syntax_marks(V))
    assert.is_nil(V.syntax_rows)
  end)

  it("fades every file but the one the cursor is in anyway", function()
    local faded, bright = file_groups(V, main)
    assert.same({}, faded)
    assert.is_true(#bright > 0, "the file being read carries no marks at all")
    for fi = 1, #V.files do
      if fi ~= main then
        local other_faded, other_bright = file_groups(V, fi)
        assert.same({}, other_bright, ("file %d, %s"):format(fi, V.files[fi].path))
        assert.is_true(#other_faded > 0, ("file %d, %s"):format(fi, V.files[fi].path))
      end
    end
  end)

  it("still fades the file left when the cursor crosses", function()
    move_to(V, assert(h.line_row(V, "src/routes.lua")))
    local _, bright = file_groups(V, main)
    assert.same({}, bright)
  end)
end)

--- With the switch off ---------------------------------------------------------------

describe("a review opened with the fade off", function()
  require("codereview").setup({ layout = "unified", syntax = true, faded = { enabled = false } })
  view.close()
  view.open("branch")
  local V = assert(view.current(), "no review view open")

  ---Every group the render gave a row, as `row:col:group`, sorted.
  ---@param rendered CRRender
  ---@return string[]
  local function asked_for(rendered)
    local out = {}
    for _, m in ipairs(rendered.marks) do
      local group = m.opts.hl_group or m.opts.line_hl_group
      if group then
        out[#out + 1] = ("%d:%d:%s"):format(m.row, m.col, group)
      end
    end
    table.sort(out)
    return out
  end

  ---Every group the buffer really carries, in the same shape. The replay's marks are left
  ---out: they are not the render's, and they are not bounded the same way.
  ---@return string[]
  local function drew()
    local out = {}
    for _, m in ipairs(h.extmarks(V)) do
      local group = m[4].hl_group or m[4].line_hl_group
      if group and m[4].priority ~= require("codereview.render").PRIORITY.syntax then
        out[#out + 1] = ("%d:%d:%s"):format(m[2], m[3], group)
      end
    end
    table.sort(out)
    return out
  end

  move_to(V, assert(h.line_row(V, "src/main.lua")))

  it("crossed into another file, which would have faded the first", function()
    assert.same(h.file_index(V, "src/main.lua"), view.current_file())
  end)

  -- Not "no faded group appears", which holds for a fade that ran and found nothing to
  -- rename. Every mark the render asked for, drawn in the group it asked for.
  it("draws the diff exactly as the render asked, mark for mark", function()
    local asked = asked_for(V.render)
    assert.is_true(#asked > 0, "the render asked for nothing")
    assert.same(asked, drew())
  end)

  it("computes no blend of its own either", function()
    -- Named for this block alone, so nothing earlier can have blended it already.
    vim.api.nvim_set_hl(0, "FadedSpecOffGroup", { fg = 0x00ee00 })
    assert.is_false(fade.enabled())
    assert.same({}, vim.api.nvim_get_hl(0, { name = FADED .. "FadedSpecOffGroup" }))
  end)
end)

--- Rows no paint had reached ----------------------------------------------------------

-- The second trap case, and the one fixture in this file taller than a window and the margin
-- around it: emission is bounded by the viewport, so a fade that renamed the rows it could
-- see at the moment of the crossing leaves everything scrolled into afterwards bright.
describe("scrolling into rows nothing had painted when the cursor crossed", function()
  view.close()
  h.cd_fixture("mkbig", "6", "200")
  require("codereview").setup({ layout = "unified", syntax = true, faded = { enabled = true, strength = 0.25 } })
  view.open("branch")
  local V = assert(view.current(), "no review view open")
  local BAND = syntax.VIEWPORT_MARGIN

  ---Put the window on `row` as a reviewer's scroll would, and raise the event with it.
  ---@param row integer
  local function scroll_to(row)
    vim.api.nvim_win_set_cursor(V.win, { row, 0 })
    vim.api.nvim_win_call(V.win, function()
      vim.cmd("normal! zz")
    end)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
  end

  local first, last = body(V, 3)

  it("renders more rows than one paint can reach", function()
    local _, hi = syntax.viewport(V)
    assert.is_true(#V.render.lines > hi * 2, ("%d rows against a reach of %d"):format(#V.render.lines, hi))
    assert.is_true(#V.files >= 4, ("%d files"):format(#V.files))
  end)

  -- Into the second file, and no further. What is asserted afterwards is about the third,
  -- which is far below anything this crossing can have painted.
  scroll_to(V.render.file_rows[2] + 1)

  it("crossed into the second file", function()
    assert.same(2, view.current_file())
  end)

  it("left the third file's rows with nothing drawn on them at all", function()
    assert.is_true(first > (select(2, syntax.viewport(V))) + BAND, ("row %d is within reach"):format(first))
    assert.same({}, drawn(V.buf, first, last))
  end)

  -- Down to the last row of the second file, so the margin below the window reaches into the
  -- third without the cursor ever leaving the second. No crossing happens here: what emits
  -- those rows is the paint that follows the scroll.
  scroll_to(select(2, body(V, 2)))

  it("scrolled without crossing out of the file being read", function()
    assert.same(2, view.current_file())
  end)

  it("emits the rows it reached", function()
    assert.is_true(next(drawn(V.buf, first, last)) ~= nil, "the scroll emitted nothing onto the third file")
  end)

  it("brings them in faded", function()
    local faded, bright = own(drawn(V.buf, first, last))
    assert.same({}, bright)
    assert.is_true(#faded > 0, "the third file's rows carry no marks of the plugin's at all")
  end)
end)

--- A colorscheme the review was not blended against ------------------------------------

-- Last of the in-process blocks, because it replaces every colour the ones above read.
describe("changing colorscheme", function()
  local function bg(group)
    return vim.api.nvim_get_hl(0, { name = group, link = false }).bg
  end

  local before = bg(FADED .. "CodeReviewAdd")
  local was = bg("CodeReviewAdd")

  vim.cmd("colorscheme blue")

  local now = bg("CodeReviewAdd")
  local backdrop = bg("Normal") or 0x000000
  local after = bg(FADED .. "CodeReviewAdd")

  -- Without this the case below passes on a theme that happens to paint a changed line the
  -- same colour the last one did, which would prove nothing about recomputing anything.
  it("is a change the theme really made", function()
    assert.is_true(was ~= now, ("both themes give a changed line %s"):format(tostring(now)))
  end)

  it("recomputes the faded colour against the theme that is active now", function()
    assert.is_true(before ~= after, "the faded colour is the one the old theme was blended into")
    assert.is_true(after ~= now, "the faded colour is the new theme's, unfaded")
    local theme, back, faded = now, backdrop, after
    for _, place in ipairs({ 65536, 256, 1 }) do
      local one = math.floor(theme / place) % 256
      local two = math.floor(back / place) % 256
      local mine = math.floor(faded / place) % 256
      local lo, hi = math.min(one, two), math.max(one, two)
      assert.is_true(
        mine >= lo and mine <= hi,
        ("%d is not between the theme's %d and the background's %d"):format(mine, one, two)
      )
    end
  end)
end)

--- The cells a reviewer's screen holds ---------------------------------------------------

-- One child per reading, because `nvim__inspect_cell` is only honest on the first call a
-- process makes. Each opens the same review over this spec's first fixture, in the unified
-- layout at 80x24, and reads the first token the treesitter replay painted on an *added* line
-- of a file the cursor is not in -- one cell carrying a changed line's background under a
-- foreground from a higher priority band, which is the only shape that can tell a fade that
-- reaches the diff from one that reaches nothing but the empty space.
describe("the cell under a reviewer's eye", function()
  ---@param env table<string, string>
  ---@return string
  local function child(env)
    local run = vim
      .system({
        vim.v.progpath,
        "--clean",
        "-l",
        vim.fs.joinpath(h.root, "tests", "codereview", "faded_child.lua"),
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
    return vim.trim(out)
  end

  local elsewhere = child({})
  local inside = child({ CURSOR = "in" })
  local off = child({ FADED = "0" })

  it("pulls both the changed line's background and the replay's foreground halfway to the background", function()
    assert.same("cell l fg=770000 bg=002200", (elsewhere:gsub(" at %d+,%d+$", "")))
  end)

  it("gives the same cell back at full strength once the cursor crosses into its file", function()
    assert.same("cell l fg=ee0000 bg=004400", (inside:gsub(" at %d+,%d+$", "")))
  end)

  -- What gives the first reading its teeth: without this it is only known to differ from a
  -- bright cell, not to be a blend of one.
  it("paints exactly what it painted before the fade existed when the switch is off", function()
    assert.same("cell l fg=ee0000 bg=004400", (off:gsub(" at %d+,%d+$", "")))
  end)
end)

--- A configuration mistake ----------------------------------------------------------------

-- Last, because it deliberately leaves a bad value in the options: the switches beside this
-- one are bare booleans, so `faded = false` is the mistake worth catching loudly.
describe("the switch written the way the coarse ones are", function()
  local ok, err = pcall(require("codereview").setup, { faded = false })

  it("fails at setup rather than inside the emission later", function()
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("faded = { enabled = false }", 1, true), tostring(err))
  end)

  it("rejects a strength that is not a fraction of the way to the background", function()
    local bad, why = pcall(require("codereview").setup, { faded = { strength = 4 } })
    assert.is_false(bad)
    assert.is_truthy(tostring(why):find("faded.strength", 1, true), tostring(why))
  end)

  require("codereview").setup({ layout = "unified", syntax = true })
end)
