-- One painted cell of a review, read in a process of its own.
--
-- Deliberately a separate process, and deliberately one cell. `nvim__inspect_cell` reports
-- a cell's real foreground and background only on the **first** call a process makes; every
-- call after it returns attributes belonging to something else entirely, which was measured
-- rather than assumed -- reading the same cell twice in a row gives two different answers,
-- and the second one is wrong. So the whole point of this file is to make exactly one such
-- call, in one arrangement, and print what it saw.
--
-- The screen is 80x24 because that is the grid a headless Neovim keeps whatever `columns`
-- and `lines` are set to: a window drawn past column 80 is drawn into cells no assertion can
-- read.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- muted_spec with FIXTURE, FOCUS, CELL, CURSOR, MUTED and COUNTERPART in its environment,
-- and it must NOT load tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.termguicolors = true
vim.o.columns = 80
vim.o.lines = 24

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- Colors the arithmetic is exact on: every channel is even, so a blend halfway to a black
-- background is a color with no rounding in it.
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x004400 })
vim.api.nvim_set_hl(0, "@keyword", { fg = 0xee0000 })
-- The row a **pane** lights. A color of its own, and its channels divide by four, so the
-- muting's half and the counterpart row's quarter are both exact and neither can be mistaken
-- for the other: 0x004488 comes out 0x002244 muted and 0x003366 as a counterpart row.
vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x004488 })
-- A group this plugin cannot know about: not one of its own, and not one the treesitter
-- replay resolves. It must come out of a muted window at full brightness.
vim.api.nvim_set_hl(0, "MutedChildStranger", { fg = 0x00ee00 })

require("codereview").setup({
  layout = "unified",
  syntax = true,
  muted = { enabled = vim.env.MUTED ~= "0", strength = 0.5 },
  counterpart = { enabled = vim.env.COUNTERPART ~= "0", strength = 0.25 },
})

local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "no review view opened")

---The first token the replay painted on a diff line of `side`, and the file it is in.
---
---Matched on the **faded** twin of the capture group as well as on the group itself: every
---file but the one the cursor is in is faded, and the row this hands back may well be in one
---of them until the cursor is moved into it.
---@param side string
---@return integer row, integer col, integer file
local function token_on(side)
  local painted = vim.api.nvim_buf_get_extmarks(V.buf, vim.api.nvim_create_namespace("codereview"), 0, -1, {
    details = true,
  })
  for _, m in ipairs(painted) do
    local group = m[4].hl_group
    local anchor = V.render.anchors[m[2] + 1]
    if (group == "@keyword" or group == "CodeReviewFaded.@keyword") and anchor and anchor.kind == "line" then
      local ln = V.files[anchor.file].hunks[anchor.hunk].lines[anchor.line]
      if ln.side == side then
        return m[2] + 1, m[3], anchor.file
      end
    end
  end
  error("no keyword was painted on a " .. side .. " line -- did the replay run?")
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

local row, col
if vim.env.CELL == "row" then
  -- A **context** line, because a lit row can only be read on a row with no line background
  -- of its own: `line_hl_group` wins over `CursorLine` -- measured, not assumed -- so a lit
  -- added line prints exactly what an unlit one does and says nothing about either.
  local file
  row, col, file = token_on("ctx")
  -- Into the file the reading is taken in either way, so the **fade** is the same in both
  -- and the one thing that moves is whether the row under test is the row the cursor is on.
  -- The control goes to that file's *header* row: a code row of its own would be lit too.
  move_to(vim.env.CURSOR == "on" and row or V.render.file_rows[file])
  assert(view.current_file() == file, "the cursor never reached the file under test")
else
  -- The first token the replay painted on an *added* line, so one cell carries both halves
  -- of the question: the line's own background under a foreground from a higher priority
  -- band.
  row, col = token_on("add")
end

if vim.env.CELL == "stranger" then
  -- Over the same cell, above the replay's band, in a namespace of this file's own so the
  -- review's next repaint would not clear it.
  vim.api.nvim_buf_set_extmark(V.buf, vim.api.nvim_create_namespace("muted_child"), row - 1, col, {
    end_col = col + 1,
    hl_group = "MutedChildStranger",
    priority = 200,
  })
end

local tree = assert(V.panel_win, "no file tree")
vim.api.nvim_set_current_win(vim.env.FOCUS == "tree" and tree or V.win)

vim.cmd("redraw!")
local pos = vim.fn.screenpos(V.win, row, col + 1)
assert(pos.row > 0 and pos.col > 0, "the row under test is off screen")
local cell = vim.api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)
local attrs = cell[2] or {}

-- `nvim -l` sends print to stderr, not stdout, so muted_spec reads both.
print(
  ("cell %s fg=%s bg=%s at %d,%d"):format(
    cell[1],
    attrs.foreground and ("%06x"):format(attrs.foreground) or "none",
    attrs.background and ("%06x"):format(attrs.background) or "none",
    pos.row,
    pos.col
  )
)
vim.cmd("qa!")
