-- The **base branch**: the branch a **branch** scope is measured from.
--
-- Three seams. Scope resolution, with the base branch set through the state setter, as
-- `trim_spec` sets a trim through `set_trim`. The review view, through `:CodeReviewBase`, which
-- is what stores, refuses and draws again. And a second process, for what reaches the disk.
--
-- Every `before` and `identity` is read against git's own `merge-base` answer for the same
-- question, never against a value worked out here the way the code works it out.
--
-- The fixture is `mkstack`: `child` forked from `feat/A` forked from master, and an
-- `origin/feat/A` one commit behind the local `feat/A`. Its three merge bases with `child` are
-- three different commits, and the first block says so, because a test whose pre-state already
-- looks like the result cannot fail.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkstack")
local root = assert(vim.uv.fs_realpath(fixture))

local codereview = require("codereview")
local git = require("codereview.git")
local state = require("codereview.state")
local view = require("codereview.view")

codereview.setup({ syntax = false, send = function() end })

---git's own merge base of `ref` and `HEAD`, in `dir`.
---@param ref string
---@param dir? string
---@return string
local function merge_base(ref, dir)
  return assert(h.git_lines(dir or fixture, { "merge-base", ref, "HEAD" })[1], "no merge base with " .. ref)
end

---@param dir string
---@param args string[]
local function git_at(dir, args)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = dir, text = true }):wait(60000)
  assert(res.code == 0, table.concat(args, " ") .. ": " .. (res.stderr or ""))
end

---@return CRView
local function current()
  return assert(view.current(), "no review view open")
end

---@param files CRFile[]
---@return string[]
local function paths(files)
  return vim.tbl_map(function(f)
    return f.path
  end, files)
end

---What the checkout's state document holds for each branch.
---@param dir string
---@return table<string, string>
local function stored(dir)
  return state.load(dir).base_branches or {}
end

---How many of `msgs` hold `needle`.
---@param msgs string[]
---@param needle string
---@return integer
local function count(msgs, needle)
  local n = 0
  for _, msg in ipairs(msgs) do
    if type(msg) == "string" and msg:find(needle, 1, true) then
      n = n + 1
    end
  end
  return n
end

---Resolve the branch scope of `dir`, and what it said while it did.
---@param dir string
---@return CRScope|nil scope, string[] msgs, string|nil err
local function resolve_told(dir)
  local msgs, restore = h.capture_notify()
  local scope, err = git.resolve_scope("branch", dir)
  restore()
  return scope, msgs, err
end

local DROPPED = "was dropped"
local DEFAULT = "origin/master"

describe("the stacked fixture", function()
  it("gives three different merge bases for the default branch, origin/feat/A and feat/A", function()
    local d, r, l = merge_base(DEFAULT), merge_base("origin/feat/A"), merge_base("feat/A")
    assert.are_not.equal(d, r)
    assert.are_not.equal(d, l)
    assert.are_not.equal(r, l)
  end)

  it("reads origin/master as the default branch", function()
    assert.equal(DEFAULT, git.default_branch(root))
  end)
end)

describe("a branch with no stored base branch", function()
  local scope = assert(git.resolve_scope("branch", root))

  it("has nothing in the store", function()
    assert.is_nil(state.base_branch(root))
  end)

  it("is measured from the default branch, as before", function()
    assert.equal(merge_base(DEFAULT), scope.before)
    assert.equal(merge_base(DEFAULT), scope.identity)
    assert.equal("branch vs origin/master", scope.label)
  end)
end)

