-- The queue scoped to its **checkout**.
--
-- Everything on the disk is already per checkout: a store's file name is the checkout's
-- base name plus a hash of its path. The queue in memory was not -- one module-level list,
-- filled by a restore that latched once per session -- and two failures followed from that,
-- neither of which said anything:
--
--   * annotate in one checkout, change directory to a second, annotate again, and the
--     write put **both** sets of **entries** into the second checkout's store;
--   * the second checkout's own stored queue was never read back, because the latch was
--     already set in the first. Unsent work there was invisible, and was then overwritten.
--
-- Single process on purpose. The latch is per checkout now, so the whole of the corruption
-- is reachable with a directory change and needs no restart. What a restart is still needed
-- for -- what reached the disk, and the id an **archive** already holds -- is in
-- `checkout_child.lua` and the blocks that spawn it.
--
-- The reviewer never leaves the checkout they are in by any other means here: there is no
-- switch gesture yet, and this slice must hold without one.
local h = require("tests.helpers")

h.ui(110, 40)

-- Three checkouts of one repository. Realpathed once: `git rev-parse --show-toplevel`
-- answers resolved, and on macOS a temporary directory is a symlink into /private.
local base = assert(vim.uv.fs_realpath(h.fixture("mkcheckouts")))
local A = vim.fs.joinpath(base, "agent-a")
local B = vim.fs.joinpath(base, "agent-b")

local codereview = require("codereview")
local git = require("codereview.git")
local queue = require("codereview.queue")
local state = require("codereview.state")

-- The note the composer answers with, set before each capture. The two checkouts hold the
-- same file at the same repository-relative path, so the note is the only thing that says
-- which checkout an entry was written in.
local note = "unset"
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
})

---Capture an annotation about a checkout's `src/main.lua`, from inside that checkout.
---
---The directory change is what a reviewer with two checkouts does today, and it is the
---whole of the gesture this slice has to survive.
---@param checkout string
---@param text string
local function annotate_in(checkout, text)
  vim.cmd("cd " .. vim.fn.fnameescape(checkout))
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(checkout, "src/main.lua")))
  note = text
  codereview.annotate("bug")
end

---The notes a checkout's store holds, in the order it holds them.
---@param checkout string
---@return string[]
local function stored_notes(checkout)
  return vim.tbl_map(function(e)
    return e.note
  end, state.load(checkout).queue or {})
end

---The notes the queue holds right now.
---@return string[]
local function queued_notes()
  return vim.tbl_map(function(e)
    return e.note
  end, queue.all())
end

describe("the fixture the rest of this spec depends on", function()
  it("resolves each checkout to itself", function()
    assert.same(A, git.root(A))
    assert.same(B, git.root(B))
  end)

  -- Two copies of a repository would satisfy every assertion below about separation, and
  -- none of them would be about checkouts.
  it("makes the two checkouts one repository", function()
    local common = { "rev-parse", "--path-format=absolute", "--git-common-dir" }
    assert.same(h.git_lines(A, common), h.git_lines(B, common))
  end)

  it("gives each checkout a store of its own", function()
    assert.are_not.same(state.path(A), state.path(B))
  end)

  -- So an entry captured in one is identical to an entry captured in the other everywhere
  -- but its absolute path. A rule reading the repository-relative path alone cannot tell
  -- the two apart, which is what makes the filing rule a claim with something to fail on.
  it("holds the same repository-relative path in both", function()
    assert.same(1, vim.fn.filereadable(vim.fs.joinpath(A, "src/main.lua")))
    assert.same(1, vim.fn.filereadable(vim.fs.joinpath(B, "src/main.lua")))
  end)
end)

-- Unsent work left in the second checkout by an earlier session. Written through the
-- store's own accessors rather than as a file, so it carries whatever a document carries.
local left = state.load(B)
left.queue = {
  {
    id = 1,
    type = "fix",
    kind = "file",
    path = "src/main.lua",
    abs_path = vim.fs.joinpath(B, "src/main.lua"),
    key = "src/main.lua:f:0",
    inline = false,
    note = "left unsent in agent-b",
  },
}
state.save(B, left)

describe("a second checkout visited in one session", function()
  annotate_in(A, "about agent-a")

  -- The guard: without this the block below is satisfied by nothing having been captured.
  it("queues what was captured in the first checkout", function()
    assert.same({ "about agent-a" }, queued_notes())
  end)

  it("files it in the first checkout's store", function()
    assert.same({ "about agent-a" }, stored_notes(A))
  end)

  -- The reviewer changes directory and nothing else. This is the read that a capture, a
  -- submit or the queue float would each make first.
  vim.cmd("cd " .. vim.fn.fnameescape(B))
  state.ensure_queue()

  -- Both halves of the second failure at once: what was left in this checkout comes back,
  -- and what belongs to the other checkout is not here to be sent from this one.
  it("reads the queue left in it back", function()
    assert.same({ "left unsent in agent-b" }, queued_notes())
  end)
end)

describe("annotating in that second checkout", function()
  annotate_in(B, "about agent-b")

  it("files it beside what was already there", function()
    assert.same({ "left unsent in agent-b", "about agent-b" }, stored_notes(B))
  end)

  -- The first failure: the write used to put both sets of entries into this store.
  it("leaves the first checkout's entries out of the second checkout's store", function()
    assert.is_false(vim.tbl_contains(stored_notes(B), "about agent-a"), vim.inspect(stored_notes(B)))
  end)

  it("leaves the first checkout's store as it was", function()
    assert.same({ "about agent-a" }, stored_notes(A))
  end)
end)

describe("returning to the first checkout", function()
  vim.cmd("cd " .. vim.fn.fnameescape(A))
  state.ensure_queue()

  it("gives back the queue that was left there", function()
    assert.same({ "about agent-a" }, queued_notes())
  end)

  it("counts only that checkout's entries", function()
    assert.same(1, queue.count())
  end)
end)
