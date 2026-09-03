-- One painted cell of a host's file glyph, read in a process of its own.
--
-- The claim: a glyph is not the one bright thing left in a **pane** that has lost focus. That
-- cannot be made by a group name. A **muted** window draws through a highlight namespace, and
-- an entry in it is a *link* -- a link reaching a group with no colour draws nothing at all,
-- and a group with no entry falls back to its global definition and stays bright. Only a cell
-- says which of those a reviewer is looking at.
--
-- The cell is the glyph's own, on a file's header row, so one reading carries both halves of
-- the question: the glyph's foreground from the group the adapter answered with, over the
-- **frame**'s band underneath it. A glyph outside the muted set reads at full brightness on a
-- band that receded without it, which is exactly the defect.
--
-- The colours are set here rather than taken from whatever theme a runner has, so each
-- reading is an absolute number. `Normal` black under white is what the band is computed
-- from: a background pulled 20% toward that foreground is `333333` in every channel with no
-- rounding in it, and halfway to the same backdrop it is `1a1a1a`. The adapter's group is
-- `00ee00`, which comes out `007700`.
--
-- Deliberately one cell per process. `nvim__inspect_cell` reports a cell's real attributes
-- only on the **first** call a process makes; every call after it returns attributes belonging
-- to something else, which `muted_child.lua` measured rather than assumed.
--
-- The screen is 80x24 because that is the grid a headless Neovim keeps whatever `columns` and
-- `lines` are set to: a window drawn past column 80 is drawn into cells no assertion can read.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- glyph_mute_spec with FIXTURE and FOCUS in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.termguicolors = true
vim.o.columns = 80
vim.o.lines = 24

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- One column wide and more than one byte long, which is what a devicon is.
local LUA = "λ"
-- The group `mini.icons` answers with. A host's group, and never one this plugin defines.
local AZURE = "MiniIconsAzure"

vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, AZURE, { fg = 0x00ee00 })

-- The **fade** and the **counterpart row** are both off, so the one thing that moves between
-- the two readings is whether the pane has focus. A header row is exempt from the fade
-- anyway, and the cursor is kept off the row under test below -- turning them off is what
-- makes each cell answer for one reason rather than for three.
require("codereview").setup({
  layout = "unified",
  syntax = false,
  muted = { enabled = true, strength = 0.5 },
  counterpart = { enabled = false },
  faded = { enabled = false },
  file_icon = function(_)
    return LUA, AZURE
  end,
})

local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "no review view opened")

local NS = vim.api.nvim_create_namespace("codereview")

---The bytes one file's header row draws in the adapter's own group, read off the marks the
---review really emitted.
---
---Read before the cell rather than at an offset this file expects the glyph at: a reading
---taken where the case already looked says nothing about where the surface put it, and a
---review that emitted no range at all would pass it.
---@param row integer 1-indexed
---@return integer col 0-indexed byte
local function glyph_col(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(V.buf, NS, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[4].hl_group == AZURE and m[4].end_col then
      return m[3]
    end
  end
  error("no range on that header row in the group the adapter answered with")
end

-- Not the first file: the cursor opens on that one, and a lit row would put a second reason
-- on the cell.
local fi = assert(V.files[2] and 2, "the scope holds one file, so every row is the cursor's")
local row = assert(V.render.file_rows[fi], "the second file has no header row")
local col = glyph_col(row)
assert(vim.api.nvim_win_get_cursor(V.win)[1] ~= row, "the cursor is on the row under test")

local tree = assert(V.panel_win, "no file tree")
vim.api.nvim_set_current_win(vim.env.FOCUS == "tree" and tree or V.win)

vim.cmd("redraw!")
local pos = vim.fn.screenpos(V.win, row, col + 1)
assert(pos.row > 0 and pos.col > 0, "the row under test is off screen")
local cell = vim.api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)
local attrs = cell[2] or {}

---@param value integer|nil
---@return string
local function hex(value)
  return value and ("%06x"):format(value) or "none"
end

-- `nvim -l` sends print to stderr, not stdout, so glyph_mute_spec reads both.
print(("cell %q fg=%s bg=%s at %d,%d"):format(cell[1], hex(attrs.foreground), hex(attrs.background), pos.row, pos.col))
vim.cmd("qa!")
