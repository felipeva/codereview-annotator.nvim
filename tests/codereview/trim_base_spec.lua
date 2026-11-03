-- A **trim** belongs to the **base branch** it was made under.
--
-- A trim is a selection out of the commits one base branch gives. Under another base branch the
-- same set is a selection the reviewer never made, so a change of base branch, from any cause,
-- drops it, and the reviewer is told once. A merge of the default branch moves the merge base
-- and changes no base branch, so a trim survives it.
--
-- The fixture is `mkstack`, with one more commit on `child` (k2), so that a trim under `feat/A`
-- can leave a commit in: `child` holds a1 a2 k1 k2 under the default branch and k1 k2 under
-- `feat/A`. Every `before` and `identity` is read against git's own answer.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkstack")
local root = assert(vim.uv.fs_realpath(fixture))

local codereview = require("codereview")
local git = require("codereview.git")
local state = require("codereview.state")
local view = require("codereview.view")

codereview.setup({ syntax = false, send = function() end })

---@param dir string
---@param args string[]
local function git_at(dir, args)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = dir, text = true }):wait(60000)
  assert(res.code == 0, table.concat(args, " ") .. ": " .. (res.stderr or ""))
end

---@param dir string
---@param name string
local function commit(dir, name)
  vim.fn.writefile({ name }, vim.fs.joinpath(dir, name .. ".txt"))
  git_at(dir, { "add", "-A" })
  git_at(dir, { "commit", "-qm", "feat: add " .. name })
end

---@param ref string
---@param dir? string
---@return string
local function sha(ref, dir)
  return assert(h.git_lines(dir or fixture, { "rev-parse", ref })[1])
end

---@param ref string
---@param dir? string
---@return string
local function merge_base(ref, dir)
  return assert(h.git_lines(dir or fixture, { "merge-base", ref, "HEAD" })[1], "no merge base with " .. ref)
end

---@return CRView
local function current()
  return assert(view.current(), "no review view open")
end

---How many of `msgs` say a trim was lost.
---@param msgs string[]
---@return integer
local function lost(msgs)
  local n = 0
  for _, msg in ipairs(msgs) do
    if msg:find("The trim was lost", 1, true) then
      n = n + 1
    end
  end
  return n
end

---What the checkout's state document holds for `branch`'s trim.
---@param dir string
---@param branch string
local function stored_trim(dir, branch)
  return (state.load(dir).trims or {})[branch]
end

---The rows of the commit list `gc` opens, and the float closed again.
---@return string[]
local function commit_list_rows()
  vim.api.nvim_set_current_win(current().win)
  view.commit_list()
  local win = vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_get_config(win).relative ~= "", "the commit list opened no float")
  local rows = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  vim.api.nvim_win_close(win, true)
  return rows
end

---@param rows string[]
---@param needle string
---@return string|nil row
local function row_with(rows, needle)
  for _, row in ipairs(rows) do
    if row:find(needle, 1, true) then
      return row
    end
  end
end

commit(fixture, "k2")
local DEFAULT = "origin/master"
local a1, k1 = sha("feat/A~1"), sha("HEAD~1")

assert(view.open("branch"), "the branch review did not open")

describe("a trim made under feat/A", function()
  vim.cmd("CodeReviewBase feat/A")
  view.trim_to({ k1 })
  local was = current().scope

  it("is in the review under feat/A", function()
    assert.equal(k1, was.before)
    assert.equal("branch vs feat/A · last 1", was.label)
  end)

  it("records feat/A in the store", function()
    assert.equal("feat/A", stored_trim(root, "child").base_branch)
  end)

  local msgs, restore = h.capture_notify()
  vim.cmd("CodeReviewBase origin/feat/A")
  restore()

  it("is dropped when another base branch is picked", function()
    assert.equal(merge_base("origin/feat/A"), current().scope.before)
    assert.equal("branch vs origin/feat/A", current().scope.label)
    assert.is_nil(stored_trim(root, "child"))
  end)

  it("says so once", function()
    assert.equal(1, lost(msgs), vim.inspect(msgs))
  end)

  it("does not say it again on the next resolve", function()
    local again, stop = h.capture_notify()
    view.set_scope("branch")
    stop()
    assert.equal(0, lost(again), vim.inspect(again))
  end)
end)

