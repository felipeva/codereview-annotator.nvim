-- The first half of solo_toggle_spec's restart proof: a Neovim that presses `go` and exits.
--
-- Deliberately a separate process, for the reason `wrap_child.lua` and `archived_child.lua`
-- beside it are. "The override dies with the session" is a claim about what a *new* Neovim
-- starts with, and no assertion made in the process that pressed the key can settle it: a
-- module local cleared by hand says nothing about what reached the disk, and an assertion
-- made here would pass however the override were stored.
--
-- Run twice, from opposite configured values, because the claim is about both directions. A
-- session configured to draw every file presses the key and ends drawing one; a session
-- configured to draw one presses it and ends drawing every one. Either way the next session
-- must start from configuration, and each direction rules out a different way of getting
-- that wrong -- a leftover `true` and a leftover `false` are not the same bug.
--
-- It also queues an annotation, which the store genuinely does carry. That is what lets the
-- next session prove the channel between the two is live before concluding the switch is not
-- on it: without it, "the choice did not come back" would be satisfied by nothing coming
-- back at all. The note says nothing about the word this file's parent greps the store for.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- solo_toggle_spec with XDG_STATE_HOME, FIXTURE and SOLO in its environment, and it must NOT
-- load tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local configured = assert(vim.env.SOLO, "SOLO is not set") == "true"
-- Two texts, so the parent can tell which session's note it found. Neither carries the word
-- the parent looks for in the store, or this file would plant the evidence it is here to
-- rule out.
local note = configured and "queued by the session that widened" or "queued by the session that narrowed"

require("codereview").setup({
  solo = configured,
  syntax = false,
  compose = function(_, on_accept, _)
    on_accept(nil, note)
  end,
})

local config = require("codereview.config")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

---How many files the paint drew, read off the anchors rather than off `file_rows`: the map
---is legitimately sparse under solo, and the question here is what has rows.
---@return integer
local function files_drawn()
  local seen, n = {}, 0
  local rendered = assert(view.current()).render
  for row = 1, #rendered.lines do
    local fi = rendered.anchors[row].file
    if not seen[fi] then
      seen[fi], n = true, n + 1
    end
  end
  return n
end

view.open("branch")
local V = assert(view.current(), "no review view opened")
assert(#V.files > 1, "the fixture has one file, so drawing one proves nothing")
assert(config.solo() == configured, "the child did not open at the value it was configured with")

-- The count rather than one: the store is shared with the session before this one, whose
-- note this session restores on the way in.
local before = #queue.all()
require("codereview.annotate").annotate("bug")
assert(#queue.all() == before + 1, "the child queued nothing for the store to carry")

view.toggle_solo()
assert(config.solo() == not configured, "the child never reached the other state")
assert(files_drawn() == (configured and #V.files or 1), "the child's key moved the switch but not the diff")
assert(config.get().solo == configured, "the child wrote the configured value")

-- Resolved, because the state store is keyed on the root git answers with, and git answers
-- with symlinks resolved.
local root = assert(vim.uv.fs_realpath(fixture))
-- Printed so a failing solo_toggle_spec can show what the session that pressed the key
-- believed it did. `nvim -l` sends this to stderr, not stdout.
print(("configured %s, ended %s; state file: %s"):format(configured, config.solo(), state.path(root)))
vim.cmd("qa!")