describe("feat/A stored on child", function()
  state.set_base_branch(root, "feat/A")
  local scope, msgs = resolve_told(root)
  assert(scope)

  it("has a merge base that descends from the default branch's, and is not the same", function()
    assert.are_not.equal(merge_base(DEFAULT), merge_base("feat/A"))
    local res = vim
      .system({ "git", "merge-base", "--is-ancestor", merge_base(DEFAULT), (merge_base("feat/A")) }, { cwd = fixture })
      :wait()
    assert.equal(0, res.code)
  end)

  it("passes the check: it stays in the store, and nothing is said", function()
    assert.equal("feat/A", stored(root).child)
    assert.equal(0, count(msgs, DROPPED), vim.inspect(msgs))
  end)

  it("is measured from the merge base with feat/A", function()
    assert.equal(merge_base("feat/A"), scope.before)
    assert.equal(merge_base("feat/A"), scope.identity)
  end)

  it("names feat/A on the label", function()
    assert.equal("branch vs feat/A", scope.label)
  end)

  it("holds only child's own commit", function()
    assert.same({ "k1.txt" }, paths(assert(git.collect(scope, root, {}))))
  end)
end)

describe("a remote-tracking ref stored", function()
  state.set_base_branch(root, "origin/feat/A")
  local scope = assert(git.resolve_scope("branch", root))

  it("is used as stored, and not as the local branch of that name", function()
    assert.equal(merge_base("origin/feat/A"), scope.before)
    assert.equal(merge_base("origin/feat/A"), scope.identity)
    assert.are_not.equal(merge_base("feat/A"), scope.before)
    assert.equal("branch vs origin/feat/A", scope.label)
  end)
end)

describe("the default marker stored", function()
  state.set_base_branch(root, state.DEFAULT_BASE_BRANCH)
  local scope, msgs = resolve_told(root)
  assert(scope)

  it("is measured from the default branch", function()
    assert.equal(merge_base(DEFAULT), scope.before)
    assert.equal("branch vs origin/master", scope.label)
  end)

  it("is not checked: it stays in the store, and nothing is said", function()
    assert.equal(state.DEFAULT_BASE_BRANCH, stored(root).child)
    assert.equal(0, count(msgs, DROPPED), vim.inspect(msgs))
  end)
end)

describe("a stored base branch whose merge base is the default branch's", function()
  state.set_base_branch(root, "master")
  local scope, msgs = resolve_told(root)
  assert(scope)

  it("has the same merge base as the default branch", function()
    assert.equal(merge_base(DEFAULT), merge_base("master"))
  end)

  it("is kept and used, and nothing is said", function()
    assert.equal("master", stored(root).child)
    assert.equal("branch vs master", scope.label)
    assert.equal(0, count(msgs, DROPPED), vim.inspect(msgs))
  end)
end)

describe("a stored base branch that merged this branch in", function()
  git_at(fixture, { "checkout", "-q", "-b", "up", "feat/A" })
  git_at(fixture, { "merge", "-q", "--no-ff", "-m", "merge child", "child" })
  git_at(fixture, { "checkout", "-q", "child" })
  state.set_base_branch(root, "up")
  local scope, msgs = resolve_told(root)
  assert(scope)

  it("has HEAD as its merge base", function()
    assert.equal(h.git_lines(fixture, { "rev-parse", "HEAD" })[1], merge_base("up"))
  end)

  it("is kept and used, and nothing is said", function()
    assert.equal("up", stored(root).child)
    assert.equal("branch vs up", scope.label)
    assert.equal(0, count(msgs, DROPPED), vim.inspect(msgs))
  end)

  it("gives an empty review", function()
    assert.same({}, paths(assert(git.collect(scope, root, {}))))
  end)
end)

describe("a stored base branch that no longer resolves", function()
  git_at(fixture, { "branch", "gone", "feat/A" })
  state.set_base_branch(root, "gone")
  git_at(fixture, { "branch", "-D", "-q", "gone" })
  local before_doc = stored(root).child
  local scope, msgs, err = resolve_told(root)

  it("was in the store before the resolve", function()
    assert.equal("gone", before_doc)
  end)

  it("falls back to the default branch, so the review still opens", function()
    assert.is_not_nil(scope, err)
    assert.equal(merge_base(DEFAULT), scope.before)
    assert.equal("branch vs origin/master", scope.label)
  end)

  it("is dropped from the store", function()
    assert.is_nil(stored(root).child)
  end)

  it("says so once, naming it", function()
    assert.equal(1, count(msgs, "The base branch gone was dropped"), vim.inspect(msgs))
  end)

  it("says nothing on the next resolve", function()
    local _, again = resolve_told(root)
    assert.equal(0, count(again, DROPPED), vim.inspect(again))
  end)
end)

