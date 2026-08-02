-- Phase 4 check: annotation targeting, types, queue.
-- Repo root from this file's own location, so the suite runs from any clone.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.opt.runtimepath:append(vim.fn.expand("~/.local/share/nvim/lazy/nvim-treesitter"))
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

-- Synchronous stub composer, so capture completes inside the call.
local last_ctx
require("codereview").setup({
  compose = function(ctx, on_accept, _)
    last_ctx = ctx
    on_accept(nil, "note about " .. ctx.label)
  end,
})

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")
local render = require("codereview.render")

view.open("branch")
local V = view.current()
queue.clear()

local function row_of(path, pred)
  for row, a in pairs(V.render.anchors) do
    if V.files[a.file].path == path then
      if pred(a, row) then
        return row
      end
    end
  end
end
local function at(row)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- 1. an added line -> @ref, not inlined -------------------------------------
local add_row = row_of("src/fresh.ts", function(a)
  return a.kind == "line"
end)
at(add_row)
annotate.annotate("bug")
local e = queue.all()[1]
check("added line: type", e.type, "bug")
check("added line: kind", e.kind, "line")
check("added line: NOT inlined", e.inline, false)
check("added line: key", e.key, "src/fresh.ts:n:1")
check("added line: range", { e.first, e.last }, { 1, 1 })
-- Kept even though this entry renders as an @ref: an out-of-tree target needs the code.
check("added line: still carries its code", e.lines, { "+export function fresh() {}" })
check("composer got a titled ctx", last_ctx.label, "Bug · src/fresh.ts:1")

--- 2. a deleted line -> inlined diff block -----------------------------------
queue.clear()
local del_row = row_of("src/gone.ts", function(a)
  return a.kind == "line"
end)
at(del_row)
annotate.annotate("issue")
e = queue.all()[1]
check("deleted line: inlined", e.inline, true)
check("deleted line: tag", e.tag, "deleted")
check("deleted line: uses pre-image number", { e.first, e.last }, { 1, 1 })
check("deleted line: key is old-sided", e.key, "src/gone.ts:o:1")
check("deleted line: carries the diff", e.lines, { "-delete me" })

--- 3. a visual range across +/- -> inlined, tagged "change" ------------------
queue.clear()
local main_first = row_of("src/main.ts", function(a)
  return a.kind == "line" and a.line == 1
end)
at(main_first)
feed("Vjjjas") -- select all 4 rendered lines, annotate as suggestion
e = queue.all()[1]
check("range: one annotation queued", queue.count(), 1)
check("range: kind", e.kind, "range")
check("range: inlined (touches a deletion)", e.inline, true)
check("range: tag", e.tag, "change")
check("range: diff block has all 4 lines", e.lines, {
  " const app = express()",
  "-const cfg = load()",
  "+const cfg = loadConfig()",
  " app.listen(cfg.port)",
})

--- 4. a pure-addition range -> @ref with post-image numbers ------------------
queue.clear()
local un_first = row_of("src/untracked.ts", function(a)
  return a.kind == "line" and a.line == 1
end)
at(un_first)
feed("Vjan")
e = queue.all()[1]
check("pure-add range: not inlined", e.inline, false)
check("pure-add range: post-image numbers", { e.first, e.last }, { 1, 2 })
check("pure-add range: type", e.type, "nitpick")

