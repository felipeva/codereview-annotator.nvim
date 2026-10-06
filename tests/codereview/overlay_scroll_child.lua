-- overlay_spec's child: the **margin** repainted by the events alone, on a main loop of its
-- own.
--
-- `WinScrolled` and `WinResized` fire from the main loop's check between two inputs. A spec
-- case runs from start to finish without ever yielding to that loop -- fed keys and
-- `:redraw` both run without it -- so in overlay_spec a scroll changes the window and fires
-- nothing, and a margin that never listened would pass every case there. This process runs
-- each step on a timer, so the loop turns between steps and the events fire as they do for a
-- reviewer.
--
-- Under `--headless -c luafile` and not `-l`, which exits when the script ends and so never
-- reaches a timer.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- overlay_spec with XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own. It writes one JSON
-- object to stdout and exits; a step that never runs leaves the parent's kill timer to end it.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 80
vim.o.lines = 24
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local LONG = "src/long.lua"
local lines = {}
for i = 1, 200 do
  lines[i] = ("local l%d = %d"):format(i, i)
end
vim.fn.writefile(lines, LONG)
vim.cmd("edit " .. LONG)
local code = vim.api.nvim_get_current_win()

require("codereview").setup({ syntax = false })
local overlay = require("codereview.overlay")
local queue = require("codereview.queue")
local state = require("codereview.state")

state.ensure_queue()
queue.add({
  type = "bug",
  kind = "line",
  path = LONG,
  abs_path = vim.fs.joinpath(assert(vim.uv.fs_realpath(fixture)), LONG),
  key = LONG .. ":n:20",
  first = 20,
  last = 20,
  note = "a note",
})
require("codereview").overlay()

---The margin row whose text starts with the card's header, or 0.
---@return integer
local function card_row()
  for i, line in ipairs(vim.api.nvim_buf_get_lines(overlay.margin().buf, 0, -1, false)) do
    if line:find("bug 20", 1, true) then
      return i
    end
  end
  return 0
end

local out = { before = card_row() }

---@param steps fun()[]
local function chain(steps)
  local i = 0
  local function step()
    i = i + 1
    if steps[i] then
      steps[i]()
      vim.defer_fn(step, 30)
    end
  end
  vim.defer_fn(step, 30)
end

chain({
  function()
    vim.api.nvim_win_call(code, function()
      vim.cmd("normal! 10\5")
    end)
  end,
  function()
    out.scrolled = card_row()
    -- Shorter by four rows: the margin's buffer is rewritten to the window's new height.
    vim.o.lines = 20
  end,
  function()
    out.height = vim.api.nvim_win_get_height(overlay.margin().win)
    out.rows = vim.api.nvim_buf_line_count(overlay.margin().buf)
    io.stdout:write(vim.json.encode(out) .. "\n")
    vim.cmd("qa!")
  end,
})
