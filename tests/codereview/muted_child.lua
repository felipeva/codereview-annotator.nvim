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
-- muted_spec with FIXTURE, FOCUS, CELL and MUTED in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.termguicolors = true
vim.o.columns = 80
vim.o.lines = 24

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- Colours the arithmetic is exact on: every channel is even, so a blend halfway to a black
-- background is a colour with no rounding in it.
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x004400 })
vim.api.nvim_set_hl(0, "@keyword", { fg = 0xee0000 })
-- A group this plugin cannot know about: not one of its own, and not one the treesitter
-- replay resolves. It must come out of a muted window at full brightness.
vim.api.nvim_set_hl(0, "MutedChildStranger", { fg = 0x00ee00 })

require("codereview").setup({
  layout = "unified",
  syntax = true,
  muted = { enabled = vim.env.MUTED ~= "0", strength = 0.5 },
})

local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "no review view opened")

-- The first token the replay painted on an *added* line, so one cell carries both halves of
-- the question: the line's own background under a foreground from a higher priority band.
local row, col
local painted = vim.api.nvim_buf_get_extmarks(V.buf, vim.api.nvim_create_namespace("codereview"), 0, -1, {
  details = true,
})
for _, m in ipairs(painted) do
  local anchor = V.render.anchors[m[2] + 1]
  if m[4].hl_group == "@keyword" and anchor and anchor.kind == "line" then
    local ln = V.files[anchor.file].hunks[anchor.hunk].lines[anchor.line]
    if ln.side == "add" then
      row, col = m[2] + 1, m[3]
      break
    end
  end
end
assert(row, "no keyword was painted on an added line -- did the replay run?")

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
