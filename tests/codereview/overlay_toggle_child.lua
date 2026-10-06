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
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- overlay_toggle_spec with XDG_STATE_HOME, FIXTURE and OVERLAY in its environment, and it
-- must NOT load tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 80
vim.o.lines = 24
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local configured = assert(vim.env.OVERLAY, "OVERLAY is not set") == "true"

-- The file is open before `setup`, as it is for a host whose configuration loads the plugin
-- after the files on the command line.
vim.cmd("edit src/main.lua")
local code = vim.api.nvim_get_current_win()

require("codereview").setup({ overlay = { enabled = configured, width = 30 }, syntax = false })

local overlay = require("codereview.overlay")
local m = overlay.margin()
local opened = m ~= nil
local beside = opened and m.code == code and vim.api.nvim_win_get_width(m.win) == 30

local after = require("codereview").overlay()
local still = overlay.margin() ~= nil

-- `nvim -l` sends print to stderr; overlay_toggle_spec reads both streams.
print(("opened=%s beside=%s toggled=%s margin_after=%s"):format(opened, beside, after, still))
vim.cmd("qa!")