state.set_base_branch(root, nil)

--- The command ----------------------------------------------------------------------

describe(":CodeReviewBase with a branch review open", function()
  assert(view.open("branch"), "the branch review did not open")
  local before_store = current().scope.before
  vim.cmd("CodeReviewBase feat/A")

  it("was on the default branch before the store", function()
    assert.equal(merge_base(DEFAULT), before_store)
  end)

  it("draws the review again from the merge base with feat/A", function()
    assert.equal(merge_base("feat/A"), current().scope.before)
    assert.same({ "k1.txt" }, paths(current().files))
  end)

  it("names feat/A on the winbar", function()
    assert.is_truthy(h.winbar(current().win):find("branch vs feat/A", 1, true), h.winbar(current().win))
  end)

  it("stores it in the checkout's state document, under the branch", function()
    assert.equal("feat/A", stored(root).child)
  end)

  it("writes nothing to git config", function()
    assert.same({}, h.git_lines(fixture, { "config", "--get-regexp", "^branch\\." }))
  end)
end)

describe(":CodeReviewBase with an unknown ref", function()
  local msgs, restore = h.capture_notify()
  vim.cmd("CodeReviewBase no-such-branch")
  restore()

  it("reports the error", function()
    assert.is_true(h.notified(msgs, "no-such-branch"), vim.inspect(msgs))
  end)

  it("stores nothing", function()
    assert.equal("feat/A", stored(root).child)
  end)

  it("leaves the review as it was", function()
    assert.equal(merge_base("feat/A"), current().scope.before)
  end)
end)

describe(":CodeReviewBase with no argument", function()
  local msgs, restore = h.capture_notify()
  vim.cmd("CodeReviewBase")
  restore()

  it("reports the usage and stores nothing", function()
    assert.is_true(h.notified(msgs, "Usage"), vim.inspect(msgs))
    assert.equal("feat/A", stored(root).child)
  end)
end)

describe("reviewed marks under a base branch", function()
  local key = "branch:" .. merge_base("feat/A")
  view.mark_reviewed(assert(h.file_index(current(), "k1.txt")))

  it("are keyed by the merge base", function()
    assert.is_not_nil(current().per_scope[key], vim.inspect(vim.tbl_keys(current().per_scope)))
    assert.is_not_nil(current().per_scope[key].reviewed["k1.txt"])
  end)

  it("are not the marks of another base branch", function()
    vim.cmd("CodeReviewBase " .. DEFAULT)
    assert.is_nil(current().reviewed["k1.txt"])
  end)

  it("come back when that base branch is stored again", function()
    vim.cmd("CodeReviewBase feat/A")
    assert.is_not_nil(current().reviewed["k1.txt"])
  end)
end)

describe(":CodeReviewBase with the default branch", function()
  vim.cmd("CodeReviewBase " .. DEFAULT)

  it("stores the explicit default marker, and does not clear the entry", function()
    assert.equal(state.DEFAULT_BASE_BRANCH, stored(root).child)
    assert.equal(state.DEFAULT_BASE_BRANCH, state.base_branch(root))
  end)

  it("reads the review from the default branch", function()
    assert.equal(merge_base(DEFAULT), current().scope.before)
    assert.is_truthy(h.winbar(current().win):find("branch vs origin/master", 1, true), h.winbar(current().win))
  end)
end)

describe("two branches", function()
  vim.cmd("CodeReviewBase feat/A")
  git_at(fixture, { "checkout", "-q", "feat/A" })
  view.set_scope("branch")
  vim.cmd("CodeReviewBase origin/feat/A")

  it("keep their own base branch in the store", function()
    assert.equal("feat/A", stored(root).child)
    assert.equal("origin/feat/A", stored(root)["feat/A"])
  end)

  it("are each measured from their own", function()
    assert.equal(merge_base("origin/feat/A"), current().scope.before)
    git_at(fixture, { "checkout", "-q", "child" })
    view.set_scope("branch")
    assert.equal(merge_base("feat/A"), current().scope.before)
  end)
end)

