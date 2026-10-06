-- overlay_caption_spec's child: a **caption** re-wrapped by the resize event alone, on a main
-- loop of its own.
--
-- `WinResized` fires from the main loop's check between two inputs, which a spec case never
-- reaches (see overlay_scroll_child). This process runs each step on a timer, so the loop
-- turns between steps and the event fires as it does for a reviewer. Nothing here calls the
-- paint after the resize: if the rows change, the event changed them.
--
-- Under `--headless -c luafile` and not `-l`, which exits when the script ends and so never
-- reaches a timer.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- overlay_caption_spec with XDG_STATE_HOME and FIXTURE in its environment, and it must NOT
-- load tests/minimal_init.lua, which would mint a state directory of its own. It writes one
-- JSON object to stdout and exits; a step that never runs leaves the parent waiting on it.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 80
vim.o.lines = 24
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local FILE = "src/caption.lua"
local lines = {}
for i = 1, 40 do
  lines[i] = ("local l%d = %d"):format(i, i)
end
vim.fn.writefile(lines, FILE)
vim.cmd("edit " .. FILE)
local code = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_get_current_buf()

require("codereview").setup({ syntax = false })
local overlay = require("codereview.overlay")
local queue = require("codereview.queue")
local state = require("codereview.state")

local words = {}
for i = 1, 40 do
  words[i] = ("w%02d"):format(i)
end
state.ensure_queue()
queue.add({
  type = "bug",
  kind = "line",
  path = FILE,
  abs_path = vim.fs.joinpath(assert(vim.uv.fs_realpath(fixture)), FILE),
  key = FILE .. ":n:5",
  first = 5,
  last = 5,
  note = table.concat(words, " "),
})
require("codereview").overlay("inline")

---The caption's rows and the widest of them, with the text width they had to fit.
---@return { rows: integer, widest: integer, width: integer }
local function read()
  local out = { rows = 0, widest = 0 }
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.NS_ANCHOR, 0, -1, { details = true })) do
    for _, row in ipairs(mark[4].virt_lines or {}) do
      local text = table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, row))
      out.rows = out.rows + 1
      out.widest = math.max(out.widest, vim.fn.strdisplaywidth(text))
    end
  end
  out.width = vim.api.nvim_win_get_width(code) - vim.fn.getwininfo(code)[1].textoff
  return out
end

local out = {}

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
    out.wide = read()
    vim.o.columns = 40
  end,
  function()
    out.narrow = read()
    io.stdout:write(vim.json.encode(out) .. "\n")
    vim.cmd("qa!")
  end,
})
