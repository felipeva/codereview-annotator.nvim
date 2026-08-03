-- One session of norepo_spec's restart case, in its own process.
--
-- MODE=write captures three annotations of different provenance -- one inside the
-- repository, one about a file outside any checkout, one with no file at all -- and lets
-- persistence route them. MODE=read starts clean and reports what came back, which is the
-- only honest way to show that a store survives a restart.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it, and it must NOT
-- load tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
local loose = assert(vim.env.LOOSE_FILE, "LOOSE_FILE is not set")
local mode = assert(vim.env.MODE, "MODE is not set")

vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local codereview = require("codereview")
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "from an earlier session")
  end,
})

local queue = require("codereview.queue")
local state = require("codereview.state")

if mode == "write" then
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
  codereview.annotate("bug")

  vim.cmd("edit " .. vim.fn.fnameescape(loose))
  codereview.annotate("fix")

  vim.cmd("enew")
  codereview.annotate("issue")

  print("queued: " .. queue.count())
else
  -- What any new session does the first time it touches the queue. Called on the
  -- persistence module rather than through the review view: reading the queue back does
  -- not need a view, and this process deliberately never opens one.
  state.ensure_queue()
  local kinds = {}
  for _, item in ipairs(queue.all()) do
    kinds[#kinds + 1] = ("%s/%s"):format(item.type, item.kind)
  end
  print("restored: " .. queue.count())
  print("kinds: " .. table.concat(kinds, ","))
end

vim.cmd("qa!")
