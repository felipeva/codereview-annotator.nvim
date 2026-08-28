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
-- The third is touched by one block only, and that is what it is for: a checkout with an
-- empty **archive**, which is the one that a counter seeded per checkout would start at 1.
local MAIN = vim.fs.joinpath(base, "main")

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

-- Reachable with no gesture this slice adds: open a file that is in another checkout and
-- annotate it. The entry is about that checkout and the queue is this one's, so it can be
-- filed nowhere -- not here, because it is not about here, and not there, because a queue
-- nothing has read back must not be written over. It is kept, it goes out with the batch,
-- and what it does not do is survive a restart. The reviewer is told exactly that.
describe("an annotation about a file in another checkout", function()
  local NOTE = "about agent-b, written from agent-a"

  vim.cmd("cd " .. vim.fn.fnameescape(A))
  state.ensure_queue()
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(B, "src/main.lua")))
  note = NOTE
  local msgs, restore = h.capture_notify()
  codereview.annotate("bug")
  restore()

  local entries = queue.all()
  local entry = entries[#entries]

  -- The guard: the entry has to be about the other checkout for anything below to mean
  -- anything, and the two checkouts hold the same repository-relative path, so it is the
  -- absolute one that says which.
  it("is about the checkout the file is in", function()
    assert.same(NOTE, entry.note)
    assert.same("src/main.lua", entry.path)
    assert.same(vim.fs.joinpath(B, "src/main.lua"), entry.abs_path)
  end)

  it("stays in the queue the reviewer is in", function()
    assert.is_true(vim.tbl_contains(queued_notes(), NOTE), vim.inspect(queued_notes()))
  end)

  it("is filed under neither checkout", function()
    assert.is_false(vim.tbl_contains(stored_notes(A), NOTE), vim.inspect(stored_notes(A)))
    assert.is_false(vim.tbl_contains(stored_notes(B), NOTE), vim.inspect(stored_notes(B)))
  end)

  it("says so, rather than leaving it to be discovered at the next start", function()
    assert.is_true(h.notified(msgs, queue.unfiled_phrase(1)), vim.inspect(msgs))
  end)

  -- Progress is written on every mutation, so a sentence said per write would be said
  -- again on the next annotation, the next reviewed mark and the next drop.
  it("says it once, and not again on the next write", function()
    local again, restore_again = h.capture_notify()
    state.persist_queue(A)
    restore_again()
    assert.is_false(h.notified(again, "about another checkout"), vim.inspect(again))
  end)
end)

local LOOSE = "a thought with no repository behind it"

---How many entries in the queue carry a note.
---@param needle string
---@return integer
local function occurrences(needle)
  local n = 0
  for _, text in ipairs(queued_notes()) do
    if text == needle then
      n = n + 1
    end
  end
  return n
end

-- An entry with no repository behind it belongs to no checkout, so it is in hand wherever
-- the reviewer is. Read back here rather than queued, because the id it carries is what the
-- last block turns on.
describe("a loose entry read back into a checkout that already has a queue", function()
  state.save_global({ { id = 1, type = "issue", kind = "note", key = "note:0", note = LOOSE } })

  vim.cmd("cd " .. vim.fn.fnameescape(A))
  state.restore_queue(A)

  it("brings it into hand", function()
    assert.same(1, occurrences(LOOSE), vim.inspect(queued_notes()))
  end)

  -- The store that needs no root is read on its own question. Asked of the whole queue, a
  -- checkout that already holds entries answers "not empty" and the loose entry never
  -- arrives at all.
  it("leaves the entries this checkout already held exactly as they were", function()
    assert.same(1, occurrences("about agent-a"), vim.inspect(queued_notes()))
  end)

  -- Without this the last block is vacuous: only an id low enough to collide can catch a
  -- counter that starts again per checkout.
  it("brought it back with the id it was stored under", function()
    for _, e in ipairs(queue.all()) do
      if e.note == LOOSE then
        assert.same(1, e.id)
      end
    end
  end)
end)

-- A checkout has to be able to read its own store while the reviewer holds something that
-- belongs to no checkout. The two guards are separate questions for this reason: asked as
-- one, a bare note in hand stops every checkout visited afterwards from ever reading what
-- was left in it -- which is the failure this slice removes, wearing a different hat.
describe("a checkout with unsent work, reached with that entry in hand", function()
  local waiting = state.load(MAIN)
  waiting.queue = {
    {
      id = 2,
      type = "fix",
      kind = "file",
      path = "src/main.lua",
      abs_path = vim.fs.joinpath(MAIN, "src/main.lua"),
      key = "src/main.lua:f:0",
      inline = false,
      note = "left unsent in main",
    },
  }
  state.save(MAIN, waiting)

  vim.cmd("cd " .. vim.fn.fnameescape(MAIN))
  state.ensure_queue()

  it("reads that checkout's own store, though the queue was not empty", function()
    assert.same(1, occurrences("left unsent in main"), vim.inspect(queued_notes()))
  end)

  -- Read on every restore rather than on its own question, the loose entry arrives once per
  -- checkout the reviewer visits.
  it("keeps the loose entry, and only one of it", function()
    assert.same(1, occurrences(LOOSE), vim.inspect(queued_notes()))
  end)

  it("shows nothing of the checkout it came from", function()
    assert.same(0, occurrences("about agent-a"), vim.inspect(queued_notes()))
  end)
end)

-- What one id counter is for, and the case a counter split per checkout would fail.
--
-- This checkout's archive is empty, which is exactly where a per-checkout counter would
-- start at 1 -- and 1 is what the loose entry beside it came back as. `remove` matches the
-- first entry carrying the id it is given, so the collision reports nothing at all: it
-- drops the wrong annotation.
describe("an annotation queued in a checkout with an empty archive", function()
  local OWNED = "the first annotation in main"
  annotate_in(MAIN, OWNED)

  local by_note = {}
  for _, e in ipairs(queue.all()) do
    by_note[e.note] = e
  end

  it("has the loose entry beside it still", function()
    assert.is_not_nil(by_note[LOOSE], vim.inspect(queued_notes()))
    assert.is_not_nil(by_note[OWNED], vim.inspect(queued_notes()))
  end)

  it("takes an id of its own", function()
    assert.are_not.same(by_note[LOOSE].id, by_note[OWNED].id)
  end)

  -- The consequence, and the whole reason the ids have to differ: dropping the loose entry
  -- has to drop the loose entry.
  it("drops the entry that was asked for, and leaves the other", function()
    local removed = queue.remove(by_note[LOOSE].id)
    assert.same(LOOSE, removed and removed.note)
    assert.is_true(vim.tbl_contains(queued_notes(), OWNED), vim.inspect(queued_notes()))
  end)
end)
