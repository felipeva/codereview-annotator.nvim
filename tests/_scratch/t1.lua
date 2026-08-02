-- Phase 1 check: git.lua + diff.lua against the fixture repo.
-- Repo root from this file's own location, so the suite runs from any clone.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

local git = require("codereview.git")
local diff = require("codereview.diff")

local ROOT = vim.env.FIXTURE
local fail = 0
local function check(label, got, want)
  local ok = vim.deep_equal(got, want)
  if not ok then
    fail = fail + 1
  end
  print(("%s %-46s got=%s want=%s"):format(ok and "ok  " or "FAIL", label, vim.inspect(got), vim.inspect(want)))
end

print("root = " .. tostring(git.root(ROOT)))
-- Compared against the canonical path: `git rev-parse --show-toplevel` resolves
-- symlinks, and on macOS /var is a symlink to /private/var.
check("root", git.root(ROOT), vim.uv.fs_realpath(ROOT))
check("default_branch", git.default_branch(ROOT), "master")
check("current_branch", git.current_branch(ROOT), "feature")

--- branch scope ---------------------------------------------------------------
local scope = assert(git.resolve_scope("branch", ROOT))
print("\n-- scope branch: " .. scope.label .. "  before=" .. scope.before .. " after=" .. tostring(scope.after))

local files = assert(git.collect(scope, ROOT))
local by = {}
for _, f in ipairs(files) do
  by[f.path] = f
end

local names = vim.tbl_keys(by)
table.sort(names)
print("\nfiles: " .. table.concat(names, ", "))

local function git_lines(args)
  local res = vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = ROOT }):wait()
  return vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true })
end

check(
  "file count = tracked + untracked",
  #files,
  #git_lines({ "diff", "--numstat", scope.before }) + #git_lines({ "ls-files", "--others", "--exclude-standard" })
)
check("gitignored file excluded", by["ignored.txt"], nil)

-- Cross-check every tracked file's counts against git itself rather than against
-- hand-arithmetic, which is exactly what went stale the first time this ran.
local numstat = vim.system({ "git", "diff", "--numstat", scope.before }, { text = true, cwd = ROOT }):wait()
for _, row in ipairs(vim.split(vim.trim(numstat.stdout), "\n", { trimempty = true })) do
  local add, del, path = row:match("^(%S+)\t(%S+)\t(.+)$")
  -- git renders a rename as `src/{old.ts => new.ts}`; take the post-image path.
  local pre, mid, post = path:match("^(.*){.* => (.*)}(.*)$")
  if pre then
    path = pre .. mid .. post
  end
  local f = by[path]
  if not f then
    check("numstat: " .. path .. " present", false, true)
  elseif add ~= "-" then
    check("numstat " .. path, { f.added, f.removed }, { tonumber(add), tonumber(del) })
  end
end

check("main.ts status", by["src/main.ts"].status, "M")
check("main.ts +/-", { by["src/main.ts"].added, by["src/main.ts"].removed }, { 1, 1 })

check("gone.ts status", by["src/gone.ts"].status, "D")
check("gone.ts +/-", { by["src/gone.ts"].added, by["src/gone.ts"].removed }, { 0, 1 })

check("fresh.ts status", by["src/fresh.ts"].status, "A")
check("newname.ts status", by["src/newname.ts"].status, "R")
check("newname.ts old_path", by["src/newname.ts"].old_path, "src/oldname.ts")

check("untracked.ts status", by["src/untracked.ts"].status, "U")
check("untracked.ts added", by["src/untracked.ts"].added, 2)
check("untracked.bin binary", by["src/untracked.bin"].binary, true)
check("untracked.bin note", by["src/untracked.bin"].note, "binary — not annotatable")

