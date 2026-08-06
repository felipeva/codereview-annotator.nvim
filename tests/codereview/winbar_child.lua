-- One painted cell of a pane's **sticky header**, read in a process of its own.
--
-- The intersection neither slice could see. The winbar names the file the cursor is in, and
-- a review window without focus is **muted** through a highlight namespace -- and the bar
-- carries no highlight group of the plugin's own, so it draws in `WinBar` when its window
-- has focus and in `WinBarNC` when it does not, both of which the muted set covers. Whether
-- the file segment actually recedes with its pane is therefore a question about that
-- namespace reaching the winbar, and **no assertion about the bar's text can answer it**:
-- the text is identical bright or muted. Only the cell is different.
--
-- `WinBarNC` is what a non-current window's bar draws in whether or not anything is muted,
-- which is exactly why the control reading matters: with muting off the same cell must come
-- back at `WinBarNC`'s own colour. Muted and unmuted differing is the claim; a bar that
-- ignored the namespace would return the second colour in both runs.
--
-- The three constraints are `muted_child.lua`'s, for the reasons measured there: exactly one
-- `nvim__inspect_cell` call per process, because only the first is honest; an 80x24 grid,
-- because that is what a headless Neovim keeps whatever `columns` says; and colours whose
-- channels are all even, so a half-strength blend toward a black background has no rounding
-- in it.
--
-- `CELL` chooses which cell that is: the path, which carries no group of the plugin's own
-- and is the reading the muting is proven with, or the file's added count, which carries
-- one and is the reading the *colour* is proven with. Neither can stand in for the other:
-- the path says the bar recedes with its pane, and the count says a group of the plugin's
-- reaches the screen at all.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. Spawned by
-- `split_spec` with FIXTURE, FOCUS, MUTED and CELL in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.termguicolors = true
vim.o.columns = 80
vim.o.lines = 24

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
-- The two groups a winbar can draw in, given distinct colours so the reading says which one
-- it came from as well as how bright it was.
vim.api.nvim_set_hl(0, "WinBar", { fg = 0xeeee00, bg = 0x006600 })
vim.api.nvim_set_hl(0, "WinBarNC", { fg = 0xee0000, bg = 0x004400 })
-- What `CodeReviewStatAdd` links into, given a colour of its own that is neither of the
-- two above -- so a cell drawn in it cannot be confused with a cell that took the bar's own
-- foreground. A `%#Group#` sets the foreground and leaves the bar's background showing
-- through, which is why only the foreground here differs from `WinBar`'s.
vim.api.nvim_set_hl(0, "Added", { fg = 0x00cc66 })

require("codereview").setup({
  layout = "split",
  syntax = false,
  -- No tree: three windows over 80 columns leave a pane too narrow to name a file at all,
  -- and the file segment is the whole point of the cell being read.
  panel = { enabled = false },
  muted = { enabled = vim.env.MUTED ~= "0", strength = 0.5 },
})

local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "no review view opened")

-- Read a file the way a reviewer does, so the bar names the file under the cursor rather
-- than whichever one the review happened to open on.
local PATH = "src/nonl.md"
local index
for i, f in ipairs(V.files) do
  if f.path == PATH then
    index = i
  end
end
assert(index, PATH .. " is not in this fixture's branch scope")
vim.api.nvim_set_current_win(V.win)
vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index] + 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })

-- Focus decides which pane is muted; the cell read is always the *after* pane's, so
-- FOCUS=before is the muted reading and FOCUS=after the bright one.
vim.api.nvim_set_current_win(vim.env.FOCUS == "before" and V.before_win or V.win)

-- Where that segment starts on the bar, in display columns of what the bar *draws*.
--
-- Taken from `nvim_eval_statusline` rather than from the option's own string, and both
-- halves of that matter. Columns rather than bytes, because the icon and the chevron in
-- front of the path are multibyte and a byte offset lands two cells early. Drawn rather than
-- written, because the bar carries highlight markers -- characters in the string and no
-- columns at all on the screen -- so a reading measured off the option drifts right by the
-- width of every marker in front of it. Same trap, arriving from the two opposite sides.
local file = V.files[index]
local needle = vim.env.CELL == "stat" and ("+%d -%d"):format(file.added, file.removed) or PATH
local drawn = vim.api.nvim_eval_statusline(vim.wo[V.win].winbar, { winid = V.win, use_winbar = true })
local at = assert(drawn.str:find(needle, 1, true), ("the winbar does not carry %q: %s"):format(needle, drawn.str))
local offset = vim.fn.strdisplaywidth(drawn.str:sub(1, at - 1))

-- A window's own position is its winbar's row, its text beginning one row below.
local top, left = unpack(vim.api.nvim_win_get_position(V.win))

vim.cmd("redraw!")
local cell = vim.api.nvim__inspect_cell(1, top, left + offset)
local attrs = cell[2] or {}

-- `nvim -l` sends print to stderr, not stdout, so split_spec reads both.
print(
  ("cell %s fg=%s bg=%s"):format(
    cell[1],
    attrs.foreground and ("%06x"):format(attrs.foreground) or "none",
    attrs.background and ("%06x"):format(attrs.background) or "none"
  )
)
vim.cmd("qa!")
