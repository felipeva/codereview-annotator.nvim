-- One painted cell of a file row's `+N -M` **stat** in the file tree, read in a process of
-- its own.
--
-- The claim these answer: the stat's two colours reach a reviewer's screen on the rows the
-- stat is for, and they do not reach one on a row marked **reviewed** -- which is why that
-- row is given no colour range at all. A group named by an extmark is not a colour on a
-- screen. Two line-wide groups land on tree rows -- `CodeReviewFileReviewed` over a reviewed
-- file's whole row, and `CodeReviewPanelSel` over the row the diff cursor is in -- and a
-- line-wide group replaces every attribute it sets on the marks beneath it, at every
-- priority.
--
-- Four readings, one per process, chosen so that each answers one thing:
--
--   added     the `+` of the stat on an ordinary row, under no line-wide group at all
--   removed   the `-` of the same stat -- a second colour on the screen, and not merely a
--             second name in a table
--   current   the `+` again, on the row the diff cursor is in. `CursorLine` carries a
--             background and no foreground here, as the shipped colourscheme's does, and the
--             cell reports both halves at once: the background says the line-wide group
--             really painted this row, so the reading cannot pass on a row that never had one
--   reviewed  the `+` on a row marked reviewed. `CodeReviewFileReviewed` resolves to
--             `Comment`, which carries a *foreground*, so the stat's own colour cannot draw
--             here whatever priority it asks for. This is the reading the tree's decision
--             rests on: the row keeps the two numbers and is given no range, because a range
--             emitted here would cost a paint and reach no cell
--
-- The colours are set here rather than taken from whatever theme a runner has, so each
-- reading is an absolute number.
--
-- Deliberately one cell per process. `nvim__inspect_cell` reports a cell's real attributes
-- only on the **first** call a process makes; every call after it returns attributes
-- belonging to something else, which `muted_child.lua` measured rather than assumed.
--
-- The screen is 80x24 because that is the grid a headless Neovim keeps whatever `columns`
-- and `lines` are set to: the tree is 34 columns at the left of it, so every cell read here
-- is well inside what an assertion can reach.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- panel_spec with FIXTURE and MODE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.termguicolors = true
vim.o.columns = 80
vim.o.lines = 24

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
local mode = assert(vim.env.MODE, "MODE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- Two files of the nested fixture: the one every reading but `reviewed` is taken on, and a
-- file the diff cursor is parked on so that the row under test carries no line-wide group
-- except where a reading asks for one.
local FILE = "apps/api/src/main.lua"
local REVIEWED = "README.md"
local PARK = "apps/api/src/routes/users.lua"

vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
-- What `CodeReviewStatAdd` and `CodeReviewStatDel` resolve to, and what both
-- `CodeReviewNoteCount` and `CodeReviewFileReviewed` resolve to.
vim.api.nvim_set_hl(0, "Added", { fg = 0x00ee00 })
vim.api.nvim_set_hl(0, "Removed", { fg = 0x00eeee })
vim.api.nvim_set_hl(0, "Comment", { fg = 0xee0000 })
-- What `CodeReviewPanelSel` resolves to: a background and no foreground, which is what the
-- shipped colourscheme gives it.
vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x0000ee })

require("codereview").setup({
  layout = "unified",
  syntax = false,
  compose = function(_, on_accept, _)
    on_accept(nil, "n")
  end,
})

local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "no review view opened")
assert(V.panel_win, "no file tree")

---The lowest diff row anchored to a line of `path`. Lowest rather than whichever `pairs`
---reaches first, so the cell a reading lands on does not move between runs.
---@param path string
---@return integer
local function line_row(path)
  local best
  for row, a in pairs(V.render.anchors) do
    if a.kind == "line" and V.files[a.file].path == path and (not best or row < best) then
      best = row
    end
  end
  return assert(best, path .. " has no diff line")
end

if mode == "reviewed" then
  vim.api.nvim_win_set_cursor(V.win, { line_row(REVIEWED), 0 })
  view.toggle_reviewed()
end

-- Where the diff cursor ends up, which is what decides whether the row under test carries a
-- line-wide group. Announced through `CursorMoved`, because the crossing the tree follows is
-- the diff's own.
vim.api.nvim_win_set_cursor(V.win, { line_row(mode == "current" and FILE or PARK), 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })

local NS_PANEL = vim.api.nvim_create_namespace("codereview_panel")

---@param path string
---@return integer row 1-indexed
local function tree_row(path)
  local index
  for i, f in ipairs(V.files) do
    if f.path == path then
      index = i
    end
  end
  return assert(V.panel_render.file_row[assert(index, path .. " is not in this review")])
end

local path = mode == "reviewed" and REVIEWED or FILE
local row = tree_row(path)
local text = vim.api.nvim_buf_get_lines(V.panel_buf, row - 1, row, false)[1]

---The byte a count of the stat starts at, read off the range the tree really emitted for it.
---
---Read before the cell rather than at an offset this file expects the count at: a reading
---taken where the case already looked says nothing about where the surface put it, and a row
---that emitted no stat at all would pass it.
---@param group string
---@return integer col 0-indexed byte
local function mark_at(group)
  for _, m in
    ipairs(vim.api.nvim_buf_get_extmarks(V.panel_buf, NS_PANEL, { row - 1, 0 }, { row - 1, -1 }, { details = true }))
  do
    if m[4].hl_group == group and m[4].end_col then
      return m[3]
    end
  end
  error(("no range on %s's tree row in %s: %q"):format(path, group, text))
end

local col
if mode == "removed" then
  col = mark_at("CodeReviewStatDel")
elseif mode == "reviewed" then
  -- No range to read it off, which is the whole of what this reading is about, so the count
  -- is found in the row the tree really drew. A row with no stat on it errors here.
  local at = assert(text:find("%+%d+ %-%d+%s*$"), ("no stat on %s's reviewed tree row: %q"):format(path, text))
  col = at - 1
else
  col = mark_at("CodeReviewStatAdd")
end

-- The two readings that must answer for no line-wide group at all: the tree follows the diff
-- cursor, so the row it lights is the parked file's and never this one.
if mode == "added" or mode == "removed" then
  assert(vim.api.nvim_win_get_cursor(V.panel_win)[1] ~= row, "the tree's cursor is on the row under test")
end

vim.cmd("redraw!")
local pos = vim.fn.screenpos(V.panel_win, row, col + 1)
assert(pos.row > 0 and pos.col > 0, "the row under test is off screen")
local cell = vim.api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)
local attrs = cell[2] or {}

---@param value integer|nil
---@return string
local function hex(value)
  return value and ("%06x"):format(value) or "none"
end

-- `nvim -l` sends print to stderr, not stdout, so panel_spec reads both.
print(("cell %q fg=%s bg=%s at %d,%d"):format(cell[1], hex(attrs.foreground), hex(attrs.background), pos.row, pos.col))
vim.cmd("qa!")
