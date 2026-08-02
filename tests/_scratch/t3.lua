-- Phase 3 check: treesitter harvest/replay.
-- Repo root from this file's own location, so the suite runs from any clone.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
-- nvim-treesitter supplies the `highlights` query for typescript; the parsers themselves
-- live under site/parser, which is already on the default runtimepath.
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

local syntax = require("codereview.syntax")
check("lang_for(.ts)", syntax.lang_for("src/main.ts"), "typescript")
check("lang_for(.lua)", syntax.lang_for("x/y.lua"), "lua")
check("lang_for(unknown ext)", syntax.lang_for("a/b.zzzz"), nil)
-- Rust has a filetype but no parser installed here: lang_for must not claim it, or every
-- .rs file pays for a file read and a doomed parse.
check("lang_for(filetype without a parser)", syntax.lang_for("a/b.rs"), nil)
check("lang_for(go, no parser)", syntax.lang_for("a/b.go"), nil)

require("codereview").setup({})
local view = require("codereview.view")
view.open("branch")
local V = view.current()

local NS = vim.api.nvim_create_namespace("codereview")
local all = vim.api.nvim_buf_get_extmarks(V.buf, NS, 0, -1, { details = true })
local syn = vim.tbl_filter(function(m)
  return m[4].priority == require("codereview.render").PRIORITY.syntax
end, all)
print(("\nextmarks: %d total, %d syntax"):format(#all, #syn))
check("syntax marks were produced", #syn > 0, true)

--- The load-bearing check: does every syntax extmark cover exactly the token it came
--- from? This validates parse -> capture -> anchor -> byte-column in one shot.
local buf_lines = vim.api.nvim_buf_get_lines(V.buf, 0, -1, false)
local mismatched, sampled = 0, {}
for _, m in ipairs(syn) do
  local row, col, ec = m[2], m[3], m[4].end_col
  local text = buf_lines[row + 1]:sub(col + 1, ec)
  local anchor = V.render.anchors[row + 1]
  if anchor and anchor.kind == "line" then
    local ln = V.files[anchor.file].hunks[anchor.hunk].lines[anchor.line]
    -- The covered bytes must lie inside the code text, never over the gutter.
    if col < anchor.col or text == "" or not ln.text:find(text, 1, true) then
      mismatched = mismatched + 1
      if mismatched <= 5 then
        print(("  MISMATCH row=%d col=%d text=%q not in %q"):format(row + 1, col, text, ln.text))
      end
    elseif #sampled < 8 then
      sampled[#sampled + 1] = ("%q=%s"):format(text, m[4].hl_group)
    end
  end
end
check("every syntax mark covers real token text", mismatched, 0)
print("sample: " .. table.concat(sampled, "  "))

--- Groups must resolve to something a colorscheme can colour.
local groups = {}
for _, m in ipairs(syn) do
  groups[m[4].hl_group] = (groups[m[4].hl_group] or 0) + 1
end
local names = vim.tbl_keys(groups)
table.sort(names)
print("\ngroups: " .. table.concat(vim.tbl_map(function(n)
  return ("%s(%d)"):format(n, groups[n])
end, names), " "))
check("uses @-prefixed treesitter groups", vim.tbl_isempty(vim.tbl_filter(function(n)
  return n:sub(1, 1) ~= "@"
end, names)), true)

--- Deleted lines come from the pre-image parse, added lines from the post-image.
local del_marked, add_marked = false, false
for _, m in ipairs(syn) do
  local a = V.render.anchors[m[2] + 1]
  if a and a.kind == "line" then
    local side = V.files[a.file].hunks[a.hunk].lines[a.line].side
    del_marked = del_marked or side == "del"
    add_marked = add_marked or side == "add"
  end
end
check("added lines highlighted (post-image parse)", add_marked, true)
check("deleted lines highlighted (pre-image parse)", del_marked, true)

--- Caching + laziness --------------------------------------------------------
local keys_before = vim.tbl_count(V.syntax_cache)
print("\ncache keys after first paint: " .. keys_before .. " -> " .. vim.inspect(vim.tbl_keys(V.syntax_cache)))
check("cache populated", keys_before > 0, true)
check("binary file never cached", V.syntax_cache["src/untracked.bin|after"], nil)

-- Reviewing a file collapses it; a repaint must then do no syntax work for it, and the
-- memo must not be re-derived for anything else either.
local probe = "src/main.ts"
local fi
for i, f in ipairs(V.files) do
  if f.path == probe then
    fi = i
  end
end
V.syntax_cache = {}
vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[fi], 0 })
view.toggle_reviewed()
check("collapsed file is not parsed", V.syntax_cache[probe .. "|after"], nil)
check("other files still parsed", V.syntax_cache["src/routes.ts|after"] ~= nil, true)

view.toggle_reviewed()
check("expanding parses it again", V.syntax_cache[probe .. "|after"] ~= nil, true)

--- Guardrails ----------------------------------------------------------------
require("codereview.config").setup({ max_syntax_bytes = 1 })
V.syntax_cache = {}
view.paint()
check("byte cap memoises a hard skip", V.syntax_cache["src/routes.ts|after"], false)
local after_cap = vim.tbl_filter(function(m)
  return m[4].priority == require("codereview.render").PRIORITY.syntax
end, vim.api.nvim_buf_get_extmarks(V.buf, NS, 0, -1, { details = true }))
check("no syntax marks when capped", #after_cap, 0)

require("codereview.config").setup({ syntax = false })
V.syntax_cache = {}
view.paint()
check("syntax=false does no work at all", vim.tbl_count(V.syntax_cache), 0)

print(("\n%s  %d failure(s)"):format(fail == 0 and "ALL PASS" or "FAILURES", fail))
vim.cmd(fail == 0 and "qa!" or "cq")
