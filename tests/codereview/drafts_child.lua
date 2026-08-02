-- The first half of drafts_spec: a Neovim that abandons a half-written note and exits.
--
-- Deliberately a separate process. A draft is only meaningfully restored across a genuine
-- restart -- reopening the composer twice in one process proves nothing about what reached
-- the disk, because the value never left memory.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- drafts_spec with XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

-- No `compose`: the composer that keeps drafts is the plugin's own.
require("codereview").setup({ syntax = false })

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")

view.open("branch")
local V = assert(view.current(), "the review view did not open")
queue.clear()

local row, path
for r = 1, vim.api.nvim_buf_line_count(V.buf) do
  local a = V.render.anchors[r]
  if a and a.kind == "line" then
    row, path = r, V.files[a.file].path
    break
  end
end
assert(row, "no annotatable line in the render")

vim.api.nvim_set_current_win(V.win)
vim.api.nvim_win_set_cursor(V.win, { row, 0 })
annotate.annotate("bug")

-- Written, then walked away from -- which is the only way a draft is ever made.
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "written in an earlier session" })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)

-- Nothing is reported back. The spec opens the same fixture at the same scope and finds
-- the same first annotatable line, so both processes are talking about the same file
-- without having to pass its name between them -- and `qa!` would not reliably flush it.
local _ = path
vim.cmd("qa!")
