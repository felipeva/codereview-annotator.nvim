-- Phase 6, process 2: a fresh Neovim must restore progress, then invalidate it correctly
-- once the underlying files move.
-- Repo root from this file's own location, so the suite runs from any clone.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40
vim.cmd("cd " .. vim.fn.fnameescape(vim.env.FIXTURE))

local fail = 0
local function check(label, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then
    fail = fail + 1
  end
  print(("%s %-46s got=%s want=%s"):format(ok and "ok  " or "FAIL", label, vim.inspect(got), vim.inspect(want)))
end

require("codereview").setup({
  syntax = false,
  compose = function(ctx, on_accept, _)
    on_accept(nil, "note on " .. ctx.rel_path)
  end,
})
local view = require("codereview.view")
local queue = require("codereview.queue")
local state = require("codereview.state")

--- A genuinely cold start: nothing in memory, everything from disk. ------------
check("queue starts empty in a new process", queue.count(), 0)
view.open("branch")
local V = view.current()

check("reviewed mark restored", V.reviewed["src/main.ts"] ~= nil, true)
check("only that file is marked", vim.tbl_count(V.reviewed), 1)
check("queue restored", queue.count(), 2)
check("restored notes keep their type", vim.tbl_map(function(i)
  return i.type
end, queue.all()), { "bug", "nitpick" })
check("restored notes keep their text", queue.all()[1].note, "note on src/fresh.ts")
check("nothing stale yet", queue.stale_count(), 0)
check("restored mark collapses the file", (function()
  for _, a in pairs(V.render.anchors) do
    if V.files[a.file].path == "src/main.ts" and a.kind == "line" then
      return false
    end
  end
  return true
end)(), true)
check("ids continue, they do not collide", (function()
  local before = queue.count()
  queue.add({ type = "bug", kind = "file", path = "x", key = "x:f:0", note = "n" })
  local ids = {}
  for _, i in ipairs(queue.all()) do
    ids[i.id] = (ids[i.id] or 0) + 1
  end
  local dupes = vim.tbl_filter(function(c)
    return c > 1
  end, vim.tbl_values(ids))
  queue.remove(queue.all()[#queue.all()].id)
  return #dupes == 0 and queue.count() == before
end)(), true)

--- Change an ANNOTATED file: the note survives, flagged stale. -----------------
local notified = {}
local orig = vim.notify
vim.notify = function(msg, ...)
  notified[#notified + 1] = msg
  return orig(msg, ...)
end

vim.fn.writefile({ "export function fresh() {}", "// touched after annotating" }, "src/fresh.ts")
view.refresh()

check("annotated file's note is kept", queue.count(), 2)
check("annotated file's note is flagged stale", queue.all()[1].stale, true)
check("the untouched note is not flagged", queue.all()[2].stale, nil)
check("staleness was reported", vim.tbl_isempty(vim.tbl_filter(function(m)
  return m:find("stale", 1, true) ~= nil
end, notified)) == false, true)

--- Change a REVIEWED file: the mark is dropped outright. ----------------------
notified = {}
vim.fn.writefile({ "const app = express()", "const cfg = loadConfig()", "app.listen(cfg.port)", "// touched" }, "src/main.ts")
view.refresh()
vim.notify = orig

check("reviewed mark cleared when the file moves", V.reviewed["src/main.ts"], nil)
check("un-marking was reported", vim.tbl_isempty(vim.tbl_filter(function(m)
  return m:find("changed since review", 1, true) ~= nil
end, notified)) == false, true)
check("the file is expanded again", (function()
  for _, a in pairs(V.render.anchors) do
    if V.files[a.file].path == "src/main.ts" and a.kind == "line" then
      return true
    end
  end
  return false
end)(), true)

--- A stale note must render as stale and never travel as an @ref. -------------
view.paint()
local virt = vim.tbl_filter(function(m)
  return m[4].virt_lines ~= nil
end, vim.api.nvim_buf_get_extmarks(V.buf, vim.api.nvim_create_namespace("codereview"), 0, -1, { details = true }))
local saw_warning = false
for _, m in ipairs(virt) do
  for _, line in ipairs(m[4].virt_lines) do
    for _, chunk in ipairs(line) do
      if type(chunk[1]) == "string" and chunk[1]:find("stale", 1, true) then
        saw_warning = true
      end
    end
  end
end
check("stale note is marked in the buffer", saw_warning, true)

local text = require("codereview.payload").render(queue.all(), V.root, {
  types = require("codereview.config").get().types,
})
check("stale note is not sent as an @ref", text:find("@src/fresh.ts", 1, true), nil)
check("stale note says its anchor is untrustworthy", text:find("line numbers may be stale", 1, true) ~= nil, true)

--- A corrupt state file must not take the plugin down. ------------------------
local path = state.path(V.root)
vim.fn.writefile({ "{ this is not json" }, path)
local loaded = state.load(V.root)
check("corrupt state loads as empty", { vim.tbl_count(loaded.scopes), #loaded.queue }, { 0, 0 })

vim.fn.writefile({ vim.json.encode({ version = 99, scopes = { a = 1 }, queue = { 1, 2 } }) }, path)
loaded = state.load(V.root)
check("future version is discarded, not migrated", { vim.tbl_count(loaded.scopes), #loaded.queue }, { 0, 0 })

state.clear(V.root)
check("clear removes the file", vim.fn.filereadable(path), 0)
check("loading a missing file is empty, not an error", state.load(V.root).version, 1)

print(("\n%s  %d failure(s)"):format(fail == 0 and "ALL PASS" or "FAILURES", fail))
vim.cmd(fail == 0 and "qa!" or "cq")
