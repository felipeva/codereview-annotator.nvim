-- One painted cell of a **frame**, read in a process of its own.
--
-- The claim the group tables exist to keep, and the one that fails silently: a frame row
-- inside a **muted** pane draws in the muting's blend of the frame's own group, and it keeps
-- its underline out there. A group named anywhere `hl.groups()` does not read would come back
-- at full brightness with nothing to report it, and no assertion over group *names* can tell
-- the two apart.
--
-- Deliberately a separate process, and deliberately one cell. `nvim__inspect_cell` reports a
-- cell's real attributes only on the **first** call a process makes; every call after it
-- returns attributes belonging to something else, which `muted_child.lua` measured rather
-- than assumed. So this file makes exactly one such call and prints what it saw.
--
-- **The cell read is the last column of the pane, on the blank pad row that closes a file.**
-- Two things are proven by that one cell and by no other. A blank row has no text under the
-- reading, so what is painted there is the line-wide group and nothing else -- no diff
-- background, no change bar, no replay. And the last column is as far past the end of the
-- text as the pane goes, which is what "a rule the full width of the pane" means; a reading
-- taken at the first column would pass over a rule one cell wide.
--
-- The **fade** and the **counterpart row** are both off. Each would put a second blend on
-- this cell, and one blend is what makes the number arithmetic rather than a guess. The row
-- read belongs to the file the cursor is in either way, so the fade would not reach it -- but
-- an option that cannot change the answer is one less thing a reader has to check.
--
-- The screen is 80x24 because that is the grid a headless Neovim keeps whatever `columns` and
-- `lines` are set to: a window drawn past column 80 is drawn into cells no assertion can read.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- frame_spec with FIXTURE in its environment, and it must NOT load tests/minimal_init.lua,
-- which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.termguicolors = true
vim.o.columns = 80
vim.o.lines = 24

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- Colors the arithmetic is exact on: every channel is even, so a blend halfway to a black
-- background is a color with no rounding in it. `Title` is where the frame's foreground comes
-- from -- `CodeReviewFileHeader` links to it, and both of that file's frame groups take their
-- color from there -- so 0x00ee00 comes out 0x007700 muted and can be mistaken for nothing.
vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
vim.api.nvim_set_hl(0, "Title", { fg = 0x00ee00 })

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

---The first row carrying the frame's bottom edge, read off the marks the review really
---emitted rather than off the render's own arithmetic.
---@return integer row 1-indexed
local function pad_row()
  local painted = vim.api.nvim_buf_get_extmarks(V.buf, vim.api.nvim_create_namespace("codereview"), 0, -1, {
    details = true,
  })
  local best
  for _, m in ipairs(painted) do
    local group = m[4].line_hl_group
    if group == "CodeReviewFramePad" and (not best or m[2] + 1 < best) then
      best = m[2] + 1
    end
  end
  return assert(best, "no file's body was closed -- is the frame drawn at all?")
end

local row = pad_row()
assert(vim.api.nvim_buf_get_lines(V.buf, row - 1, row, true)[1] == "", "the row read is not blank")
assert(vim.api.nvim_win_get_cursor(V.win)[1] ~= row, "the cursor is on the row under test")

-- Into the tree, which is what mutes the pane. The tree is never muted itself, so focus has
-- somewhere to be that leaves the diff without it.
local tree = assert(V.panel_win, "no file tree")
vim.api.nvim_set_current_win(tree)

vim.cmd("redraw!")
local pos = vim.fn.screenpos(V.win, row, 1)
assert(pos.row > 0, "the row under test is off screen")
-- The pane's own last column, computed rather than asked of `screenpos`: that function
-- answers for a position in the *text*, and a blank row has no text to ask about past its
-- first column.
local last = vim.api.nvim_win_get_position(V.win)[2] + vim.api.nvim_win_get_width(V.win) - 1
local cell = vim.api.nvim__inspect_cell(1, pos.row - 1, last)
local attrs = cell[2] or {}

-- `nvim -l` sends print to stderr, not stdout, so frame_spec reads both.
print(
  ("cell %q fg=%s bg=%s underline=%s at %d,%d"):format(
    cell[1],
    attrs.foreground and ("%06x"):format(attrs.foreground) or "none",
    attrs.background and ("%06x"):format(attrs.background) or "none",
    tostring(attrs.underline),
    pos.row,
    last + 1
  )
)
vim.cmd("qa!")
