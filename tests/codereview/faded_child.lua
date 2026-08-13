-- One painted cell of a review, read in a process of its own.
--
-- Deliberately a separate process, and deliberately one cell. `nvim__inspect_cell` reports
-- a cell's real foreground and background only on the **first** call a process makes; every
-- call after it returns attributes belonging to something else entirely -- measured rather
-- than assumed, and recorded in `muted_child.lua` beside it. So the whole point of this file
-- is to make exactly one such call, in one arrangement, and print what it saw.
--
-- A group name cannot tell a faded row from a bright one, which is why this exists at all:
-- the cell is the only reading that says the color really moved.
--
-- The screen is 80x24 because that is the grid a headless Neovim keeps whatever `columns`
-- and `lines` are set to: a window drawn past column 80 is drawn into cells no assertion can
-- read.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- faded_spec with FIXTURE, CURSOR and FADED in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
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

require("codereview").setup({
  layout = "unified",
  syntax = true,
  -- The window rule is off, so nothing but the fade can pull a color toward the background
  -- here. Its strength is deliberately not the fade's either: a fade that read the number
  -- beside it would print a color this cell can tell apart.
  muted = { enabled = false, strength = 0.25 },
  faded = { enabled = vim.env.FADED ~= "0", strength = 0.5 },
})

local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "no review view opened")

-- The first token the replay painted on an *added* line of a file the cursor is **not** in,
-- so one cell carries both halves of the question: the line's own background under a
-- foreground from a higher priority band, on a row the fade covers.
local current = assert(view.current_file(), "the cursor is in no file")
local row, col, target
local painted = vim.api.nvim_buf_get_extmarks(V.buf, vim.api.nvim_create_namespace("codereview"), 0, -1, {
  details = true,
})
for _, m in ipairs(painted) do
  local group = m[4].hl_group
  local anchor = V.render.anchors[m[2] + 1]
  if (group == "@keyword" or group == "CodeReviewFaded.@keyword") and anchor and anchor.kind == "line" then
    local ln = V.files[anchor.file].hunks[anchor.hunk].lines[anchor.line]
    if ln.side == "add" and anchor.file ~= current then
      row, col, target = m[2] + 1, m[3], anchor.file
      break
    end
  end
end
assert(row, "no keyword was painted on an added line of another file -- did the replay run?")

if vim.env.CURSOR == "in" then
  -- Onto that file's *header* row, not onto the token's own: the focused window draws a
  -- `cursorline`, and a reading taken on the lit row would be a reading of that instead.
  -- Driven through the event a reviewer's keystroke raises, because neither
  -- `nvim_win_set_cursor` nor a `normal!` motion raises `CursorMoved` under `nvim -l`.
  vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[target], 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
  assert(view.current_file() == target, "the cursor never reached the file under test")
end

vim.cmd("redraw!")
local pos = vim.fn.screenpos(V.win, row, col + 1)
assert(pos.row > 0 and pos.col > 0, "the row under test is off screen")
local cell = vim.api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)
local attrs = cell[2] or {}

-- `nvim -l` sends print to stderr, not stdout, so faded_spec reads both.
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
