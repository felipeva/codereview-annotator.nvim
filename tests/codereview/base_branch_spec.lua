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
  local scope = assert(git.resolve_scope("branch", root))

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
  local scope = assert(git.resolve_scope("branch", root))

  it("is measured from the default branch", function()
    assert.equal(merge_base(DEFAULT), scope.before)
    assert.equal("branch vs origin/master", scope.label)
  end)
end)

describe("a stored base branch that no longer resolves", function()
  git_at(fixture, { "branch", "gone", "feat/A" })
  state.set_base_branch(root, "gone")
  git_at(fixture, { "branch", "-D", "-q", "gone" })
  local scope, err = git.resolve_scope("branch", root)

  it("falls back to the default branch, so the review still opens", function()
    assert.is_not_nil(scope, err)
    assert.equal(merge_base(DEFAULT), scope.before)
    assert.equal("branch vs origin/master", scope.label)
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