describe("a review on another scope", function()
  view.set_scope("worktree")
  vim.cmd("CodeReviewBase origin/feat/A")

  it("stays on that scope", function()
    assert.equal("worktree", current().scope.name)
  end)

  it("still stores the base branch", function()
    assert.equal("origin/feat/A", stored(root).child)
  end)
end)

vim.cmd("CodeReviewBase feat/A")
codereview.close()

describe(":CodeReviewBase with no review open", function()
  vim.cmd("CodeReviewBase origin/feat/A")

  it("stores for the checkout of the working directory", function()
    assert.equal("origin/feat/A", stored(root).child)
  end)
end)

vim.cmd("CodeReviewBase feat/A")

--- A switch (ADR-0008) ---------------------------------------------------------------

-- A second checkout of the same repository, on a branch of its own forked from child. Its
-- branch name is in no other document, so a read from the wrong checkout gives the default.
local other = vim.fn.tempname() .. "-other"
git_at(fixture, { "worktree", "add", "-q", "-b", "side", other, "child" })
other = assert(vim.uv.fs_realpath(other))
state.set_base_branch(other, "origin/feat/A")

describe("a review switched to another checkout", function()
  assert(view.open(nil, other), "the review did not open on the other checkout")

  it("reads that checkout's base branch", function()
    assert.equal(other, current().root)
    assert.equal(merge_base("origin/feat/A", other), current().scope.before)
    assert.equal("branch vs origin/feat/A", current().scope.label)
  end)

  -- The working directory is still the first checkout, on child: a command that read it would
  -- store under child there and draw nothing new here.
  vim.cmd("CodeReviewBase feat/A")

  it("stores a command's base branch in that checkout, under its branch", function()
    assert.equal("feat/A", stored(other).side)
    assert.is_nil(stored(root).side)
    assert.equal("feat/A", stored(root).child)
  end)

  it("draws that checkout's review again", function()
    assert.equal(merge_base("feat/A", other), current().scope.before)
  end)
end)

codereview.close()

--- A detached HEAD ------------------------------------------------------------------

---Run a Neovim of its own over a fixture, sharing this process's throwaway
---`XDG_STATE_HOME` and nothing else.
---@param dir string
---@param mode "write"|"read"
---@return vim.SystemCompleted
local function spawn(dir, mode)
  return vim
    .system({
      vim.v.progpath,
      "--clean",
      "-l",
      vim.fs.joinpath(h.root, "tests", "codereview", "base_branch_child.lua"),
    }, {
      cwd = dir,
      text = true,
      env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = dir, MODE = mode },
    })
    :wait(60000)
end

describe("a base branch stored on a detached HEAD", function()
  git_at(fixture, { "checkout", "-q", "--detach", "child" })
  assert(view.open("branch"), "the branch review did not open")
  local before_doc = vim.deepcopy(stored(root))

  local msgs, restore = h.capture_notify()
  vim.cmd("CodeReviewBase origin/feat/A")
  restore()

  it("is used for the session", function()
    assert.equal(merge_base("origin/feat/A"), current().scope.before)
  end)

  it("says it is not kept", function()
    assert.is_true(h.notified(msgs, "not kept"), vim.inspect(msgs))
  end)

  it("says it once, and not again on the next store", function()
    local again, stop = h.capture_notify()
    vim.cmd("CodeReviewBase feat/A")
    stop()
    assert.is_false(h.notified(again, "not kept"), vim.inspect(again))
    assert.equal(merge_base("feat/A"), current().scope.before)
  end)

  it("reaches no document", function()
    assert.same(before_doc, stored(root))
  end)

  local reader = spawn(fixture, "read")

  it("is gone in the session after it", function()
    local out = (reader.stdout or "") .. (reader.stderr or "")
    assert.equal(0, reader.code, out)
    assert.is_truthy(out:find("label: branch vs origin/master", 1, true), out)
    assert.is_truthy(out:find("before: " .. merge_base(DEFAULT), 1, true), out)
  end)

  it("never became the base branch of the branch checked out after it", function()
    git_at(fixture, { "checkout", "-q", "child" })
    view.set_scope("branch")
    assert.equal("feat/A", stored(root).child)
    assert.equal(merge_base("feat/A"), current().scope.before)
  end)
end)

