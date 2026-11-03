-- The picker of the **base branch**: `gm` in the diff and in the tree, and `:CodeReviewBase`
-- with no argument, with `vim.ui.select` stubbed.
--
-- The fixture is `mkstack`, with five refs added here, each one that a single rule alone can
-- reject or place: `backup` at `HEAD` and `grandchild` forked from `child` contain `HEAD`, so
-- only `--no-contains` drops them; `origin/child` is behind `HEAD`, so only the remote-copy
-- rule drops it; `zz-new` and `aa-old` carry dates far from the rest, so the order is git's
-- date order and not the name order. `origin/HEAD` is in the fixture already, and only the
-- symref rule drops it. The first block asserts each of those pre-states.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkstack")
local root = assert(vim.uv.fs_realpath(fixture))

local codereview = require("codereview")
local git = require("codereview.git")
local state = require("codereview.state")
local view = require("codereview.view")

codereview.setup({ syntax = false, send = function() end })

---@param args string[]
---@param env? table<string, string>
---@return string stdout
local function git_at(args, env)
  -- Hermetic, as the fixture script is: a user's `commit.gpgsign` must not reach a commit here.
  env = vim.tbl_extend("force", { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_SYSTEM = "/dev/null" }, env or {})
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = fixture, text = true, env = env }):wait(60000)
  assert(res.code == 0, table.concat(args, " ") .. ": " .. (res.stderr or ""))
  return vim.trim(res.stdout or "")
end

---A branch with one commit on `parent`, made with no checkout, at `date` when one is given.
---@param name string
---@param parent string
---@param date? string
local function branch_off(name, parent, date)
  local env = date and { GIT_COMMITTER_DATE = date, GIT_AUTHOR_DATE = date } or nil
  local commit = git_at({ "commit-tree", parent .. "^{tree}", "-p", parent, "-m", name }, env)
  git_at({ "branch", name, commit })
end

git_at({ "branch", "backup" })
branch_off("grandchild", "child")
git_at({ "update-ref", "refs/remotes/origin/child", "child~1" })
branch_off("zz-new", "master", "2090-01-01T00:00:00Z")
branch_off("aa-old", "master", "2001-01-01T00:00:00Z")

---git's own merge base of `ref` and `HEAD`.
---@param ref string
---@return string
local function merge_base(ref)
  return assert(h.git_lines(fixture, { "merge-base", ref, "HEAD" })[1], "no merge base with " .. ref)
end

---What git lists with no filter of the plugin's: every ref, newest commit first.
---@param ... string extra arguments
---@return string[]
local function git_refs(...)
  return h.git_lines(
    fixture,
    vim.list_extend({ "for-each-ref", "--sort=-committerdate", "--format=%(refname)", ... }, {
      "refs/heads",
      "refs/remotes",
    })
  )
end

---@return CRView
local function current()
  return assert(view.current(), "no review view open")
end

---@return table<string, string>
local function stored()
  return state.load(root).base_branches or {}
end

---Stand in for `vim.ui.select` once: record what it was handed and answer with `choose`.
---@param choose string|nil nil cancels
---@return { items: string[]|nil, prompt: string|nil }
local function stub_select(choose)
  local seen = {}
  local orig = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    vim.ui.select = orig
    seen.items, seen.prompt = items, opts.prompt
    cb(choose)
  end
  seen.restore = function()
    vim.ui.select = orig
  end
  return seen
end

---@param buf integer
---@return table<string, true>
local function bound(buf)
  local lhs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    lhs[vim.keycode(m.lhs)] = true
  end
  return lhs
end

local DEFAULT = "origin/master"
local EXPECTED = { DEFAULT, "zz-new", "aa-old", "feat/A", "master", "origin/feat/A" }

