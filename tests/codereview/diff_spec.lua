-- git.lua + diff.lua against the flat fixture repo.
--
-- Counts are cross-checked against git itself rather than hardcoded. Hardcoded totals
-- went stale three times while this was being written, every time the fixture grew a file.
local h = require("tests.helpers")

local git = require("codereview.git")
local diff = require("codereview.diff")

-- One fixture for the file. Nothing here mutates the repository, so rebuilding it per
-- describe only bought four `git init`s.
local root = h.fixture("mkfixture")
local scope = assert(git.resolve_scope("branch", root))
local files = assert(git.collect(scope, root))

local by = {}
for _, f in ipairs(files) do
  by[f.path] = f
end

describe("git scope resolution", function()
  it("resolves the repository root", function()
    -- Compared against the canonical path: `git rev-parse --show-toplevel` resolves
    -- symlinks, and on macOS /var is a symlink to /private/var.
    assert.same(vim.uv.fs_realpath(root), git.root(root))
  end)

  it("reads the default branch instead of assuming main", function()
    assert.same("master", git.default_branch(root))
  end)

  it("reports the current branch", function()
    assert.same("feature", git.current_branch(root))
  end)

  it("rejects a revspec that is not a revision", function()
    local scope, err = git.resolve_scope("nonsense-ref", root)
    assert.is_nil(scope)
    assert.is_string(err)
  end)

  it("resolves a bare revspec against the working tree", function()
    local scope = assert(git.resolve_scope("HEAD~1", root))
    assert.same("revspec", scope.name)
    assert.same("HEAD~1", scope.before)
    -- nil `after` means "the working tree", which is what the highlighter needs to know
    -- to read the post-image off disk rather than out of git.
    assert.is_nil(scope.after)
  end)

  it("resolves a three-dot revspec through the merge base", function()
    local scope = assert(git.resolve_scope("master...feature", root))
    assert.same(git.merge_base("master", "feature", root), scope.before)
    assert.same("feature", scope.after)
  end)

  it("resolves a two-dot revspec to its literal endpoints", function()
    local scope = assert(git.resolve_scope("master..feature", root))
    assert.same("master", scope.before)
    assert.same("feature", scope.after)
  end)
end)

