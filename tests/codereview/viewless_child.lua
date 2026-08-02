-- The writing half of viewless_spec, in its own process.
--
-- Two phases, in this order on purpose:
--   1. a normal review that leaves reviewed marks in the state file, so the viewless
--      write in phase 2 has something it could clobber;
--   2. queueing with no review view open at all.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. Spawned with
-- XDG_STATE_HOME and FIXTURE in its environment, and must NOT load tests/minimal_init.lua,
-- which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40

local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

require("codereview").setup({ syntax = false })

local view = require("codereview.view")
local queue = require("codereview.queue")

--- Phase 1: a review, so the state file carries reviewed marks -------------------
view.open("branch")
local V = assert(view.current(), "the view did not open")
for i, file in ipairs(V.files) do
  if file.path == "src/main.lua" then
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[i], 0 })
    view.toggle_reviewed()
  end
end
assert(V.reviewed["src/main.lua"], "src/main.lua was not marked reviewed")

view.close()
assert(view.current() == nil, "the view did not close")

--- Phase 2: queue with nothing open ---------------------------------------------
queue.clear()
queue.add({
  type = "bug",
  kind = "file",
  path = "src/routes.lua",
  abs_path = vim.fs.joinpath(fixture, "src/routes.lua"),
  key = "src/routes.lua:f:0",
  note = "queued with no view",
})
queue.add({
  type = "nitpick",
  kind = "file",
  path = "src/fresh.lua",
  abs_path = vim.fs.joinpath(fixture, "src/fresh.lua"),
  key = "src/fresh.lua:f:0",
  note = "queued with no view either",
})
view.persist()

print("queued: " .. queue.count())
vim.cmd("qa!")
