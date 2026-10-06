-- One painted cell of a **tint**, read in a process of its own.
--
-- overlay_tint_spec reads the groups on the marks, and a group on a mark is not a colour on
-- screen: a tint group carrying no background, or one the cursor line draws over, passes every
-- case there. This reads the cell.
--
-- Deliberately one cell per process. `nvim__inspect_cell` reports a cell's real attributes
-- only on the **first** call a process makes, which `muted_child.lua` measured rather than
-- assumed.
--
-- The colours are set here, so a reading is an absolute number. `Normal`'s background is
-- black, and 12% -- the default strength -- of 0xc8 is 24 with nothing to round: a bug's tint is
-- `180000`, a fix's `001800`. `CursorLine` is a colour nothing else on screen holds, so the
-- cursor's row reading it says the cursor line is drawn there, and a tint left on that row
-- would read as a tint.
--
-- CELL picks the reading: `bug` and `fix` a row inside each range, `cursor` the row the cursor
-- is moved onto inside the bug's range from outside it -- through `CursorMoved`, since neither
-- `nvim_win_set_cursor` nor a motion raises it under `nvim -l` -- and `plain` a row no entry
-- covers, which carries no background attribute at all: `Normal`'s is the grid's default. With TGC=0 the terminal has no true colour, and what is printed is the marks rather
-- than a cell: a background set in true colour alone draws nothing there whether or not a tint
-- mark exists, so a cell could not tell the fallback from its absence.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- overlay_tint_spec with FIXTURE, CELL and TGC in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.termguicolors = vim.env.TGC ~= "0"
vim.o.columns = 80
vim.o.lines = 24

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x004488 })
vim.api.nvim_set_hl(0, "CodeReviewBug", { fg = 0xc80000 })
vim.api.nvim_set_hl(0, "CodeReviewFix", { fg = 0x00c800 })

local FILE = "src/tint.lua"
local lines = {}
for i = 1, 40 do
  lines[i] = ("local l%d = %d"):format(i, i)
end
vim.fn.writefile(lines, FILE)
vim.cmd("edit " .. FILE)
local win = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_get_current_buf()
vim.wo[win].cursorline = true
vim.wo[win].signcolumn = "yes"

require("codereview").setup({ syntax = false })
-- The toggle says "Overlay on", and `nvim -l` prints a notification where the reading goes.
vim.notify = function() end
local overlay = require("codereview.overlay")
local queue = require("codereview.queue")
local state = require("codereview.state")

state.ensure_queue()
local abs = vim.fs.joinpath(assert(vim.uv.fs_realpath(fixture)), FILE)
for _, e in ipairs({ { type = "bug", first = 3, last = 6 }, { type = "fix", first = 10, last = 12 } }) do
  queue.add({
    type = e.type,
    kind = "line",
    path = FILE,
    abs_path = abs,
    key = ("%s:n:%d"):format(FILE, e.first),
    first = e.first,
    last = e.last,
    note = "a note",
  })
end
vim.api.nvim_win_set_cursor(win, { 20, 0 })
vim.cmd("normal! gg")
require("codereview").overlay("inline")

if vim.env.TGC == "0" then
  local tints, signs = 0, 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.NS, 0, -1, { details = true })) do
    tints = tints + (m[4].line_hl_group and 1 or 0)
    signs = signs + (m[4].sign_text and 1 or 0)
  end
  print(("tints=%d signs=%d group=%d"):format(tints, signs, vim.fn.hlexists("CodeReviewTint.CodeReviewBug")))
  vim.cmd("qa!")
end

local line = ({ bug = 5, fix = 11, cursor = 4, plain = 20 })[vim.env.CELL]
assert(line, "CELL must be bug, fix, cursor or plain")
if vim.env.CELL == "cursor" then
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
end

vim.cmd("redraw!")
local pos = vim.fn.screenpos(win, line, 1)
assert(pos.row > 0 and pos.col > 0, "the row under test is off screen")
local cell = vim.api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)
local attrs = cell[2] or {}

-- `nvim -l` sends print to stderr, not stdout, so overlay_tint_spec reads both.
print(("cell %s bg=%s"):format(cell[1], attrs.background and ("%06x"):format(attrs.background) or "none"))
vim.cmd("qa!")
