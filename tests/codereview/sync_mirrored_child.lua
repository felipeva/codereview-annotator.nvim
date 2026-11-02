-- One session of sync_mirrored_spec's restart case, in its own process.
--
-- MODE=write connects to the fake queue owner of the parent at SOCKET, waits for the
-- snapshot, captures a bare note of its own, and prints the uuids of its mirrored entries
-- and of the capture. MODE=read starts with no sync, reads the queue back, and prints the
-- uuid of each entry that came back.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it, and it must NOT
-- load tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
local mode = assert(vim.env.MODE, "MODE is not set")

vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local started = false
vim.notify = function(msg)
  if type(msg) == "string" and msg:find("Queue sync started", 1, true) then
    started = true
  end
end

local codereview = require("codereview")
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "from the child")
  end,
  sync = mode == "write" and {
    socket = assert(vim.env.SOCKET, "SOCKET is not set"),
    target = function()
      return { tool = "custom", address = "agent", cwd = fixture }
    end,
  } or nil,
})

local queue = require("codereview.queue")
local state = require("codereview.state")

if mode == "write" then
  vim.wait(5000, function()
    return started
  end, 10)
  local function mirrored()
    return vim.tbl_filter(function(e)
      return e.mirrored
    end, queue.entries())
  end
  vim.wait(3000, function()
    return #mirrored() > 0
  end, 10)
  for _, e in ipairs(mirrored()) do
    print("mirrored: " .. e.uuid)
  end
  vim.cmd("enew")
  codereview.annotate("issue")
  local captured = queue.all()[#queue.all()]
  print("captured: " .. captured.uuid)
else
  state.ensure_queue()
  for _, e in ipairs(queue.entries()) do
    print("restored: " .. e.uuid)
  end
end

vim.cmd("qa!")
