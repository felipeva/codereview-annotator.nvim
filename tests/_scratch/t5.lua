-- Phase 5 check: payload rendering and the submit path.
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

local sent = {}
require("codereview").setup({
  compose = function(ctx, on_accept, _)
    on_accept(nil, ctx.note_override or ("re: " .. ctx.label))
  end,
  send = function(text, target)
    sent[#sent + 1] = { text = text, target = target }
  end,
  pick_target = function(cb)
    cb({ short = "janus · api", pane_id = "wV:p3", cwd = "/somewhere/else" })
  end,
})

local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")
local payload = require("codereview.payload")
local cfg = require("codereview.config").get()

view.open("branch")
local V = view.current()
queue.clear()

local function row_of(path, pred)
  for row, a in pairs(V.render.anchors) do
    if V.files[a.file].path == path and pred(a) then
      return row
    end
  end
end
local function at(row)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
end

--- relative_to ----------------------------------------------------------------
check("relative_to inside", payload.relative_to("/a/b/c.ts", "/a"), "b/c.ts")
check("relative_to trailing slash", payload.relative_to("/a/b/c.ts", "/a/"), "b/c.ts")
check("relative_to outside", payload.relative_to("/x/c.ts", "/a"), nil)
check("relative_to sibling prefix", payload.relative_to("/about/c.ts", "/a"), nil)

--- Build a mixed queue --------------------------------------------------------
at(row_of("src/fresh.ts", function(a) return a.kind == "line" end))
annotate.annotate("bug")
at(row_of("src/gone.ts", function(a) return a.kind == "line" end))
annotate.annotate("suggestion")
at(V.render.file_rows[1])
annotate.annotate("nitpick")
at(row_of("src/main.ts", function(a) return a.kind == "hunk" end))
annotate.annotate("bug")
check("queue size", queue.count(), 4)

--- In-tree render -------------------------------------------------------------
local text = payload.render(queue.all(), V.root, {
  types = cfg.types,
  scope_label = V.scope.label,
  files = #V.files,
  reviewed = 0,
})
print("\n========== payload (in-tree) ==========\n" .. text .. "\n=======================================")

check("header states the count and scope", text:match("^Code review — 4 annotations on branch vs master %(8 files, 0 reviewed%)") ~= nil, true)
check("bugs group leads with its directive", text:find("## Bugs (2) — diagnose and fix these", 1, true) ~= nil, true)
check("suggestions group present", text:find("## Suggestions (1) — evaluate; apply if sound", 1, true) ~= nil, true)
check("groups ordered by type, not capture", text:find("## Bugs", 1, true) < text:find("## Suggestions", 1, true), true)
-- Assert on heading content, not entry number: numbering follows group order, so the
-- indices shift whenever a type is added or reordered.
check("added line became a bare @ref", text:find("@src/fresh.ts#L1\n", 1, true) ~= nil, true)
check("whole file became @path", text:match("### %d+%. @src/fresh%.ts\n") ~= nil, true)
check("deleted line inlined, not @ref'd", text:match("### %d+%. src/gone%.ts:1 %(deleted%)") ~= nil, true)
check("deleted line's diff travels with it", text:find("```diff\n-delete me\n```", 1, true) ~= nil, true)
check("hunk always inlined", text:match("### %d+%. src/main%.ts:1%-3 %(change%)") ~= nil, true)
check("gone.ts is never @ref'd", text:find("@src/gone.ts", 1, true), nil)
check("numbering is continuous across groups", (function()
  local ns = {}
  for n in text:gmatch("### (%d+)%.") do
    ns[#ns + 1] = tonumber(n)
  end
  return ns
end)(), { 1, 2, 3, 4 })
check("no @ref repeated as a second line", text:find("#L1\n@src", 1, true), nil)

--- Out-of-tree render: every ref must degrade to inlined code -----------------
local outside = payload.render(queue.all(), "/somewhere/else", { types = cfg.types })
print("\n========== payload (out-of-tree) ==========\n" .. outside .. "\n==========================================")
check("out-of-tree: no @refs at all", outside:find("@src/", 1, true), nil)
check("out-of-tree: uses absolute paths", outside:find(V.root .. "/src/fresh.ts", 1, true) ~= nil, true)
check("out-of-tree: inlines the code an @ref would have carried", outside:find("+export function fresh() {}", 1, true) ~= nil, true)

--- Stale entries must never be @ref'd ----------------------------------------
queue.all()[1].stale = true
local staled = payload.render(queue.all(), V.root, { types = cfg.types })
check("stale entry loses its @ref", staled:find("@src/fresh.ts#L1", 1, true), nil)
check("stale entry says so", staled:find("line numbers may be stale", 1, true) ~= nil, true)
check("stale entry inlines its code", staled:find("+export function fresh() {}", 1, true) ~= nil, true)
queue.all()[1].stale = nil

--- Targeting + submit ---------------------------------------------------------
view.pick_target()
check("target recorded", V.target.short, "janus · api")
check("winbar shows the target", vim.wo[V.win].winbar:find("→ janus · api", 1, true) ~= nil, true)

view.submit()
check("send adapter called once", #sent, 1)
check("routed target passed through", sent[1].target.pane_id, "wV:p3")
check("refs resolved against the TARGET cwd, not ours", sent[1].text:find("@src/", 1, true), nil)
check("queue cleared after submit", queue.count(), 0)
check("view repainted with no notes", (function()
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(V.buf, vim.api.nvim_create_namespace("codereview"), 0, -1, { details = true })) do
    if m[4].virt_lines then
      return false
    end
  end
  return true
end)(), true)

--- Local target (no routing) --------------------------------------------------
V.target = nil
at(row_of("src/fresh.ts", function(a) return a.kind == "line" end))
annotate.annotate("fix")
view.submit()
check("second submit sent", #sent, 2)
check("local target is nil", sent[2].target, nil)
check("local submit uses @refs", sent[2].text:find("@src/fresh.ts#L1", 1, true) ~= nil, true)

--- No send adapter -> clipboard fallback --------------------------------------
require("codereview.config").setup({
  compose = function(ctx, on_accept, _) on_accept(nil, "x") end,
})
at(row_of("src/fresh.ts", function(a) return a.kind == "line" end))
annotate.annotate("bug")
view.submit()
check("without a send adapter the queue is kept", queue.count(), 1)
check("payload landed in the + register", vim.fn.getreg("+"):find("Code review", 1, true) ~= nil, true)

--- Queue float ----------------------------------------------------------------
view.review_queue()
local qwin = vim.api.nvim_get_current_win()
local qbuf = vim.api.nvim_win_get_buf(qwin)
local qlines = vim.api.nvim_buf_get_lines(qbuf, 0, -1, false)
print("\n========== queue float ==========")
for _, l in ipairs(qlines) do
  print(l)
end
check("float lists the group", qlines[1]:find("## Bugs", 1, true) ~= nil, true)
local wcfg = vim.api.nvim_win_get_config(qwin)
print("title=" .. tostring(wcfg.title[1][1]) .. " footer=" .. tostring(wcfg.footer[1][1]))
check("float title counts the queue", tostring(wcfg.title[1][1]):find("1 annotation", 1, true) ~= nil, true)

-- `x` drops the entry under the cursor and closes when nothing is left.
vim.api.nvim_win_set_cursor(qwin, { 2, 0 })
vim.api.nvim_feedkeys("x", "x", false)
check("x dropped the last entry", queue.count(), 0)
check("float closed when emptied", vim.api.nvim_win_is_valid(qwin), false)

print(("\n%s  %d failure(s)"):format(fail == 0 and "ALL PASS" or "FAILURES", fail))
vim.cmd(fail == 0 and "qa!" or "cq")