describe("a trim whose base branch was deleted", function()
  git_at(fixture, { "branch", "gone", "feat/A" })
  vim.cmd("CodeReviewBase gone")
  view.trim_to({ k1 })
  local was = current().scope.label
  git_at(fixture, { "branch", "-D", "-q", "gone" })

  local msgs, restore = h.capture_notify()
  view.set_scope("branch")
  restore()

  it("was in the review under that branch", function()
    assert.equal("branch vs gone · last 1", was)
  end)

  it("is dropped when the review falls back to the default branch", function()
    assert.equal(merge_base(DEFAULT), current().scope.before)
    assert.equal("branch vs " .. DEFAULT, current().scope.label)
    assert.is_nil(stored_trim(root, "child"))
    assert.equal(1, lost(msgs), vim.inspect(msgs))
  end)
end)

state.set_base_branch(root, nil)

describe("a trim stored before a trim recorded its base branch", function()
  local data = state.load(root)
  data.trims.child = { a1 }
  state.save(root, data)

  local msgs, restore = h.capture_notify()
  local scope = assert(git.resolve_scope("branch", root))
  restore()

  it("is read as made under the default branch, and kept", function()
    assert.equal(a1, scope.before)
    assert.equal("branch vs " .. DEFAULT .. " · last 3", scope.label)
    assert.same({ a1 }, stored_trim(root, "child"))
    assert.equal(0, lost(msgs), vim.inspect(msgs))
  end)

  it("is dropped under another base branch", function()
    state.set_base_branch(root, "feat/A")
    local dropped, stop = h.capture_notify()
    local other = assert(git.resolve_scope("branch", root))
    stop()
    assert.equal(merge_base("feat/A"), other.before)
    assert.is_nil(stored_trim(root, "child"))
    assert.equal(1, lost(dropped), vim.inspect(dropped))
  end)
end)

state.set_base_branch(root, nil)
view.set_scope("branch")

describe("the commit list", function()
  local whole = commit_list_rows()
  vim.cmd("CodeReviewBase feat/A")
  local under = commit_list_rows()

  it("lists feat/A's commits under the default branch", function()
    assert.is_not_nil(row_with(whole, "feat: add a1"), table.concat(whole, "\n"))
    assert.is_not_nil(row_with(whole, "feat: add k1"), table.concat(whole, "\n"))
  end)

  it("lists from the merge base with the base branch", function()
    assert.equal(merge_base("feat/A"), current().scope.identity)
    assert.is_nil(row_with(under, "feat: add a1"), table.concat(under, "\n"))
    assert.is_nil(row_with(under, "feat: add a2"), table.concat(under, "\n"))
    assert.is_not_nil(row_with(under, "feat: add k1"), table.concat(under, "\n"))
    assert.is_not_nil(row_with(under, "feat: add k2"), table.concat(under, "\n"))
  end)

  it("opens over a trim made under the base branch, and keeps it", function()
    view.trim_to({ k1 })
    local msgs, restore = h.capture_notify()
    local rows = commit_list_rows()
    restore()
    local k1_row = assert(row_with(rows, "feat: add k1"), table.concat(rows, "\n"))
    local k2_row = assert(row_with(rows, "feat: add k2"), table.concat(rows, "\n"))
    assert.equal("[ ]", k1_row:sub(1, 3), k1_row)
    assert.equal("[x]", k2_row:sub(1, 3), k2_row)
    assert.same({ k1 }, stored_trim(root, "child").skipped)
    assert.equal(0, lost(msgs), vim.inspect(msgs))
  end)
end)

state.set_trim(root, nil)
state.set_base_branch(root, nil)

