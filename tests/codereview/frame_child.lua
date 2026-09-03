-- Painted cells of a **frame**, one per process.
--
-- Three claims live here, and none of them can be made anywhere else.
--
-- **The band is really painted, and it is computed from this process's own `Normal`.** The
-- colours below are set here rather than taken from whatever theme a runner has, so the
-- reading is an absolute number: a band pulled 20% from a black background toward a white
-- foreground is `333333`, and a reading of anything else says the strength moved or the band
-- came from somewhere other than `Normal`.
--
-- **The band does not flatten the row it fills.** A `line_hl_group` replaces every attribute
-- it sets on every inline highlight the row carries -- at any priority, in either direction --
-- so a band carrying a foreground would draw the whole file header row in one colour and take
-- the `+N -M` stat, the note count and a **path**'s own styling with it. A background is the
-- one attribute the row does not already own. `docs/design-notes.md` has the measurement.
--
-- **The band mutes with its pane.** A group named where `hl.groups()` does not read comes back
-- at full brightness in a pane without focus, and no assertion over group *names* can tell
-- that apart from a group that mutes. The muted cell reads the blended pair: the name's
-- foreground and the band's background, each pulled halfway to the backdrop.
--
-- The **pad** row is read for what is no longer there. Its group is still emitted -- the child
-- finds the mark before it reads the cell -- and on a true-colour terminal it paints nothing,
-- which is the doubled rule going away. An absence nothing emitted would read the same, so the
-- mark is asserted first and the cell second.
--
-- Deliberately one cell per process. `nvim__inspect_cell` reports a cell's real attributes
-- only on the **first** call a process makes; every call after it returns attributes belonging
-- to something else, which `muted_child.lua` measured rather than assumed.
--
-- The screen is 80x24 because that is the grid a headless Neovim keeps whatever `columns` and
-- `lines` are set to: a window drawn past column 80 is drawn into cells no assertion can read.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- frame_spec with FIXTURE and CELL in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.termguicolors = true
vim.o.columns = 80
vim.o.lines = 24

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- Colours the arithmetic is exact on. `Normal` is what the band is computed from, and a black
-- background pulled 20% toward a white foreground is `333333` in every channel with no
-- rounding in it -- so the reading names the strength as well as the fact that something was
-- painted. Muted, halfway to the same backdrop, that band is `1a1a1a`; `Title` is where the
-- file's own name takes its colour from, and 0x00ee00 comes out 0x007700 muted.
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "Title", { fg = 0x00ee00 })

---The group the quiet half of a **path** is drawn in. Set here, directly, rather than left to
---the link `hl.lua` gives it: a reading then names the group it came from rather than only how
---bright it was, and `Comment`'s own colour in whatever theme a runner has is not a number any
---assertion could hold. `hl.apply` links it with `default = true`, so this definition stands.
local PATH_HL = "CodeReviewFileDir"
vim.api.nvim_set_hl(0, PATH_HL, { fg = 0x2266aa })

require("codereview").setup({
  layout = "unified",
  syntax = false,
  muted = { enabled = true, strength = 0.5 },
  counterpart = { enabled = false },
  faded = { enabled = false },
})

local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "no review view opened")

local NS = vim.api.nvim_create_namespace("codereview")

---The first row carrying the frame's bottom edge, read off the marks the review really
---emitted rather than off the render's own arithmetic.
---
---Read before the cell rather than after it, so that "the pad row draws no rule" is a claim
---about a row the render really marked. A review that emitted nothing at all would otherwise
---pass the same reading.
---@return integer row 1-indexed
local function pad_row()
  local best
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(V.buf, NS, 0, -1, { details = true })) do
    if m[4].line_hl_group == "CodeReviewFramePad" and (not best or m[2] + 1 < best) then
      best = m[2] + 1
    end
  end
  return assert(best, "no file's body was closed -- is the pad group emitted at all?")
end

---A file with a directory in its path, and not the first file of the review: the cursor opens
---on that one, and a lit row would put a second reason on every cell read here.
---@return integer fi
local function file_with_a_directory()
  for i, f in ipairs(V.files) do
    if i > 1 and f.path:find("/") then
      return i
    end
  end
  error("no file below the first has a directory in its path")
end

local row, col
local cell_kind = vim.env.CELL

if cell_kind == "pad" then
  row, col = pad_row(), 1
else
  local fi = file_with_a_directory()
  row = assert(V.render.file_rows[fi])
  local text = vim.api.nvim_buf_get_lines(V.buf, row - 1, row, true)[1]
  local path = V.files[fi].path
  local at = assert(text:find(path, 1, true), "the path is not on its own header row: " .. text)
  local slash = assert(path:find("/[^/]*$"), "the path has no directory half")

  if cell_kind == "covered" then
    col = at + 1 -- inside the directory half, which the render draws in PATH_HL
  elseif cell_kind == "name" or cell_kind == "muted" then
    -- The first byte of the file's own name, which carries `CodeReviewFileName`. That group
    -- links to `Title`, so the cell reads the name's own foreground -- and it must read the
    -- band's background under it, which is the whole of what a band carrying no foreground
    -- buys. `muted` is the same cell in a pane without focus, where both halves are blended.
    col = at + slash
  else
    error("CELL must be pad, covered, name or muted")
  end
  assert(vim.api.nvim_win_get_cursor(V.win)[1] ~= row, "the cursor is on the row under test")
end

-- `muted` is the only reading taken in a pane without focus. Everywhere else what is under
-- test is how a line-wide group composes with the marks beneath it, and a blend would put a
-- second reason on the cell.
if cell_kind == "muted" then
  local tree = assert(V.panel_win, "no file tree")
  vim.api.nvim_set_current_win(tree)
else
  vim.api.nvim_set_current_win(V.win)
end

vim.cmd("redraw!")
local pos = vim.fn.screenpos(V.win, row, col)
assert(pos.row > 0 and pos.col > 0, "the row under test is off screen")
-- On the pad row, the pane's own last column: a blank row has no text to ask `screenpos`
-- about past its first column, and the last column is as far past the end of the text as a
-- rule the full width of the pane would have to reach. A reading taken at the first column
-- would pass over a rule one cell wide.
local scol = pos.col - 1
if cell_kind == "pad" then
  scol = vim.api.nvim_win_get_position(V.win)[2] + vim.api.nvim_win_get_width(V.win) - 1
end
local cell = vim.api.nvim__inspect_cell(1, pos.row - 1, scol)
local attrs = cell[2] or {}

---@param value integer|nil
---@return string
local function hex(value)
  return value and ("%06x"):format(value) or "none"
end

-- `nvim -l` sends print to stderr, not stdout, so frame_spec reads both.
print(
  ("cell %q fg=%s bg=%s sp=%s underline=%s at %d,%d"):format(
    cell[1],
    hex(attrs.foreground),
    hex(attrs.background),
    hex(attrs.special),
    tostring(attrs.underline),
    pos.row,
    scol + 1
  )
)
vim.cmd("qa!")
