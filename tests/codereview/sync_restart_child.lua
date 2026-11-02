-- One session of sync_restart_spec and sync_unsent_restart_spec, in its own process.
--
-- Deliberately a separate process. The queue is read back once per session, and the sync
-- reads its own lists from the disk at setup and at each connect. So only a new process can
-- show what a session left on the disk for the next one.
--
-- With `sync` set in every mode. SOCKET is the socket path: the fake queue owner of the
-- parent, or a path where nothing listens.
--
--   * MODE=capture: capture a bare note for each text in NOTES (comma-separated), wait until
--     the sync started, which is after the queue owner replied to every `keep`, and exit.
--   * MODE=away: no queue owner listens. In the queue float, drop the note DROP; then, when
--     SUBMIT is set, submit through the `send` adapter; then, when CAPTURE is set, capture a
--     bare note with that text; then, when EDIT is set (`old=new`), edit the note `old` to
--     `new` in the queue float.
--
-- Prints `entry: <note> <uuid>` for each entry in the queue at the end, for the parent.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned with
-- XDG_STATE_HOME and FIXTURE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
local socket = assert(vim.env.SOCKET, "SOCKET is not set")
local mode = assert(vim.env.MODE, "MODE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local messages = {}
local notify = vim.notify
vim.notify = function(msg, ...)
  messages[#messages + 1] = msg
  return notify(msg, ...)
end

---@param needle string
---@return boolean
local function said(needle)
  for _, m in ipairs(messages) do
    if type(m) == "string" and m:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local note = "unset"
local codereview = require("codereview")
codereview.setup({
  syntax = false,
  types = { { name = "question", key = "q", label = "Questions" } },
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
  send = function() end,
  sync = {
    socket = socket,
    target = function()
      return { tool = "custom", address = "agent", cwd = fixture }
    end,
  },
})

local queue = require("codereview.queue")

---@param text string
local function bare(text)
  vim.cmd("enew")
  note = text
  codereview.annotate("question")
end

---Press `keys` in the queue float on the row that holds `text`.
---@param text string
---@param keys string
local function in_float(text, keys)
  codereview.queue()
  assert(vim.fn.search(text) > 0, "the float does not show " .. text)
  vim.api.nvim_feedkeys(keys, "x", false)
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    vim.api.nvim_win_close(0, true)
  end
end

if mode == "capture" then
  for text in vim.env.NOTES:gmatch("[^,]+") do
    bare(text)
  end
  assert(
    vim.wait(5000, function()
      return said("Queue sync started")
    end, 10),
    "the sync did not start"
  )
else
  assert(not said("Queue sync started"), "a queue owner listens, and this mode needs none")
  if vim.env.DROP then
    in_float(vim.env.DROP, "x")
  end
  if vim.env.SUBMIT then
    codereview.submit()
    assert(queue.count() == 0, "the submit did not dispatch")
  end
  if vim.env.CAPTURE then
    bare(vim.env.CAPTURE)
  end
  if vim.env.EDIT then
    local old, new = vim.env.EDIT:match("^(.-)=(.*)$")
    note = new
    in_float(old, "e")
  end
end

for _, item in ipairs(queue.entries()) do
  print(("entry: %s %s"):format(item.note, item.uuid))
end
vim.cmd("qa!")
