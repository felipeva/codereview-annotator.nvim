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
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. Spawned by
-- `split_spec` with FIXTURE, FOCUS and MUTED in its environment, and it must NOT load
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

-- Where the path starts on that bar, in display columns rather than bytes: the icon and the
-- chevron in front of it are both multibyte, so a byte offset lands two cells early.
local bar = vim.wo[V.win].winbar
local at = assert(bar:find(PATH, 1, true), "the winbar does not name " .. PATH .. ": " .. bar)
local offset = vim.fn.strdisplaywidth(bar:sub(1, at - 1))

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