describe("collecting a branch diff", function()
  local numstat = h.git_lines(root, { "diff", "--numstat", scope.before })

  it("collects every tracked and untracked file", function()
    assert.same(#numstat + #h.git_lines(root, { "ls-files", "--others", "--exclude-standard" }), #files)
  end)

  it("excludes gitignored files", function()
    assert.is_nil(by["ignored.txt"])
  end)

  -- Cross-check every tracked file's counts against git rather than against
  -- hand-arithmetic, which is exactly what went stale the first time this ran.
  for _, row in ipairs(numstat) do
    local add, del, path = row:match("^(%S+)\t(%S+)\t(.+)$")
    -- git renders a rename as `src/{old.lua => new.lua}`; take the post-image path.
    local pre, mid, post = path:match("^(.*){.* => (.*)}(.*)$")
    if pre then
      path = pre .. mid .. post
    end
    it(("matches git numstat for %s"):format(path), function()
      local f = by[path]
      assert.is_table(f)
      if add ~= "-" then
        assert.same({ tonumber(add), tonumber(del) }, { f.added, f.removed })
      end
    end)
  end

  it("totals additions and removals across the scope", function()
    local want_a, want_r = 0, 0
    for _, row in ipairs(numstat) do
      local add, del = row:match("^(%S+)\t(%S+)\t")
      if add ~= "-" then
        want_a, want_r = want_a + tonumber(add), want_r + tonumber(del)
      end
    end
    local added, removed = diff.totals(files)
    -- Plus the untracked file's 2 added lines, which numstat cannot see.
    assert.same({ want_a + 2, want_r }, { added, removed })
  end)

  it("classifies a modification", function()
    assert.same("M", by["src/main.lua"].status)
    assert.same({ 1, 1 }, { by["src/main.lua"].added, by["src/main.lua"].removed })
  end)

  it("classifies a deletion", function()
    assert.same("D", by["src/gone.lua"].status)
    assert.same({ 0, 1 }, { by["src/gone.lua"].added, by["src/gone.lua"].removed })
  end)

  it("classifies an addition", function()
    assert.same("A", by["src/fresh.lua"].status)
  end)

  it("classifies a rename and keeps the pre-image path", function()
    assert.same("R", by["src/newname.lua"].status)
    assert.same("src/oldname.lua", by["src/newname.lua"].old_path)
  end)

  it("classifies an untracked file as wholly added", function()
    assert.same("U", by["src/untracked.lua"].status)
    assert.same(2, by["src/untracked.lua"].added)
  end)

  it("marks an untracked binary as not annotatable", function()
    assert.is_true(by["src/untracked.bin"].binary)
    assert.same("binary — not annotatable", by["src/untracked.bin"].note)
  end)
end)

describe("parsing a unified diff", function()
  local hunk = by["src/main.lua"].hunks[1]

  it("renders context, deletion and addition as separate lines", function()
    assert.same(4, #hunk.lines)
  end)

  it("numbers a deleted line on the pre-image side only", function()
    local ln = hunk.lines[2]
    assert.same(
      { side = "del", old = 2, text = "local cfg = load()" },
      { side = ln.side, old = ln.old, new = ln.new, text = ln.text }
    )
  end)

  it("numbers an added line on the post-image side only", function()
    local ln = hunk.lines[3]
    assert.same(
      { side = "add", new = 2, text = "local cfg = load_config()" },
      { side = ln.side, old = ln.old, new = ln.new, text = ln.text }
    )
  end)

  it("numbers trailing context on both sides", function()
    local ln = hunk.lines[4]
    assert.same({ side = "ctx", old = 3, new = 3 }, { side = ln.side, old = ln.old, new = ln.new })
  end)

  -- Both sides of nonl.md lack a trailing newline, so the marker appears twice: once
  -- mid-hunk and once after the final line, where the line counters have already run out.
  -- A loop that stops on the counters alone drops the second one.
  it("records `\\ No newline at end of file` on both sides", function()
    local lines = by["src/nonl.md"].hunks[1].lines
    assert.is_true(lines[1].no_newline)
    assert.is_true(lines[#lines].no_newline)
  end)
end)

describe("narrower scopes", function()
  it("sees only the staged change in the staged scope", function()
    local files = assert(git.collect(assert(git.resolve_scope("staged", root)), root))
    assert.same({ 1, "src/routes.lua", 1 }, { #files, files[1].path, files[1].added })
  end)

  it("sees only the unstaged change in the unstaged scope", function()
    local files = assert(git.collect(assert(git.resolve_scope("unstaged", root)), root))
    assert.same({ 1, "src/routes.lua", 1 }, { #files, files[1].path, files[1].added })
  end)

  it("includes untracked files in the worktree scope", function()
    local scope = assert(git.resolve_scope("worktree", root))
    assert.is_true(scope.untracked)
    local paths = vim.tbl_map(function(f)
      return f.path
    end, assert(git.collect(scope, root)))
    assert.is_true(vim.tbl_contains(paths, "src/untracked.lua"))
  end)
end)

describe("reading file content and blobs", function()
  it("reads the working tree when no ref is given", function()
    assert.same(
      'local app = require("app")\nlocal cfg = load_config()\napp.listen(cfg.port)\n',
      git.file_content("src/main.lua", nil, root)
    )
  end)

  it("reads the pre-image at a ref", function()
    assert.same(
      'local app = require("app")\nlocal cfg = load()\napp.listen(cfg.port)\n',
      git.file_content("src/main.lua", scope.before, root)
    )
  end)

  it("returns nil for a path that does not exist at that ref", function()
    assert.is_nil(git.file_content("src/fresh.lua", scope.before, root))
  end)

  it("hashes every file to a blob", function()
    assert.is_truthy((by["src/main.lua"].blob or ""):match("^%x%x%x%x%x%x%x+$"))
  end)

  it("hashes a deleted file too, from its pre-image", function()
    assert.is_truthy((by["src/gone.lua"].blob or ""):match("^%x+$"))
  end)
end)
