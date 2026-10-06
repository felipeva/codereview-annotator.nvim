-- overlay_toggle_spec's child: a Neovim configured with the **overlay** on or off, asked what
-- it opened with and what the toggle then leaves it in.
--
-- A process of its own for the reason solo_toggle_child is one. "Unset means the configured
-- value" holds only until something in the process has toggled, and overlay_spec toggles in
-- its first cases; a new Neovim is the only place the configured value is still what decides.
-- Run from both values, because a margin that opens whatever the configuration says and one
-- that never opens are different bugs.
--
-- Under `-l`, where startup has already finished when this runs, so `setup` opens the margin
-- at once rather than waiting for a `VimEnter` that `-l` never fires.
--
-- With STYLE set, the configured style is the question: an entry is queued before `setup`,
-- so the drawing the session opens with has something to show, and the child says whether
-- it opened a margin and how many captions it hung.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- overlay_toggle_spec with XDG_STATE_HOME, FIXTURE, OVERLAY and optionally STYLE in its
-- environment, and it must NOT load tests/minimal_init.lua, which would mint a state
-- directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 80
vim.o.lines = 24
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local configured = assert(vim.env.OVERLAY, "OVERLAY is not set") == "true"
local style = vim.env.STYLE

-- The file is open before `setup`, as it is for a host whose configuration loads the plugin
-- after the files on the command line.
vim.cmd("edit src/main.lua")
local code = vim.api.nvim_get_current_win()

if style then
  require("codereview.state").ensure_queue()
  require("codereview.queue").add({
    type = "bug",
    kind = "line",
    path = "src/main.lua",
    abs_path = vim.fs.joinpath(assert(vim.uv.fs_realpath(fixture)), "src/main.lua"),
    key = "src/main.lua:n:2",
    first = 2,
    last = 2,
    note = "configured",
  })
end

require("codereview").setup({ overlay = { enabled = configured, width = 30, style = style }, syntax = false })

local overlay = require("codereview.overlay")

if style then
  local hung = 0
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, overlay.NS_ANCHOR, 0, -1, { details = true })) do
    hung = hung + (mark[4].virt_lines and #mark[4].virt_lines or 0)
  end
  print(("style=%s margin=%s captions=%d"):format(overlay.style(), overlay.margin() ~= nil, hung))
  vim.cmd("qa!")
end
local m = overlay.margin()
local opened = m ~= nil
local beside = opened and m.code == code and vim.api.nvim_win_get_width(m.win) == 30

local after = require("codereview").overlay()
local still = overlay.margin() ~= nil

-- `nvim -l` sends print to stderr; overlay_toggle_spec reads both streams.
print(("opened=%s beside=%s toggled=%s margin_after=%s"):format(opened, beside, after, still))
vim.cmd("qa!")
