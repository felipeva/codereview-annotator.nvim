-- One painted cell where two of the review's quiet states meet, read in a process of its own.
--
-- Deliberately a separate process, and deliberately one cell. `nvim__inspect_cell` reports
-- a cell's real foreground and background only on the **first** call a process makes; every
-- call after it returns attributes belonging to something else entirely -- measured rather
-- than assumed, and recorded in `muted_child.lua` beside it. So the whole point of this file
-- is to make exactly one such call, in one arrangement, and print what it saw.
--
-- A group name cannot tell a faded row from a bright one, and it cannot tell one blend from
-- two. The cell is the only reading that says where a colour really ended up.
--
-- The screen is 80x24 because that is the grid a headless Neovim keeps whatever `columns`
-- and `lines` are set to: a window drawn past column 80 is drawn into cells no assertion can
-- read.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- quiet_spec with FIXTURE, CELL, CURSOR, FOCUS and MUTED in its environment, and it must NOT
-- load tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.termguicolors = true
vim.o.columns = 80
vim.o.lines = 24

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- Colours the arithmetic is exact on: every channel divides by four, so a blend halfway to a
-- black background and a blend a quarter of the way are both colours with no rounding in
-- them -- and so is one laid over the other.
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x004400 })
vim.api.nvim_set_hl(0, "@keyword", { fg = 0xec0000 })
-- What the marker of a queued entry draws in, through `CodeReviewBug`, and what the marker
-- of an archived one draws in, through `CodeReviewArchived`. Two colours of their own, so a
-- reading of either says which of the two it read.
vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0x00ec00, bg = 0x440044 })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x0000ec, bg = 0x444400 })

require("codereview").setup({
  layout = "unified",
  syntax = true,
  -- Two strengths that cannot be mistaken for each other. A cell blended once at either of
  -- them, and a cell blended at both, are three different colours -- which is what lets one
  -- reading say how many times a colour was pulled toward the background.
  muted = { enabled = vim.env.MUTED ~= "0", strength = 0.25 },
  faded = { enabled = true, strength = 0.5 },
  -- One type, with an ASCII marker: the cell under test then holds a character this file can
  -- name, where the shipped icons are glyphs of a font nothing here has.
  types = { { name = "bug", key = "b", icon = "!", hl = "CodeReviewBug", label = "Bugs" } },
  compose = function(_, on_accept)
    on_accept(nil, "a note inside a faded file")
  end,
  send = function()
    return true
  end,
})

local annotate = require("codereview.annotate")
local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "no review view opened")

-- The file every reading is taken inside. Not the first file of the review, so the cursor
-- has somewhere else to be.
local PATH = "src/main.lua"

---@return integer
local function target()
  for i, f in ipairs(V.files) do
    if f.path == PATH then
      return i
    end
  end
  error(PATH .. " is not in this review")
end

---The rows of `PATH` carrying a diff line of one side, lowest first.
---@param side string
---@return integer[]
local function rows_of(side)
  local rows = {}
  for row, a in pairs(V.render.anchors) do
    if a.kind == "line" and V.files[a.file].path == PATH then
      local ln = V.files[a.file].hunks[a.hunk].lines[a.line]
      if ln.side == side then
        rows[#rows + 1] = row
      end
    end
  end
  table.sort(rows)
  return rows
end

---Put the cursor on `row` and raise the event a reviewer's keystroke would.
---
---Driven through that event because neither `nvim_win_set_cursor` nor a `normal!` motion
---raises `CursorMoved` under `nvim -l`.
---@param row integer
local function move_to(row)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
end

-- Every step below reports itself through `vim.notify`, and `nvim -l` prints that to the
-- stream the reading is read from. Silenced here so this process prints exactly one line.
vim.notify = function() end

-- One entry already dispatched and one still queued, each on a row of its own inside the
-- file under test, so one reading can be taken of each. The archived one goes first: a
-- submit empties the queue, and what is queued afterwards stays queued.
local archived_row = assert(rows_of("ctx")[1], "no context line to put an archived entry on")
move_to(archived_row)
annotate.annotate("bug")
view.submit()

local queued_row = assert(rows_of("add")[1], "no added line to put a queued entry on")
move_to(queued_row)
annotate.annotate("bug")

if vim.env.CURSOR == "in" then
  -- Onto that file's *header* row, not onto one of its code rows: the focused window draws a
  -- `cursorline`, and a reading taken on the lit row would be a reading of that instead.
  move_to(V.render.file_rows[target()])
  assert(view.current_file() == target(), "the cursor never reached the file under test")
else
  move_to(V.render.file_rows[1])
  assert(view.current_file() == 1, "the cursor never left the file under test")
  assert(target() ~= 1, "the file under test is the file the cursor is in")
end

local tree = assert(V.panel_win, "no file tree")
vim.api.nvim_set_current_win(vim.env.FOCUS == "tree" and tree or V.win)

---Where on screen the cell under test is.
---
---A queued entry and an archived one are drawn as virtual lines hanging under the row they
---are about, and a virtual line has no buffer position to ask `screenpos` for. So the row
---the entry belongs to is located, and the line under it is the one read. The marker sits
---three columns in, whatever the width of the icon after it.
---@return integer row, integer col Both 1-indexed screen positions
local function cell_at()
  local cell = vim.env.CELL or "code"
  if cell ~= "code" then
    local anchor = cell == "archived" and archived_row or queued_row
    local pos = vim.fn.screenpos(V.win, anchor, 1)
    assert(pos.row > 0 and pos.col > 0, "the annotated row is off screen")
    return pos.row + 1, pos.col + 3
  end
  -- The first token the replay painted on an *added* line of the file under test, so one
  -- cell carries both halves of the question: the line's own background under a foreground
  -- from a higher priority band.
  local painted = vim.api.nvim_buf_get_extmarks(V.buf, vim.api.nvim_create_namespace("codereview"), 0, -1, {
    details = true,
  })
  for _, m in ipairs(painted) do
    local group = m[4].hl_group
    local a = V.render.anchors[m[2] + 1]
    if
      (group == "@keyword" or group == "CodeReviewFaded.@keyword")
      and a
      and a.kind == "line"
      and V.files[a.file].path == PATH
      and V.files[a.file].hunks[a.hunk].lines[a.line].side == "add"
    then
      local pos = vim.fn.screenpos(V.win, m[2] + 1, m[3] + 1)
      assert(pos.row > 0 and pos.col > 0, "the row under test is off screen")
      return pos.row, pos.col
    end
  end
  error("no keyword was painted on an added line of " .. PATH .. " -- did the replay run?")
end

vim.cmd("redraw!")
local row, col = cell_at()
local cell = vim.api.nvim__inspect_cell(1, row - 1, col - 1)
local attrs = cell[2] or {}

-- `nvim -l` sends print to stderr, not stdout, so quiet_spec reads both.
print(
  ("cell %s fg=%s bg=%s at %d,%d"):format(
    cell[1],
    attrs.foreground and ("%06x"):format(attrs.foreground) or "none",
    attrs.background and ("%06x"):format(attrs.background) or "none",
    row,
    col
  )
)
vim.cmd("qa!")