describe("a trim on a detached HEAD", function()
  git_at(fixture, { "checkout", "-q", "--detach", "child" })
  view.set_scope("branch")
  local quiet, hush = h.capture_notify()
  view.trim_to({ a1 })
  hush()
  local was = current().scope

  local msgs, restore = h.capture_notify()
  vim.cmd("CodeReviewBase feat/A")
  restore()

  it("was in the review for the session", function()
    assert.equal(a1, was.before)
    assert.is_true(h.notified(quiet, "not kept"), vim.inspect(quiet))
  end)

  it("is dropped when the base branch changes, and says so once", function()
    assert.equal(merge_base("feat/A"), current().scope.before)
    assert.equal("branch vs feat/A", current().scope.label)
    assert.equal(1, lost(msgs), vim.inspect(msgs))
  end)

  it("stays dropped when the base branch changes back", function()
    local again, stop = h.capture_notify()
    vim.cmd("CodeReviewBase " .. DEFAULT)
    stop()
    assert.equal(merge_base(DEFAULT), current().scope.before)
    assert.equal(0, lost(again), vim.inspect(again))
  end)

  git_at(fixture, { "checkout", "-q", "child" })
end)

state.set_base_branch(root, nil)
view.set_scope("branch")

-- Last of this copy: it moves master and origin/master and adds a merge to child.
describe("a trim and a merge of the default branch", function()
  view.trim_to({ a1 })
  local was = current().scope

  git_at(fixture, { "checkout", "-q", "master" })
  commit(fixture, "m1")
  git_at(fixture, { "checkout", "-q", "child" })
  git_at(fixture, { "update-ref", "refs/remotes/origin/master", "master" })
  git_at(fixture, { "merge", "-q", "--no-edit", DEFAULT })

  local msgs, restore = h.capture_notify()
  view.set_scope("branch")
  restore()

  it("was in the review before the merge", function()
    assert.equal(a1, was.before)
  end)

  it("moved the merge base", function()
    assert.are_not.equal(was.identity, current().scope.identity)
    assert.equal(merge_base(DEFAULT), current().scope.identity)
  end)

  it("keeps the trim", function()
    assert.equal(a1, current().scope.before)
    assert.same({ a1 }, stored_trim(root, "child").skipped)
    assert.equal(0, lost(msgs), vim.inspect(msgs))
  end)
end)

codereview.close()

--- After a restart -------------------------------------------------------------------

-- A fresh copy: nothing this process did above may answer for what the process before it
-- stored.
local kept = h.fixture("mkstack")
commit(kept, "k2")
local kept_root = assert(vim.uv.fs_realpath(kept))
local kept_k1 = sha("HEAD~1", kept)
local writer = vim
  .system({
    vim.v.progpath,
    "--clean",
    "-l",
    vim.fs.joinpath(h.root, "tests", "codereview", "trim_base_child.lua"),
  }, {
    cwd = kept,
    text = true,
    env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = kept },
  })
  :wait(60000)

describe("a trim stored in the session before", function()
  it("the writing process exits cleanly", function()
    assert.equal(0, writer.code, (writer.stderr or "") .. (writer.stdout or ""))
  end)

  it("is still in use under the base branch it was made under", function()
    local scope = assert(git.resolve_scope("branch", kept_root))
    assert.equal(kept_k1, scope.before)
    assert.equal("branch vs feat/A · last 1", scope.label)
  end)

  it("is dropped once the base branch changes", function()
    state.set_base_branch(kept_root, nil)
    local msgs, restore = h.capture_notify()
    local scope = assert(git.resolve_scope("branch", kept_root))
    restore()
    assert.equal(merge_base(DEFAULT, kept), scope.before)
    assert.equal("branch vs " .. DEFAULT, scope.label)
    assert.is_nil(stored_trim(kept_root, "child"))
    assert.equal(1, lost(msgs), vim.inspect(msgs))
  end)
end)