describe("the fixture the listing reads", function()
  local all = git_refs()

  it("holds every ref a rule must drop", function()
    for _, ref in ipairs({
      "refs/heads/child",
      "refs/heads/backup",
      "refs/heads/grandchild",
      "refs/remotes/origin/child",
      "refs/remotes/origin/HEAD",
    }) do
      assert.is_true(vim.tbl_contains(all, ref), ref .. " is not in " .. vim.inspect(all))
    end
  end)

  it("has origin/child and origin/HEAD outside what --no-contains drops", function()
    local kept = git_refs("--no-contains=HEAD")
    assert.is_true(vim.tbl_contains(kept, "refs/remotes/origin/child"), vim.inspect(kept))
    assert.is_true(vim.tbl_contains(kept, "refs/remotes/origin/HEAD"), vim.inspect(kept))
    assert.is_false(vim.tbl_contains(kept, "refs/heads/backup"), vim.inspect(kept))
    assert.is_false(vim.tbl_contains(kept, "refs/heads/grandchild"), vim.inspect(kept))
  end)

  it("puts zz-new before the default branch in git's date order, and aa-old last", function()
    assert.equal("refs/heads/zz-new", all[1])
    assert.equal("refs/heads/aa-old", all[#all])
  end)
end)

describe("the listing", function()
  local calls = {}
  local system = vim.system
  vim.system = function(cmd, ...)
    calls[#calls + 1] = cmd[2]
    return system(cmd, ...)
  end
  local choices = git.base_branch_choices(root)
  vim.system = system

  it("starts with the default branch, then the newest commit, and ends with the oldest", function()
    assert.equal(DEFAULT, choices[1])
    assert.equal("zz-new", choices[2])
    assert.equal("aa-old", choices[#choices])
  end)

  it("holds the local and remote-tracking branches that do not contain HEAD, each once", function()
    local got, want = vim.deepcopy(choices), vim.deepcopy(EXPECTED)
    table.sort(got)
    table.sort(want)
    assert.same(want, got)
  end)

  it("leaves out the current branch, its remote copy, origin/HEAD and what contains HEAD", function()
    for _, ref in ipairs({ "child", "origin/child", "origin", "origin/HEAD", "backup", "grandchild" }) do
      assert.is_false(vim.tbl_contains(choices, ref), ref .. " is in " .. vim.inspect(choices))
    end
  end)

  it("comes from one for-each-ref and no merge-base", function()
    assert.equal(1, #vim.tbl_filter(function(c)
      return c == "for-each-ref"
    end, calls), vim.inspect(calls))
    assert.is_false(vim.tbl_contains(calls, "merge-base"), vim.inspect(calls))
  end)
end)

describe("the listing on a branch the default branch already contains", function()
  git_at({ "checkout", "-q", "master" })
  local filtered = git_refs("--no-contains=HEAD")
  local choices = git.base_branch_choices(root)
  git_at({ "checkout", "-q", "child" })

  it("is a branch whose every ref git drops", function()
    assert.same({}, filtered)
  end)

  it("still offers the default branch, first", function()
    assert.same({ DEFAULT }, choices)
  end)
end)

--- The review view ----------------------------------------------------------------

describe("gm in the diff", function()
  assert(view.open("branch"), "the branch review did not open")
  local before_pick, before_stored = current().scope.before, stored().child
  local seen = stub_select("feat/A")
  vim.api.nvim_set_current_win(current().win)
  h.feed("gm")
  seen.restore()

  it("was on the default branch before the pick", function()
    assert.equal(merge_base(DEFAULT), before_pick)
    assert.is_nil(before_stored)
  end)

  it("opens the listing", function()
    assert.same(git.base_branch_choices(root), seen.items)
  end)

  it("stores the pick under the branch", function()
    assert.equal("feat/A", stored().child)
  end)

  it("draws the review again from the merge base with it, and names it on the winbar", function()
    assert.equal(merge_base("feat/A"), current().scope.before)
    assert.is_truthy(h.winbar(current().win):find("branch vs feat/A", 1, true), h.winbar(current().win))
  end)
end)

describe("gm in the file tree", function()
  it("is bound in the diff and in the tree", function()
    assert.is_true(bound(current().buf)[vim.keycode("gm")] == true, "gm is not bound in the diff")
    assert.is_true(bound(assert(current().panel_buf))[vim.keycode("gm")] == true, "gm is not bound in the tree")
  end)

  it("opens the same listing, and a pick draws the review again", function()
    local seen = stub_select("origin/feat/A")
    vim.api.nvim_set_current_win((assert(current().panel_win, "no file tree")))
    h.feed("gm")
    seen.restore()
    assert.same(git.base_branch_choices(root), seen.items)
    assert.equal("origin/feat/A", stored().child)
    assert.equal(merge_base("origin/feat/A"), current().scope.before)
  end)
end)

describe("a cancel", function()
  local before_cancel = current().scope.before
  local seen = stub_select(nil)
  vim.api.nvim_set_current_win(current().win)
  h.feed("gm")
  seen.restore()

  it("opened the picker", function()
    assert.is_not_nil(seen.items)
  end)

  it("changes nothing", function()
    assert.equal("origin/feat/A", stored().child)
    assert.equal(before_cancel, current().scope.before)
  end)
end)

describe("a pick of the default branch", function()
  local seen = stub_select(DEFAULT)
  h.feed("gm")
  seen.restore()

  it("stores the explicit default marker", function()
    assert.equal(state.DEFAULT_BASE_BRANCH, stored().child)
  end)

  it("draws the review from the default branch", function()
    assert.equal(merge_base(DEFAULT), current().scope.before)
    assert.is_truthy(h.winbar(current().win):find("branch vs origin/master", 1, true), h.winbar(current().win))
  end)
end)

describe("gm in a scope other than branch", function()
  view.set_scope("worktree")
  local seen = stub_select("feat/A")
  local msgs, restore = h.capture_notify()
  vim.api.nvim_set_current_win(current().win)
  h.feed("gm")
  restore()
  seen.restore()

  it("says that a base branch is for a branch review", function()
    assert.is_true(h.notified(msgs, "A base branch is for a branch review"), vim.inspect(msgs))
  end)

  it("opens no picker and changes nothing", function()
    assert.is_nil(seen.items)
    assert.equal(state.DEFAULT_BASE_BRANCH, stored().child)
    assert.equal("worktree", current().scope.name)
  end)
end)

--- The command --------------------------------------------------------------------

describe(":CodeReviewBase with no argument in a scope other than branch", function()
  local seen = stub_select("feat/A")
  local msgs, restore = h.capture_notify()
  vim.cmd("CodeReviewBase")
  restore()
  seen.restore()

  it("was on another scope", function()
    assert.equal("worktree", current().scope.name)
  end)

  it("refuses as gm does: the sentence, no picker, nothing stored", function()
    assert.is_true(h.notified(msgs, "A base branch is for a branch review"), vim.inspect(msgs))
    assert.is_nil(seen.items)
    assert.equal(state.DEFAULT_BASE_BRANCH, stored().child)
  end)
end)

describe(":CodeReviewBase with no argument", function()
  view.set_scope("branch")
  local seen = stub_select("feat/A")
  vim.cmd("CodeReviewBase")
  seen.restore()

  it("opens the same listing", function()
    assert.same(git.base_branch_choices(root), seen.items)
  end)

  it("stores the pick and draws the review again", function()
    assert.equal("feat/A", stored().child)
    assert.equal(merge_base("feat/A"), current().scope.before)
  end)
end)

describe(":CodeReviewBase completion", function()
  it("completes from the listing", function()
    assert.same(git.base_branch_choices(root), vim.fn.getcompletion("CodeReviewBase ", "cmdline"))
  end)

  it("filters the listing by what is typed", function()
    assert.same({ "origin/master", "origin/feat/A" }, vim.fn.getcompletion("CodeReviewBase origin/", "cmdline"))
  end)
end)

codereview.close()

describe(":CodeReviewBase with no argument and no review open", function()
  local seen = stub_select("origin/feat/A")
  vim.cmd("CodeReviewBase")
  seen.restore()

  it("opens the picker and stores the pick", function()
    assert.same(git.base_branch_choices(root), seen.items)
    assert.equal("origin/feat/A", stored().child)
  end)
end)

--- A trim under the old base branch ----------------------------------------------

-- One more commit on `child`, as `trim_base_spec` adds, so a trim under `feat/A` leaves a
-- commit in. Last in this file: it moves `HEAD`, which every listing above reads.
vim.fn.writefile({ "k2" }, vim.fs.joinpath(fixture, "k2.txt"))
git_at({ "add", "-A" })
git_at({ "commit", "-qm", "feat: add k2" })
local k1 = h.git_lines(fixture, { "rev-parse", "HEAD~1" })[1]

describe("a pick from the picker over a trim made under feat/A", function()
  assert(view.open("branch"), "the branch review did not open")
  vim.cmd("CodeReviewBase feat/A")
  view.trim_to({ k1 })
  local trimmed = current().scope
  local trim_before = vim.deepcopy((state.load(root).trims or {}).child)

  local seen = stub_select("master")
  local msgs, restore = h.capture_notify()
  vim.api.nvim_set_current_win(current().win)
  h.feed("gm")
  restore()
  seen.restore()

  it("was a trim recorded under feat/A, in the review", function()
    assert.equal("feat/A", trim_before and trim_before.base_branch)
    assert.equal(k1, trimmed.before)
    assert.equal("branch vs feat/A · last 1", trimmed.label)
  end)

  it("drops the trim from the store", function()
    assert.equal("master", stored().child)
    assert.is_nil((state.load(root).trims or {}).child)
  end)

  it("tells the reviewer once", function()
    local n = #vim.tbl_filter(function(msg)
      return type(msg) == "string" and msg:find("The trim was lost", 1, true) ~= nil
    end, msgs)
    assert.equal(1, n, vim.inspect(msgs))
  end)

  it("draws the whole branch from the merge base with master", function()
    assert.equal(merge_base("master"), current().scope.before)
    assert.equal("branch vs master", current().scope.label)
  end)
end)

codereview.close()
