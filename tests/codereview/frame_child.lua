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
-- **The mark under `covered` is the review's own.** The surface this protects is the styled
-- path #199 draws on this row, and #199 has landed: `covered` reads a real
-- `CodeReviewFileDir` mark, emitted by the render, in the quiet half of a path. Until then it
-- read a stand-in this file emitted itself, at the same band, because the group did not exist
-- on that branch. Nothing else moved when the stand-in went, which is what it was shaped for.
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

  if cell_kind == "covered" then
    col = at + 1 -- inside the directory half, which the render draws in PATH_HL
  elseif cell_kind == "bare" then
    -- The first byte of the file's own name. Not *bare* of marks since #199 landed -- it
    -- carries `CodeReviewFileName` -- but bare of anything with a colour of its own: that
    -- group links to `Title`, which is where the header row's colour and the frame's rule
    -- both come from, so this cell reads the row's own colour whichever of them drew it. That
    -- is what makes it the control for `covered` and what stops it standing in for a second
    -- reading of the path.
    col = at + slash
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
