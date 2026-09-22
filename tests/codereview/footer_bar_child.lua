-- One painted cell of the file tree's footer bar, read in a process of its own.
--
-- The claim a mark table cannot make: the bar reaches the screen, and it reaches it in the
-- group the footer's own text is drawn in. The footer row carries a line-wide
-- `CodeReviewTitle`, and a line-wide group with a foreground **replaces the foreground of
-- every column mark on the row** -- so no table over group names can say what colour the
-- bar's cells are. Measured here rather than argued: a filled cell and an empty cell read
-- the same foreground, which is the whole of "one colour, two glyphs", and a range added
-- over a filled cell in a group of its own reads that same foreground too, which is why the
-- bar was not given two.
--
-- The colours are set here rather than taken from whatever theme a runner has, so each
-- reading is an absolute number. `Normal` is white on black and `Title` -- which
-- `CodeReviewTitle` links to -- is `00ee00`; the probe group is `ee0000`, so a reading that
-- came back with the probe's own colour could not be mistaken for the row's.
--
-- Deliberately one cell per process. `nvim__inspect_cell` reports a cell's real attributes
-- only on the **first** call a process makes; every call after it returns attributes
-- belonging to something else, which `muted_child.lua` measured rather than assumed.
--
-- The screen is 80x24 because that is the grid a headless Neovim keeps whatever `columns`
-- and `lines` are set to. The file tree is drawn on the left at the panel width, so every
-- column of the footer row is inside that grid.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- panel_spec with FIXTURE and CELL in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.termguicolors = true
vim.o.columns = 80
vim.o.lines = 24

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- The two glyphs of the bar, spelled here rather than read off the panel, so a reading is
-- taken on the glyph this file names and not on whatever the surface happened to draw.
local FULL, EMPTY = "█", "░"

-- A group with a colour of its own, laid over a filled cell for the `flattened` reading.
local PROBE = "FooterBarProbe"

vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "Title", { fg = 0x00ee00 })
vim.api.nvim_set_hl(0, PROBE, { fg = 0xee0000 })

-- The **fade** and the muting are both off. Neither reaches the file tree -- the tree is
-- never muted and never faded -- so this is belt and braces rather than a fix, and it is
-- what makes the cell answer for one reason.
require("codereview").setup({
  layout = "unified",
  syntax = false,
  muted = { enabled = false },
  faded = { enabled = false },
})

local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "no review view opened")
local win = assert(V.panel_win, "no file tree")
local buf = assert(V.panel_buf)

-- Part-way through, so the row holds both kinds of cell at once and one reading can be
-- taken on either. Written onto the review and repainted rather than driven through the
-- key, because what is under test is the row and not how it came to say what it says.
for index = 1, 3 do
  V.reviewed[V.files[index].path] = V.files[index].blob or ""
end
view.paint()

local row = vim.api.nvim_buf_line_count(buf)
local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
assert(line:match("^%d+/%d+ reviewed"), "the last row of the tree is not the footer: " .. line)

---The first byte of a glyph on the footer row, read off the row the tree really drew rather
---than taken at an offset this file expects it at: a reading at the offset the case already
---looked at says nothing about where the surface put it.
---@param glyph string
---@return integer col 0-indexed byte
local function glyph_col(glyph)
  local at = line:find(glyph, 1, true)
  assert(at, ("the footer row draws no %q: %s"):format(glyph, line))
  return at - 1
end

local col = glyph_col(vim.env.CELL == "empty" and EMPTY or FULL)

if vim.env.CELL == "flattened" then
  -- A range in a group of its own over the filled cell -- exactly what a bar drawn in two
  -- colours would emit. The row's own line-wide group is left where it is.
  local ns = vim.api.nvim_create_namespace("footer_bar_probe")
  vim.api.nvim_buf_set_extmark(buf, ns, row - 1, col, { end_col = col + #FULL, hl_group = PROBE })
end

assert(vim.api.nvim_win_get_cursor(win)[1] ~= row, "the tree's cursor is on the row under test")

vim.cmd("redraw!")
local pos = vim.fn.screenpos(win, row, col + 1)
assert(pos.row > 0 and pos.col > 0, "the footer row is off screen")
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
