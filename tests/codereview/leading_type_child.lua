-- One painted cell of a file's **state** mark in the file tree, read in a process of its own.
--
-- The claim: the colour of a file's **leading type** reaches the screen. That cannot be made
-- by a group name. Two line-wide groups already land on the rows a reviewer looks at hardest
-- -- `CodeReviewFileReviewed` over a reviewed file's whole row, and `CodeReviewPanelSel` over
-- the row the diff cursor is in -- and a line-wide group replaces every attribute it sets on
-- the marks beneath it. So a foreground can be named by an extmark on every paint and be
-- invisible on exactly the row that matters, and no assertion about that extmark can see it.
--
-- Four readings, one per process, chosen so that each answers one thing:
--
--   bug      the mark on a file holding a bug, on no line-wide group at all
--   nitpick  the mark on a file holding only a nitpick -- a different colour on the screen,
--            and not merely a different name in a table
--   current  the same cell as `bug`, on the row the diff cursor is in. `CursorLine` carries a
--            background and no foreground here, as the shipped colourscheme's does, and the
--            cell reports both halves at once: the background says the line-wide group really
--            painted this row, so the reading cannot pass on a row that never had one.
--   flatten  the same row again with a foreground added to `CursorLine`. This is the control
--            and it is the point: it says which row loses the colour and why. A line-wide
--            foreground wins over a range's at every priority -- measured -- so a
--            colourscheme that gives `CursorLine` a foreground takes the leading type's
--            colour off the row the reviewer is on, and nothing in the plugin can answer it.
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

-- Three files of the nested fixture: one holding a bug, one holding only a nitpick, and one
-- holding nothing, which is where the diff cursor is parked for the two readings that must
-- carry no line-wide group at all.
local BUG_FILE = "apps/api/src/main.lua"
local NIT_FILE = "docs/guide.md"
local PARK = "apps/api/src/routes/users.lua"

vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "CodeReviewBug", { fg = 0x00ee00 })
vim.api.nvim_set_hl(0, "CodeReviewNitpick", { fg = 0xee0000 })
-- What `CodeReviewPanelSel` resolves to. A background and no foreground, which is what the
-- shipped colourscheme gives it -- except under `flatten`, which is the whole control.
if mode == "flatten" then
  vim.api.nvim_set_hl(0, "CursorLine", { fg = 0xeeee00, bg = 0x0000ee })
else
  vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x0000ee })
end

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

---@param path string
---@param type_name string
local function annotate(path, type_name)
  vim.api.nvim_win_set_cursor(V.win, { line_row(path), 0 })
  require("codereview.annotate").annotate(type_name)
end

annotate(BUG_FILE, "bug")
annotate(NIT_FILE, "nitpick")

-- Where the diff cursor ends up, which is what decides whether the row under test carries a
-- line-wide group. Announced through `CursorMoved`, because the crossing the tree follows is
-- the diff's own.
local look_at = (mode == "current" or mode == "flatten") and BUG_FILE or PARK
vim.api.nvim_win_set_cursor(V.win, { line_row(look_at), 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })

local NS_PANEL = vim.api.nvim_create_namespace("codereview_panel")

---The byte the state mark of `path` starts at in the tree, read off the marks the tree really
---emitted in that type's group.
---
---Read before the cell rather than at an offset this file expects the mark at: a reading
---taken where the case already looked says nothing about where the surface put it, and a tree
---that emitted no range at all would pass it.
---@param path string
---@param group string
---@return integer row 1-indexed, integer col 0-indexed byte
local function mark_at(path, group)
  local index
  for i, f in ipairs(V.files) do
    if f.path == path then
      index = i
    end
  end
  local row = assert(V.panel_render.file_row[assert(index, path .. " is not in this review")])
  for _, m in
    ipairs(vim.api.nvim_buf_get_extmarks(V.panel_buf, NS_PANEL, { row - 1, 0 }, { row - 1, -1 }, { details = true }))
  do
    if m[4].hl_group == group and m[4].end_col then
      return row, m[3]
    end
  end
  error(("no range on %s's tree row in %s"):format(path, group))
end

local path = mode == "nitpick" and NIT_FILE or BUG_FILE
local group = mode == "nitpick" and "CodeReviewNitpick" or "CodeReviewBug"
local row, col = mark_at(path, group)

-- The two readings that must answer for no line-wide group at all: the tree follows the diff
-- cursor, so the row it lights is the parked file's and never this one.
if mode == "bug" or mode == "nitpick" then
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