--- 5. hunk header -> always inlined ------------------------------------------
queue.clear()
at(row_of("src/main.ts", function(a)
  return a.kind == "hunk"
end))
annotate.annotate("fix")
e = queue.all()[1]
check("hunk: kind", e.kind, "hunk")
check("hunk: always inlined", e.inline, true)
check("hunk: whole hunk captured", #e.lines, 4)

--- 6. file header -> whole file ----------------------------------------------
queue.clear()
at(V.render.file_rows[1])
annotate.annotate("suggestion")
e = queue.all()[1]
check("file: kind", e.kind, "file")
check("file: key", e.key, render.file_key(V.files[1].path))
check("file: tag", e.tag, "whole file")

--- 7. binary file -> file-level, never a line --------------------------------
queue.clear()
local bin_i
for i, f in ipairs(V.files) do
  if f.path == "src/untracked.bin" then
    bin_i = i
  end
end
at(V.render.file_rows[bin_i])
annotate.annotate("issue")
check("binary: falls back to whole file", queue.all()[1].kind, "file")
check("binary: tagged binary", queue.all()[1].tag, "binary")

--- 8. cross-file selection -> clamped to the first file ----------------------
queue.clear()
local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, ...)
  notified[#notified + 1] = msg
  return orig_notify(msg, ...)
end
local function warned()
  return vim.tbl_isempty(vim.tbl_filter(function(m)
    return m:find("clamped", 1, true) ~= nil
  end, notified)) == false
end

-- Start on an actual diff line of fresh.ts and run past its end into gone.ts.
at(add_row)
feed("V4jab")
e = queue.all()[1]
check("clamp: still one annotation", queue.count(), 1)
check("clamp: bound to the first file", e.path, "src/fresh.ts")
-- fresh.ts contributes exactly one diff line, so the clamped range collapses to it.
check("clamp: kept only that file's line", { e.first, e.last }, { 1, 1 })
check("clamp: kind stays line-ish", e.kind, "line")
check("clamp: warned about it", warned(), true)

-- Anchored on a file header instead: still "whole file", but the overlap is reported
-- rather than silently discarded.
queue.clear()
notified = {}
at(1)
feed("V7jab")
vim.notify = orig_notify
e = queue.all()[1]
check("clamp from header: whole file", e.kind, "file")
check("clamp from header: right file", e.path, "src/fresh.ts")
check("clamp from header: still warns", warned(), true)

--- 9. rendering ---------------------------------------------------------------
queue.clear()
at(add_row)
annotate.annotate("bug")
at(row_of("src/gone.ts", function(a)
  return a.kind == "line"
end))
annotate.annotate("nitpick")
view.paint()

local NS = vim.api.nvim_create_namespace("codereview")
local virt = vim.tbl_filter(function(m)
  return m[4].virt_lines ~= nil
end, vim.api.nvim_buf_get_extmarks(V.buf, NS, 0, -1, { details = true }))
check("annotations render as virt_lines", #virt, 2)
check("virt_line carries the note text", virt[1][4].virt_lines[1][#virt[1][4].virt_lines[1]][1]:find("note about", 1, true) ~= nil, true)

local header = vim.api.nvim_buf_get_lines(V.buf, V.render.file_rows[1] - 1, V.render.file_rows[1], false)[1]
print("\nheader with a note: " .. header)
check("file header advertises the note", header:find("[1 note]", 1, true) ~= nil, true)
-- The panel is a tree now, so row 1 is a directory; find the file's own row.
local plines = vim.api.nvim_buf_get_lines(V.panel_buf, 0, -1, false)
local fresh_i
for i, f in ipairs(V.files) do
  if f.path == "src/fresh.ts" then
    fresh_i = i
  end
end
local prow = V.panel_render.file_row[fresh_i]
check("panel shows the note count", plines[prow]:match("(%d)%s*$"), "1")
check("panel row is the file, not a directory", plines[prow]:find("fresh.ts", 1, true) ~= nil, true)

--- 10. a file-level note survives collapsing ---------------------------------
queue.clear()
at(V.render.file_rows[1])
annotate.annotate("issue")
at(V.render.file_rows[1])
view.toggle_reviewed()
local virt2 = vim.tbl_filter(function(m)
  return m[4].virt_lines ~= nil
end, vim.api.nvim_buf_get_extmarks(V.buf, NS, 0, -1, { details = true }))
check("file note still visible when collapsed", #virt2, 1)
view.toggle_reviewed()

--- 11. drop -------------------------------------------------------------------
queue.clear()
at(add_row)
annotate.annotate("bug")
annotate.annotate("fix")
check("two notes on one line", queue.count(), 2)
at(add_row)
annotate.drop()
check("drop removes the most recent", queue.count(), 1)
check("the earlier one survives", queue.all()[1].type, "bug")
at(add_row)
annotate.drop()
check("drop again empties it", queue.count(), 0)

--- 12. grouping order ---------------------------------------------------------
queue.clear()
for _, t in ipairs({ "nitpick", "bug", "issue", "bug" }) do
  at(add_row)
  annotate.annotate(t)
end
local groups = queue.grouped(require("codereview.config").get().types)
check("groups follow type order, not insertion", vim.tbl_map(function(g)
  return ("%s:%d"):format(g.type.name, #g.items)
end, groups), { "bug:2", "nitpick:1", "issue:1" })

print(("\n%s  %d failure(s)"):format(fail == 0 and "ALL PASS" or "FAILURES", fail))
vim.cmd(fail == 0 and "qa!" or "cq")
