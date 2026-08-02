-- Tree panel + navigation.
-- Repo root from this file's own location, so the suite runs from any clone.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 120
vim.o.lines = 45
vim.cmd("cd " .. vim.fn.fnameescape(vim.env.TREE))

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
    on_accept(nil, "n")
  end,
})
local view = require("codereview.view")
local queue = require("codereview.queue")
local annotate = require("codereview.annotate")

view.open("branch")
local V = view.current()
queue.clear()

local function panel_lines()
  return vim.api.nvim_buf_get_lines(V.panel_buf, 0, -1, false)
end
local function show(title)
  print("\n===== " .. title .. " =====")
  for i, l in ipairs(panel_lines()) do
    print(("%3d |%s|"):format(i, l))
  end
end
local function pcur(row)
  vim.api.nvim_win_set_cursor(V.panel_win, { row, 0 })
end
local function row_of_dir(dir)
  for r, d in pairs(V.panel_render.row_dir) do
    if d == dir then
      return r
    end
  end
end
local function row_of_file(path)
  for i, f in ipairs(V.files) do
    if f.path == path then
      return V.panel_render.file_row[i]
    end
  end
end

show("tree")

--- Structure -------------------------------------------------------------------
local L = panel_lines()
check("root files and dirs both present", #V.panel_render.file_rows, #V.files)
check("directories are rows of their own", vim.tbl_count(V.panel_render.row_dir) > 0, true)

-- apps/api holds only src, which holds only main.ts + routes/ -> the chain compacts.
check("single-child chains compact", row_of_dir("apps/api/src") ~= nil, true)
check("uncompacted intermediates are gone", row_of_dir("apps/api"), nil)
check("packages/shared/src compacts too", row_of_dir("packages/shared/src") ~= nil, true)
check("apps does NOT compact (two children)", row_of_dir("apps") ~= nil, true)

-- Directories sort before files at the same level, alphabetically.
local top = {}
for i, l in ipairs(L) do
  if (V.panel_render.row_depth[i] or 99) == 0 then
    top[#top + 1] = vim.trim(l):gsub("%s+%d+/%d+$", ""):gsub("%s+$", "")
  end
end
print("top level: " .. vim.inspect(top))
check("dirs before files, alphabetical", top, { "▾ apps", "▾ docs", "▾ packages/shared/src", "○ README.md" })

check("basenames are shown, paths are the tree", L[row_of_file("apps/api/src/main.ts")]:find("main.ts", 1, true) ~= nil, true)
check("nested files are indented", L[row_of_file("apps/api/src/main.ts")]:match("^%s+") ~= nil, true)

--- Directory aggregates --------------------------------------------------------
-- Derived, not hardcoded: the tally must equal the files actually under that prefix.
local apps_n = #require("codereview.panel").files_under(V.files, "apps")
check("dir row shows a subtree tally", L[row_of_dir("apps")]:match("(%d+/%d+)%s*$"), ("0/%d"):format(apps_n))
check("root tally in the footer", L[#L], ("0/%d reviewed"):format(#V.files))

-- Reviewing one file must move its ancestors' counts.
vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[1], 0 })
local first_path = V.files[1].path
view.toggle_reviewed()
check("reviewing updates the footer", panel_lines()[#panel_lines()], ("1/%d reviewed"):format(#V.files))
view.toggle_reviewed()

--- Collapsing ------------------------------------------------------------------
local before = #panel_lines()
pcur(row_of_dir("apps"))
view.panel_select()
check("<CR> on a directory collapses it", #panel_lines() < before, true)
check("collapsed directory shows the closed chevron", panel_lines()[row_of_dir("apps")]:find("▸", 1, true) ~= nil, true)
check("its children are gone", row_of_file("apps/api/src/main.ts"), nil)
check("cursor stayed on the directory", vim.api.nvim_win_get_cursor(V.panel_win)[1], row_of_dir("apps"))
show("apps collapsed")

view.panel_select()
check("<CR> again expands", #panel_lines(), before)

pcur(row_of_dir("apps"))
view.panel_fold(true)
check("h collapses", V.collapsed["apps"], true)
view.panel_fold(false)
check("l expands", V.collapsed["apps"], nil)

-- h on a FILE folds its parent -- and the parent is by depth, not by proximity.
pcur(row_of_file("apps/web/src/index.ts"))
view.panel_fold(true)
check("h on a file folds its own parent", V.collapsed["apps/web/src"], true)
check("not a sibling directory it scrolled past", V.collapsed["apps/web/src/components"], nil)
V.collapsed = {}
view.panel_select() -- repaint

view.panel_fold_all(true)
check("zM collapses every directory", row_of_file("apps/api/src/main.ts"), nil)
show("all collapsed")
view.panel_fold_all(false)
check("zR expands every directory", row_of_file("apps/api/src/main.ts") ~= nil, true)

--- Reviewing a whole subtree ---------------------------------------------------
pcur(row_of_dir("apps"))
view.panel_toggle_reviewed()
local under = require("codereview.panel").files_under(V.files, "apps")
check("R on a directory marks the subtree", (function()
  for _, i in ipairs(under) do
    if not V.reviewed[V.files[i].path] then
      return false
    end
  end
  return #under
end)(), #under)
check("files outside it are untouched", V.reviewed["README.md"], nil)
check("dir tally reads fully reviewed", panel_lines()[row_of_dir("apps")]:match("(%d+/%d+)%s*$"), ("%d/%d"):format(apps_n, apps_n))
show("apps subtree reviewed")

view.panel_toggle_reviewed()
check("R again unmarks the subtree", vim.tbl_count(V.reviewed), 0)

--- Navigation ------------------------------------------------------------------
vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
view.jump("file", true)
check("]f still walks every file", vim.api.nvim_win_get_cursor(V.win)[1], V.render.file_rows[2])

-- Mark files 1..3 reviewed; ]F must skip them.
for i = 1, 3 do
  V.reviewed[V.files[i].path] = V.files[i].blob
  V.expanded[V.files[i].path] = false
end
view.paint()
vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
view.jump_unreviewed(true)
local landed = V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].file
check("]F skips reviewed files", landed, 4)
check("]F lands on a file header", V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].kind, "file")

-- From the last unreviewed file, ]F wraps rather than dead-ending.
vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[#V.files], 0 })
view.jump_unreviewed(true)
check("]F wraps to the first unreviewed", V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].file, 4)
V.reviewed = {}
V.expanded = {}
view.paint()

--- Annotation navigation -------------------------------------------------------
queue.clear()
local target_row
for row, a in pairs(V.render.anchors) do
  if a.kind == "line" and V.files[a.file].path == "packages/shared/src/types.ts" then
    target_row = row
  end
end
vim.api.nvim_win_set_cursor(V.win, { target_row, 0 })
annotate.annotate("bug")
vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
view.jump_annotation(true)
check("]a jumps to the annotated line", V.files[V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].file].path, "packages/shared/src/types.ts")
check("panel shows that file's note count", panel_lines()[row_of_file("packages/shared/src/types.ts")]:match("(%d)%s*$"), "1")

--- Panel <-> diff sync ---------------------------------------------------------
local mid = V.render.file_rows[5]
vim.api.nvim_win_set_cursor(V.win, { mid, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = V.buf })
check("panel follows the diff cursor", V.panel_current, 5)
local sel = vim.tbl_filter(function(m)
  return m[4].line_hl_group == "CodeReviewPanelSel"
end, vim.api.nvim_buf_get_extmarks(V.panel_buf, vim.api.nvim_create_namespace("codereview_panel"), 0, -1, { details = true }))
check("current file is highlighted in the tree", #sel, 1)
check("...on the right row", sel[1][2] + 1, V.panel_render.file_row[5])

--- Focus -----------------------------------------------------------------------
vim.api.nvim_set_current_win(V.win)
view.toggle_focus()
check("<Tab> focuses the tree", vim.api.nvim_get_current_win(), V.panel_win)
check("...landing on the current file", vim.api.nvim_win_get_cursor(V.panel_win)[1], V.panel_render.file_row[5])
view.toggle_focus()
check("<Tab> returns to the diff", vim.api.nvim_get_current_win(), V.win)

--- Tree navigation inside the panel --------------------------------------------
pcur(1)
view.panel_jump_file(true)
check("]f in the tree skips directory rows", V.panel_render.row_file[vim.api.nvim_win_get_cursor(V.panel_win)[1]] ~= nil, true)

--- Picker ----------------------------------------------------------------------
local offered
vim.ui.select = function(items, _, cb)
  offered = items
  for i, s in ipairs(items) do
    if s:find("packages/shared/src/types.ts", 1, true) then
      return cb(s, i)
    end
  end
end
vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
view.pick_file()
check("picker offers every file", #offered, #V.files)
-- Full paths, not the basenames the tree shows: the picker is how you disambiguate the
-- four files called index.ts.
check("picker shows full paths, not basenames", vim.tbl_isempty(vim.tbl_filter(function(s)
  return s:find("apps/web/src/index.ts", 1, true) ~= nil
end, offered)) == false, true)
check("picker jumped to the chosen file", V.files[V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].file].path, "packages/shared/src/types.ts")

-- A reviewed (collapsed) file must open when you deliberately jump to it.
local pth = "packages/shared/src/types.ts"
for i, f in ipairs(V.files) do
  if f.path == pth then
    V.reviewed[pth] = f.blob
    V.expanded[pth] = false
  end
end
view.paint()
view.pick_file()
check("jumping to a collapsed file expands it", V.expanded[pth], true)

print(("\n%s  %d failure(s)"):format(fail == 0 and "ALL PASS" or "FAILURES", fail))
vim.cmd(fail == 0 and "qa!" or "cq")
