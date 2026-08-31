-- git.lua + diff.lua against the flat fixture repo.
--
-- Counts are cross-checked against git itself rather than hardcoded. Hardcoded totals
-- went stale three times while this was being written, every time the fixture grew a file.
local h = require("tests.helpers")

local git = require("codereview.git")
local diff = require("codereview.diff")
local state = require("codereview.state")

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
end)

-- One process for every side the render path is about to parse. The claim is not that this
-- is faster -- timing lives in `perf.lua` -- but that it answers *the same thing* the
-- single-file fetch does, for every kind of side a review contains, because the render path
-- prefers it and falls back to the other one.
describe("reading many files in one batch", function()
  it("answers every side with what the single-file fetch answers", function()
    local items = {}
    -- A modification, a rename -- whose post-image name has no pre-image blob under that
    -- name at all -- and the file with no trailing newline, which is what catches a reader
    -- that ends a record where a line ends rather than where its declared length does.
    for _, path in ipairs({ "src/main.lua", "src/newname.lua", "src/nonl.md" }) do
      items[#items + 1] = { path = path, ref = scope.before }
    end
    local batched = git.file_contents(items, root)
    for _, it in ipairs(items) do
      local spec = git.spec(it.ref, it.path)
      local got = batched[spec]
      assert.is_not_nil(got, spec .. " was left uncovered by the batch")
      -- `false` is the batch's spelling of the nil the single-file fetch answers with. The
      -- two are the same answer; only the batch can afford to say it, which is the point.
      assert.same(git.file_content(it.path, it.ref, root), got or nil, spec)
    end
  end)

  -- `false`, not absent. Absent means "the batch did not cover this", which sends the
  -- caller back to a process per file; a side git has already said does not exist has been
  -- covered, and asking again buys the same nothing.
  it("answers false for a path that does not exist at that ref", function()
    local spec = git.spec(scope.before, "src/fresh.lua")
    assert.same(false, git.file_contents({ { path = "src/fresh.lua", ref = scope.before } }, root)[spec])
  end)

  it("leaves a working-tree side out: no ref, no blob to batch", function()
    assert.same({}, git.file_contents({ { path = "src/main.lua", ref = nil } }, root))
  end)

  it("takes the index as a ref like any other", function()
    local staged = assert(git.resolve_scope("staged", root))
    local spec = git.spec(staged.after, "src/routes.lua")
    local batched = git.file_contents({ { path = "src/routes.lua", ref = staged.after } }, root)
    assert.same(git.file_content("src/routes.lua", staged.after, root), batched[spec])
  end)

  -- The one case that cannot be answered from a batch at all: `cat-file` runs no textconv
  -- filter, so a path with one attached would come back as the raw bytes the filter exists
  -- to hide. It is left out instead, and its neighbour in the same repository is not --
  -- which is what says the rule is about the path rather than about the repository.
  describe("a repository with a textconv filter", function()
    local tc = h.fixture("mktextconv")
    local tc_scope = assert(git.resolve_scope("branch", tc))
    local batched = git.file_contents({
      { path = "src/filtered.bin", ref = tc_scope.before },
      { path = "src/plain.lua", ref = tc_scope.before },
    }, tc)

    it("leaves the filtered path out of the batch entirely", function()
      assert.is_nil(batched[git.spec(tc_scope.before, "src/filtered.bin")])
    end)

    -- Absent, so the caller fetches it the old way -- and that is what still runs the
    -- filter. Without this the exclusion would be indistinguishable from dropping the file.
    it("still reads the filtered path through the single-file fetch", function()
      -- Filtered, and the blob behind it says RAW: what a batch would have answered with is
      -- exactly what the filter is configured to hide.
      assert.same("COOKED one\nCOOKED two\n", git.file_content("src/filtered.bin", tc_scope.before, tc))
    end)

    it("still batches every other path in that repository", function()
      assert.same('local plain = "old"\n', batched[git.spec(tc_scope.before, "src/plain.lua")])
    end)
  end)
end)

describe("blobs", function()
  it("hashes every file to a blob", function()
    assert.is_truthy((by["src/main.lua"].blob or ""):match("^%x%x%x%x%x%x%x+$"))
  end)

  it("hashes a deleted file too, from its pre-image", function()
    assert.is_truthy((by["src/gone.lua"].blob or ""):match("^%x+$"))
  end)
end)

-- The scope that diffs the working tree against the newest snapshot in the archive.
--
-- A fixture of its own, because this one is dispatched from and *then* edited: the file
-- above is built once and read, and every count in it would move underneath the assertions
-- already made. Read top to bottom -- the empty-archive cases have to run before the
-- dispatch below them, which is the only state in which they mean anything.
describe("the since-batch scope", function()
  local repo = h.fixture("mkfixture")
  local repo_root = assert(vim.uv.fs_realpath(repo))

  it("is offered by name whether or not anything has been dispatched", function()
    assert.is_true(vim.tbl_contains(git.SCOPES, "since-batch"))
  end)

  it("reports a sentence rather than failing with an empty archive", function()
    local resolved, err = git.resolve_scope("since-batch", repo_root)
    assert.is_nil(resolved)
    assert.is_string(err)
  end)

  it("stays out of the cycle in a repository that has never dispatched", function()
    assert.is_false(vim.tbl_contains(git.cycle(repo_root), "since-batch"))
  end)

  -- The dispatch, through the write every dispatch goes through, and then the agent's
  -- answer to it: one tracked file changed *after* the batch went out.
  state.archive_batch({
    { id = 1, type = "bug", kind = "file", path = "src/main.lua", key = "src/main.lua:f:0", note = "have a look" },
  }, "agent", repo_root)
  local snapshot = assert(state.archive(repo_root)[1].snapshot, "the batch was archived without a snapshot")

  vim.fn.writefile({
    'local app = require("app")',
    "local cfg = load_config()",
    "cfg.validate()",
    "app.listen(cfg.port)",
  }, vim.fs.joinpath(repo, "src/main.lua"))

  local since = assert(git.resolve_scope("since-batch", repo_root))
  local since_files = assert(git.collect(since, repo_root))
  local paths = vim.tbl_map(function(f)
    return f.path
  end, since_files)
  local since_by = {}
  for _, f in ipairs(since_files) do
    since_by[f.path] = f
  end

  it("carries the newest snapshot as its before-image", function()
    assert.same({ "since-batch", snapshot }, { since.name, since.before })
  end)

  -- nil `after` means "the working tree", which is what the highlighter needs to know to
  -- read the post-image off disk rather than out of git.
  it("compares it against the working tree", function()
    assert.is_nil(since.after)
  end)

  it("joins the cycle once something has been dispatched", function()
    assert.is_true(vim.tbl_contains(git.cycle(repo_root), "since-batch"))
  end)

  -- Derived from git rather than hardcoded, as everything else in this file is: which
  -- files a snapshot differs from is a fact about the fixture, and hardcoded lists have
  -- gone stale in this repository before.
  it("collects exactly what git reports against the snapshot, untracked files included", function()
    local want = h.git_lines(repo, { "diff", "--name-only", snapshot })
    vim.list_extend(want, h.git_lines(repo, { "ls-files", "--others", "--exclude-standard" }))
    table.sort(want)
    assert.same(want, paths)
  end)

  it("shows the file that changed since the batch went", function()
    assert.same({ "M", 1, 0 }, {
      since_by["src/main.lua"].status,
      since_by["src/main.lua"].added,
      since_by["src/main.lua"].removed,
    })
  end)

  -- The point of the scope. `src/routes.lua` was dirty before the batch was dispatched and
  -- has not been touched since, so it is in the snapshot and not in this diff -- which the
  -- guard makes an assertion rather than a coincidence of an already-clean fixture.
  it("leaves out the work that was already in flight when the batch went", function()
    local uncommitted = h.git_lines(repo, { "diff", "--name-only", "HEAD" })
    assert.is_true(vim.tbl_contains(uncommitted, "src/routes.lua"), "nothing was in flight, so this proves nothing")
    assert.is_false(vim.tbl_contains(paths, "src/routes.lua"), vim.inspect(paths))
  end)

  -- Untracked at dispatch, so it is in no snapshot at all: it arrives through the same
  -- synthesis the branch and worktree scopes apply, not through a rule of its own.
  it("synthesises a file that was untracked when the batch went", function()
    assert.same({ "U", 2 }, { since_by["src/untracked.lua"].status, since_by["src/untracked.lua"].added })
  end)
end)
