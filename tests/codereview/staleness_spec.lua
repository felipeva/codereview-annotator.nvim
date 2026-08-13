-- Staleness for annotations captured from a buffer.
--
-- A review annotation is judged against the diff on screen, which is right for it: a file
-- the scope does not include is not evidence that anything changed. A buffer annotation
-- has no scope behind it, so that rule never judges it at all -- it would keep claiming a
-- line span that may now point at unrelated code, with nothing saying so.
--
-- Its own spec rather than an extension of capture_spec, because it rewrites fixture files
-- on disk and every spec file gets its own Neovim and its own throwaway repository.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local codereview = require("codereview")
local queue = require("codereview.queue")
local state = require("codereview.state")
local payload = require("codereview.payload")
local config = require("codereview.config")

codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "the note")
  end,
})

local root = assert(vim.uv.fs_realpath(fixture))

---@param rel string
---@return integer buf
local function edit(rel)
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, rel)))
  return vim.api.nvim_get_current_buf()
end

---Rewrite a fixture file on disk, which is what moves its blob.
---@param rel string
---@param lines string[]
local function rewrite(rel, lines)
  vim.fn.writefile(lines, vim.fs.joinpath(root, rel))
end

---@return string
local function render()
  return payload.render(queue.all(), root, { types = config.get().types })
end

describe("a whole-file buffer annotation", function()
  queue.clear()
  edit("src/fresh.lua")
  codereview.annotate("bug")
  local entry = queue.all()[1]

  it("is not flagged while the file is untouched", function()
    state.reconcile_queue(root)
    assert.is_nil(entry.stale)
  end)

  it("still travels as a reference", function()
    assert.is_truthy(render():find("@src/fresh.lua", 1, true), render())
  end)

  it("is flagged once the file on disk changes", function()
    rewrite("src/fresh.lua", { "local function fresh() end", "local added = true" })
    state.reconcile_queue(root)
    assert.is_true(entry.stale)
  end)

  it("stops traveling as a reference", function()
    assert.is_nil(render():find("@src/fresh.lua", 1, true), render())
  end)
end)

vim.keymap.set({ "n", "x" }, "<F5>", function()
  codereview.annotate("bug")
end, { desc = "staleness_spec: annotate as bug" })

describe("a range buffer annotation", function()
  queue.clear()
  edit("src/newname.lua")
  h.feed("1GVj<F5>")
  local entry = queue.all()[1]

  it("travels as a reference while the file is untouched", function()
    state.reconcile_queue(root)
    assert.is_nil(entry.stale)
    assert.is_truthy(render():find("@src/newname.lua#L1-2", 1, true), render())
  end)

  it("is flagged once the file on disk changes", function()
    rewrite("src/newname.lua", { 'local name = "changed"', "local second = 2", "local third = 3" })
    state.reconcile_queue(root)
    assert.is_true(entry.stale)
  end)

  it("inlines its code rather than pointing at lines it can no longer vouch for", function()
    local text = render()
    assert.is_nil(text:find("@src/newname.lua", 1, true), text)
    assert.is_truthy(text:find("```diff", 1, true), text)
    assert.is_truthy(text:find("line numbers may be stale", 1, true), text)
  end)

  -- The whole point of inlining: the agent reads what the reviewer was looking at, not
  -- whatever now occupies those line numbers.
  it("inlines the lines as captured, not as they are now", function()
    local text = render()
    assert.is_truthy(text:find('local name = "new"', 1, true), text)
    assert.is_nil(text:find('local name = "changed"', 1, true), text)
  end)
end)

-- Two rules could reach the same entry here, and they disagree. The diff-based rule would
-- compare a working-tree capture against the *index* blob the staged scope shows, and flag
-- an annotation about a file nobody has touched since it was captured.
describe("a buffer annotation about a file that is also in the diff", function()
  local view = require("codereview.view")
  queue.clear()
  edit("src/routes.lua")
  codereview.annotate("bug")
  local entry = queue.all()[1]

  -- Guards the premise: if the fixture ever stops staging a change on top of an unstaged
  -- one, these blobs converge and this whole case quietly stops testing anything.
  it("is a file whose index and working-tree blobs genuinely differ", function()
    local indexed = h.git_lines(root, { "rev-parse", ":0:src/routes.lua" })[1]
    local working = h.git_lines(root, { "hash-object", "src/routes.lua" })[1]
    assert.is_true(indexed ~= working, "the fixture no longer distinguishes index from worktree")
  end)

  view.open("staged")
  local V = assert(view.current(), "the staged review did not open")

  it("is a file the open scope includes", function()
    assert.is_truthy(h.file_index(V, "src/routes.lua"), "routes.lua is not in the staged scope")
  end)

  it("is judged against the working tree it came from, not the diff it overlaps", function()
    assert.is_nil(entry.stale, "a worktree capture was judged against the index blob")
  end)

  it("still travels as a reference", function()
    assert.is_truthy(render():find("@src/routes.lua", 1, true), render())
  end)

  view.close()
end)

describe("restoring a queue whose file has moved on", function()
  queue.clear()
  state.clear(root)
  edit("src/nonl.md")
  codereview.annotate("bug")
  rewrite("src/nonl.md", { "# rewritten after the note was written" })

  -- What a new session does: nothing in memory, the queue on disk.
  queue.clear()
  local staled = state.restore_queue(root)

  it("restores the annotation", function()
    assert.same(1, queue.count())
    assert.same("src/nonl.md", queue.all()[1].path)
  end)

  -- Without this surviving the round trip through JSON, a restored capture would never be
  -- judged again -- which is precisely the window staleness exists to cover.
  it("kept the record of what its blob was taken against", function()
    assert.is_true(queue.all()[1].worktree)
  end)

  it("flags it stale on restore", function()
    assert.is_true(queue.all()[1].stale)
  end)

  it("reports how many went stale", function()
    assert.same(1, staled)
  end)
end)

describe("telling the user", function()
  local view = require("codereview.view")
  queue.clear()
  edit("src/main.lua")
  codereview.annotate("bug")
  rewrite("src/main.lua", { "local app = require('app')", "local cfg = load_config()", "local extra = true" })

  local msgs, restore_notify = h.capture_notify()
  view.open("branch")
  restore_notify()

  it("counts it in the same message review staleness is reported by", function()
    assert.is_true(h.notified(msgs, "1 annotation now stale"), vim.inspect(msgs))
  end)

  it("leaves reviewed marks alone", function()
    local V = assert(view.current())
    assert.same({}, V.reviewed)
  end)

  view.close()
end)

-- The gap this slice exists to close. `ignored.txt` is gitignored, so no scope will ever
-- contain it, and the diff-based rule would never reach the annotation at all.
describe("a buffer annotation about a file no scope includes", function()
  local view = require("codereview.view")
  queue.clear()
  edit("ignored.txt")
  codereview.annotate("nitpick")
  local entry = queue.all()[1]

  view.open("branch")
  local V = assert(view.current(), "the branch review did not open")

  it("is about a file the review genuinely does not show", function()
    assert.is_nil(h.file_index(V, "ignored.txt"), "the fixture stopped ignoring ignored.txt")
  end)

  it("survives the review opening rather than being discarded", function()
    assert.same(1, queue.count())
  end)

  it("is not flagged while its file is untouched", function()
    assert.is_nil(entry.stale)
  end)

  it("is judged on its own terms once its file changes", function()
    rewrite("ignored.txt", { "secret, but different" })
    view.refresh()
    assert.is_true(entry.stale)
  end)

  view.close()
end)