-- Both sides of nonl.ts lack a trailing newline, so the marker appears twice: once
-- mid-hunk and once after the final line, where the counters have already run out.
local nonl = by["src/nonl.ts"].hunks[1].lines
check("nonl.ts del no_newline", nonl[1].no_newline, true)
check("nonl.ts add no_newline (last line)", nonl[#nonl].no_newline, true)

-- Derived from numstat, not hand-arithmetic: tracked totals plus the untracked file's
-- 2 added lines, which numstat cannot see.
local want_a, want_r = 0, 0
for _, row in ipairs(vim.split(vim.trim(numstat.stdout), "\n", { trimempty = true })) do
  local add, del = row:match("^(%S+)\t(%S+)\t")
  if add ~= "-" then
    want_a, want_r = want_a + tonumber(add), want_r + tonumber(del)
  end
end
local a, r = diff.totals(files)
check("totals", { a, r }, { want_a + 2, want_r })

--- line numbering -------------------------------------------------------------
local h = by["src/main.ts"].hunks[1]
local shape = {}
for _, ln in ipairs(h.lines) do
  shape[#shape + 1] = ("%s/%s/%s:%s"):format(ln.side, tostring(ln.old), tostring(ln.new), ln.text)
end
print("\nmain.ts hunk " .. h.header)
print("  " .. table.concat(shape, "\n  "))
check("main.ts hunk line count", #h.lines, 4)
check("main.ts del line", { h.lines[2].side, h.lines[2].old, h.lines[2].new, h.lines[2].text }, {
  "del",
  2,
  nil,
  "const cfg = load()",
})
check("main.ts add line", { h.lines[3].side, h.lines[3].old, h.lines[3].new, h.lines[3].text }, {
  "add",
  nil,
  2,
  "const cfg = loadConfig()",
})
check("main.ts trailing ctx", { h.lines[4].side, h.lines[4].old, h.lines[4].new }, { "ctx", 3, 3 })

--- other scopes ---------------------------------------------------------------
for _, name in ipairs({ "staged", "unstaged", "worktree" }) do
  local s = assert(git.resolve_scope(name, ROOT))
  local fs = assert(git.collect(s, ROOT))
  local desc = {}
  for _, f in ipairs(fs) do
    desc[#desc + 1] = ("%s(%s +%d-%d)"):format(f.path, f.status, f.added, f.removed)
  end
  print(("\n-- %-9s before=%-8s after=%-8s : %s"):format(name, s.before, tostring(s.after), table.concat(desc, " ")))
end

check("staged sees only routes.ts", (function()
  local fs = assert(git.collect(assert(git.resolve_scope("staged", ROOT)), ROOT))
  return { #fs, fs[1].path, fs[1].added }
end)(), { 1, "src/routes.ts", 1 })

check("unstaged sees only routes.ts", (function()
  local fs = assert(git.collect(assert(git.resolve_scope("unstaged", ROOT)), ROOT))
  return { #fs, fs[1].path, fs[1].added }
end)(), { 1, "src/routes.ts", 1 })

--- revspecs -------------------------------------------------------------------
for _, spec in ipairs({ "HEAD~1", "master...feature", "master..feature", "nonsense-ref" }) do
  local s, err = git.resolve_scope(spec, ROOT)
  print(("\n-- revspec %-18s -> %s"):format(spec, s and ("before=" .. s.before .. " after=" .. tostring(s.after)) or ("ERR " .. err)))
end
check("bad revspec rejected", (select(1, git.resolve_scope("nonsense-ref", ROOT))), nil)

--- file content + blob --------------------------------------------------------
check("file_content worktree", git.file_content("src/main.ts", nil, ROOT), "const app = express()\nconst cfg = loadConfig()\napp.listen(cfg.port)\n")
check("file_content at base", git.file_content("src/main.ts", scope.before, ROOT), "const app = express()\nconst cfg = load()\napp.listen(cfg.port)\n")
check("file_content missing path is nil", git.file_content("src/fresh.ts", scope.before, ROOT), nil)
check("blob is a sha", (by["src/main.ts"].blob or ""):match("^%x%x%x%x%x%x%x+$") ~= nil, true)
check("deleted file has a blob", (by["src/gone.ts"].blob or ""):match("^%x+$") ~= nil, true)

print(("\n%s  %d failure(s)"):format(fail == 0 and "ALL PASS" or "FAILURES", fail))
vim.cmd(fail == 0 and "qa" or "cq")