codereview.close()

--- After a restart -------------------------------------------------------------------

-- A fresh copy of the fixture: nothing this process did above may answer for what the
-- process before it stored.
local kept = h.fixture("mkstack")
local kept_root = assert(vim.uv.fs_realpath(kept))
local writer = spawn(kept, "write")

describe("base branches stored in the session before", function()
  it("the writing process exits cleanly", function()
    assert.equal(0, writer.code, (writer.stderr or "") .. (writer.stdout or ""))
  end)

  it("are still in use on child", function()
    local scope = assert(git.resolve_scope("branch", kept_root))
    assert.equal(merge_base("feat/A", kept), scope.before)
    assert.equal("branch vs feat/A", scope.label)
  end)

  it("are still in use on feat/A, which keeps its own", function()
    git_at(kept, { "checkout", "-q", "feat/A" })
    local scope = assert(git.resolve_scope("branch", kept_root))
    assert.equal(merge_base("origin/feat/A", kept), scope.before)
    assert.equal("branch vs origin/feat/A", scope.label)
    git_at(kept, { "checkout", "-q", "child" })
  end)
end)

--- The squash trap ------------------------------------------------------------------

-- A copy in which feat/A has landed: squash-merged into master, child rebased onto master, the
-- local feat/A kept and origin/feat/A never pruned. Both refs still resolve, so only the check
-- on the two merge bases can reject them.
local sq = h.fixture("mkstack", "squash")
local sq_root = assert(vim.uv.fs_realpath(sq))
local squash = h.git_lines(sq, { "rev-parse", "master" })[1]

---@param args string[]
---@return string[]
local function names(args)
  return h.git_lines(sq, vim.list_extend({ "diff", "--name-only" }, args))
end

describe("the squash copy", function()
  local d, l, r = merge_base(DEFAULT, sq), merge_base("feat/A", sq), merge_base("origin/feat/A", sq)

  it("has child one commit above the default branch", function()
    assert.equal("1", h.git_lines(sq, { "rev-list", "--count", DEFAULT .. "..HEAD" })[1])
  end)

  it("gives merge bases with feat/A and origin/feat/A strictly behind the default branch's", function()
    assert.are_not.equal(d, l)
    assert.are_not.equal(d, r)
    for _, mb in ipairs({ l, r }) do
      assert.equal(0, vim.system({ "git", "merge-base", "--is-ancestor", mb, d }, { cwd = sq }):wait().code)
    end
  end)

  it("keeps origin/feat/A stale, behind the local feat/A", function()
    assert.are_not.equal(
      h.git_lines(sq, { "rev-parse", "feat/A" })[1],
      h.git_lines(sq, { "rev-parse", "origin/feat/A" })[1]
    )
  end)

  it("reads the squash commit as work of child when measured from feat/A", function()
    assert.same({ "a1.txt", "a2.txt", "k1.txt" }, names({ l, "HEAD" }))
    assert.same({ "k1.txt" }, names({ d, "HEAD" }))
  end)
end)

