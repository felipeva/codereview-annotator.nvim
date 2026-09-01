-- Painted cells of a **frame**, one per process.
--
-- Two claims live here, and neither can be made anywhere else.
--
-- **The bottom rule mutes with its pane.** A group named anywhere `hl.groups()` does not read
-- comes back at full brightness in a pane without focus, and no assertion over group *names*
-- can tell that apart from a group that mutes. That is what the group tables exist to keep.
--
-- **The top rule does not flatten the row it is drawn on.** A `line_hl_group` replaces every
-- attribute it sets on every inline highlight the row carries -- at any priority, in either
-- direction -- so a frame group carrying a foreground would draw the whole file header row in
-- one colour and take the `+N -M` stat, the note count and a **path**'s own styling with it.
-- The rule's colour is therefore in `sp`, and the row's foreground is left to the marks that
-- own it. `docs/design-notes.md` has the measurement.
--
-- **The stand-in mark is this file's own, and it is meant to be replaced.** The surface this
-- protects is the styled path #199 draws on this row, in `CodeReviewFileDir`. That group and
-- those marks do not exist on this branch, so `covered` reads a mark this child emits itself,
-- in a group of its own, at the band the render's own column marks use -- the shape
-- `muted_child.lua` already uses for `MutedChildStranger`. When the styled path lands, drop
-- the emission below and point `PATH_HL` at `CodeReviewFileDir`: the cells, the assertions and
-- this file all stay as they are.
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

-- Colors the arithmetic is exact on: every channel is even, so a blend halfway to a black
-- background is a color with no rounding in it. `Title` is where the frame's colour comes
-- from -- `CodeReviewFileHeader` links to it, and the frame's groups take their rule from
-- there -- so 0x00ee00 comes out 0x007700 muted and can be mistaken for nothing.
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "Title", { fg = 0x00ee00 })

---The group the stand-in path mark is drawn in. Set directly rather than through a link, so a
---reading names the group it came from rather than only how bright it was.
local PATH_HL = "FrameChildPath"
vim.api.nvim_set_hl(0, PATH_HL, { fg = 0x2266aa })

require("codereview").setup({
  layout = "unified",
  syntax = false,
  muted = { enabled = true, strength = 0.5 },
  counterpart = { enabled = false },
  faded = { enabled = false },
})

local render = require("codereview.render")
local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "no review view opened")

local NS = vim.api.nvim_create_namespace("codereview")

---The first row carrying the frame's bottom edge, read off the marks the review really
---emitted rather than off the render's own arithmetic.
---@return integer row 1-indexed
local function pad_row()
  local best
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(V.buf, NS, 0, -1, { details = true })) do
    if m[4].line_hl_group == "CodeReviewFramePad" and (not best or m[2] + 1 < best) then
      best = m[2] + 1
    end
  end
  return assert(best, "no file's body was closed -- is the frame drawn at all?")
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

  -- The stand-in, over the directory half alone, in a namespace of this file's own so the
  -- review's next repaint would not clear it. At the band the render's own column marks use,
  -- which is what the styled path will arrive at.
  vim.api.nvim_buf_set_extmark(V.buf, vim.api.nvim_create_namespace("frame_child"), row - 1, at - 1, {
    end_col = at - 1 + slash,
    hl_group = PATH_HL,
    priority = render.PRIORITY.gutter,
  })

  if cell_kind == "covered" then
    col = at + 1 -- inside the directory half, under the stand-in
  elseif cell_kind == "bare" then
    col = at + slash -- the first byte of the file's own name, which nothing covers
  else
    error("CELL must be pad, covered or bare")
  end
  assert(vim.api.nvim_win_get_cursor(V.win)[1] ~= row, "the cursor is on the row under test")
end

-- The bottom rule is read in a **muted** pane, which is the claim it is there for. The top
-- rule is read in the pane with focus: what is under test there is how a line-wide group
-- composes with the marks beneath it, and a blend would put a second reason on the cell.
if cell_kind == "pad" then
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
-- rule the full width of the pane has to reach. A reading taken at the first column would
-- pass over a rule one cell wide.
local scol = pos.col - 1
if cell_kind == "pad" then
  scol = vim.api.nvim_win_get_position(V.win)[2] + vim.api.nvim_win_get_width(V.win) - 1
end
local cell = vim.api.nvim__inspect_cell(1, pos.row - 1, scol)
local attrs = cell[2] or {}

-- `nvim -l` sends print to stderr, not stdout, so frame_spec reads both.
print(
  ("cell %q fg=%s sp=%s underline=%s at %d,%d"):format(
    cell[1],
    attrs.foreground and ("%06x"):format(attrs.foreground) or "none",
    attrs.special and ("%06x"):format(attrs.special) or "none",
    tostring(attrs.underline),
    pos.row,
    scol + 1
  )
)
vim.cmd("qa!")
