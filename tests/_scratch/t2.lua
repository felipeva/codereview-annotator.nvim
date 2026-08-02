-- Phase 2 check: render/view/panel against the fixture repo.
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
  print(("%s %-44s got=%s want=%s"):format(ok and "ok  " or "FAIL", label, vim.inspect(got), vim.inspect(want)))
end

require("codereview").setup({})
local view = require("codereview.view")
local render = require("codereview.render")

view.open("branch")
local V = view.current()
check("view opened", V ~= nil, true)

local function dump(title)
  local lines = vim.api.nvim_buf_get_lines(V.buf, 0, -1, false)
  print(("\n===== %s (%d rows) ====="):format(title, #lines))
  for i, l in ipairs(lines) do
    local a = V.render.anchors[i]
    print(("%3d %-6s %s"):format(i, a and a.kind or "-", l))
  end
end

dump("branch scope")

--- structure -------------------------------------------------------------------
check("file_rows count == files", #V.render.file_rows, #V.files)
check("every file_row anchors to its file", (function()
  for fi, row in ipairs(V.render.file_rows) do
    if not V.render.anchors[row] or V.render.anchors[row].file ~= fi or V.render.anchors[row].kind ~= "file" then
      return fi
    end
  end
  return true
end)(), true)

check("hunk_rows all anchor to hunks", (function()
  for _, row in ipairs(V.render.hunk_rows) do
    if V.render.anchors[row].kind ~= "hunk" then
      return row
    end
  end
  return true
end)(), true)

-- Every "line" anchor must point at a real CRLine, and its recorded byte column must be
-- exactly where the code text starts in the rendered row.
check("line anchors resolve and cols are right", (function()
  local lines = vim.api.nvim_buf_get_lines(V.buf, 0, -1, false)
  for row, a in pairs(V.render.anchors) do
    if a.kind == "line" then
      local ln = V.files[a.file].hunks[a.hunk].lines[a.line]
      if not ln then
        return ("row %d: no CRLine"):format(row)
      end
      if lines[row]:sub(a.col + 1) ~= ln.text then
        return ("row %d: col %d gives %q want %q"):format(row, a.col, lines[row]:sub(a.col + 1), ln.text)
      end
    end
  end
  return true
end)(), true)

--- navigation ------------------------------------------------------------------
vim.api.nvim_win_set_cursor(V.win, { 1, 0 })
view.jump("file", true)
check("]f moves to 2nd file header", vim.api.nvim_win_get_cursor(V.win)[1], V.render.file_rows[2])
view.jump("file", false)
check("[f returns to 1st", vim.api.nvim_win_get_cursor(V.win)[1], V.render.file_rows[1])
view.jump("hunk", true)
check("]h lands on a hunk header", V.render.anchors[vim.api.nvim_win_get_cursor(V.win)[1]].kind, "hunk")

--- collapse --------------------------------------------------------------------
local rows_before = #V.render.lines
-- Park on the largest file so collapsing it is unmistakable.
local biggest, bi = 0, 1
for i, f in ipairs(V.files) do
  if #f.hunks > 0 and (f.added + f.removed) > biggest then
    biggest, bi = f.added + f.removed, i
  end
end
vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[bi], 0 })
local target = V.files[bi].path
view.toggle_reviewed()
check("marking reviewed records the blob", V.reviewed[target], V.files[bi].blob)
check("marking reviewed collapses (fewer rows)", #V.render.lines < rows_before, true)
check("cursor parked on that file's header", vim.api.nvim_win_get_cursor(V.win)[1], V.render.file_rows[bi])
check("collapsed file emits no line anchors", (function()
  for _, a in pairs(V.render.anchors) do
    if a.file == bi and a.kind == "line" then
      return false
    end
  end
  return true
end)(), true)
dump("after marking " .. target .. " reviewed")

view.toggle_reviewed()
check("unmarking restores rows", #V.render.lines, rows_before)
check("unmarking clears the blob", V.reviewed[target], nil)

--- panel -----------------------------------------------------------------------
check("panel window exists", V.panel_win ~= nil and vim.api.nvim_win_is_valid(V.panel_win), true)
local plines = vim.api.nvim_buf_get_lines(V.panel_buf, 0, -1, false)
print("\n===== panel =====")
for i, l in ipairs(plines) do
  print(("%3d %s"):format(i, l))
end
check("panel last line is the tally", plines[#plines], ("0/%d reviewed"):format(#V.files))
check("panel row_file covers every file", vim.tbl_count(V.panel_render.row_file), #V.files)

--- scope cycling ---------------------------------------------------------------
local seen = {}
for _ = 1, 4 do
  view.set_scope(nil)
  seen[#seen + 1] = ("%s(%d files)"):format(view.current().scope.name, #view.current().files)
end
print("\nscope cycle: " .. table.concat(seen, " -> "))
check("cycle returns to branch after 4 steps", view.current().scope.name, "branch")

view.set_scope("staged")
check("staged scope selected", view.current().scope.name, "staged")
check("staged shows routes.ts only", vim.tbl_map(function(f)
  return f.path
end, view.current().files), { "src/routes.ts" })

view.set_scope("branch")

--- winbar ----------------------------------------------------------------------
print("\nwinbar: " .. vim.wo[V.win].winbar)
check("winbar names the scope", vim.wo[V.win].winbar:find("branch vs master", 1, true) ~= nil, true)

--- line_key --------------------------------------------------------------------
check("line_key sides differ for same number", {
  render.line_key("a.ts", { side = "del", old = 20 }),
  render.line_key("a.ts", { side = "add", new = 20 }),
}, { "a.ts:o:20", "a.ts:n:20" })

print(("\n%s  %d failure(s)"):format(fail == 0 and "ALL PASS" or "FAILURES", fail))
vim.cmd(fail == 0 and "qa!" or "cq")