for _, ref in ipairs({ "feat/A", "origin/feat/A" }) do
  describe(ref .. " stored in the squash copy", function()
    state.set_base_branch(sq_root, ref)
    local before_doc = (state.load(sq_root).base_branches or {}).child
    local scope, msgs, err = resolve_told(sq_root)

    it("was in the store before the resolve", function()
      assert.equal(ref, before_doc)
    end)

    it("is measured from the default branch", function()
      assert.is_not_nil(scope, err)
      assert.equal(merge_base(DEFAULT, sq), scope.before)
      assert.equal("branch vs origin/master", scope.label)
      assert.same({ "k1.txt" }, paths(assert(git.collect(scope, sq_root, {}))))
    end)

    it("is dropped from the store", function()
      assert.is_nil((state.load(sq_root).base_branches or {}).child)
    end)

    it("says so once, naming it and the default branch", function()
      assert.equal(1, count(msgs, ("The base branch %s was dropped"):format(ref)), vim.inspect(msgs))
      assert.equal(1, count(msgs, "more of this branch than origin/master"), vim.inspect(msgs))
    end)

    it("says nothing on the next resolve", function()
      local _, again = resolve_told(sq_root)
      assert.equal(0, count(again, DROPPED), vim.inspect(again))
    end)
  end)
end

describe("a trim made under feat/A, in the squash copy", function()
  -- The squash commit taken out: what a reviewer trims when feat/A reads it as branch work.
  -- Still an ancestor of HEAD, so only the change of base branch can drop the trim.
  state.set_base_branch(sq_root, "feat/A")
  state.set_trim(sq_root, { squash }, "feat/A")
  local before_trim = (state.load(sq_root).trims or {}).child
  local scope, msgs = resolve_told(sq_root)

  it("was in the store before the resolve", function()
    assert.same({ skipped = { squash }, base_branch = "feat/A" }, before_trim)
  end)

  it("is dropped with the base branch, and each is said once", function()
    assert.equal(1, count(msgs, "The base branch feat/A was dropped"), vim.inspect(msgs))
    assert.equal(1, count(msgs, "The trim was lost"), vim.inspect(msgs))
    assert.is_nil((state.load(sq_root).trims or {}).child)
    assert.is_nil((state.load(sq_root).base_branches or {}).child)
  end)

  it("leaves the whole branch, from the default branch", function()
    assert.equal(merge_base(DEFAULT, sq), assert(scope).before)
    assert.equal("branch vs origin/master", scope.label)
  end)

  it("says neither again on the next resolve", function()
    local _, again = resolve_told(sq_root)
    assert.equal(0, count(again, DROPPED), vim.inspect(again))
    assert.equal(0, count(again, "The trim was lost"), vim.inspect(again))
  end)
end)

describe("a review opened on the squash copy with feat/A stored", function()
  state.set_base_branch(sq_root, "feat/A")
  local msgs, restore = h.capture_notify()
  assert(view.open("branch", sq_root), "the branch review did not open")
  view.set_scope("branch")
  restore()

  it("opens from the default branch, and the winbar says so", function()
    assert.equal(merge_base(DEFAULT, sq), current().scope.before)
    assert.same({ "k1.txt" }, paths(current().files))
    assert.is_truthy(h.winbar(current().win):find("branch vs origin/master", 1, true), h.winbar(current().win))
  end)

  it("says it once over an open and a redraw", function()
    assert.equal(1, count(msgs, DROPPED), vim.inspect(msgs))
  end)
end)

codereview.close()

describe("a base branch of the session on a detached HEAD, in the squash copy", function()
  git_at(sq, { "checkout", "-q", "--detach", "child" })
  state.set_base_branch(sq_root, "feat/A")
  local held = state.base_branch(sq_root)
  local scope, msgs = resolve_told(sq_root)

  it("was held for the session", function()
    assert.equal("feat/A", held)
  end)

  it("follows the same check: dropped, and said once", function()
    assert.equal(merge_base(DEFAULT, sq), assert(scope).before)
    assert.is_nil(state.base_branch(sq_root))
    assert.equal(1, count(msgs, "The base branch feat/A was dropped"), vim.inspect(msgs))
    local _, again = resolve_told(sq_root)
    assert.equal(0, count(again, DROPPED), vim.inspect(again))
  end)

  git_at(sq, { "checkout", "-q", "child" })
end)
