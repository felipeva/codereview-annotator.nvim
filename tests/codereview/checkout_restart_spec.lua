-- What a queue scoped per **checkout** can only be shown across a genuine restart.
--
-- Two claims live here and neither can be made in one process, which is why this is a file
-- of its own rather than more blocks in `checkout_spec`:
--
--   * **What reached the disk.** A session that worked in two checkouts wrote two stores,
--     and each holds only what it is about. Asserting that in the writing process asserts
--     memory. Prior art is `state_spec`, which writes in a child and reads after a restart.
--   * **The id an archive already holds.** The queue's counter is module-level and starts
--     at 1, so the process that dispatched is the process still counting: a one-process
--     test of "a new annotation does not take an id the archive holds" passes whether or
--     not anything is seeded. The same trap `archive_spec` records, one checkout further
--     on -- here the counter has to be lifted by the archive of the checkout being *
--     visited*, not by the first checkout the session happened to open.
--
-- This process must therefore reach the second checkout with a counter that has only ever
-- heard about the first, which is what the block order below is for.
local h = require("tests.helpers")

h.ui(110, 40)

local base = assert(vim.uv.fs_realpath(h.fixture("mkcheckouts")))
local A = vim.fs.joinpath(base, "agent-a")
local B = vim.fs.joinpath(base, "agent-b")

local codereview = require("codereview")
local queue = require("codereview.queue")
local state = require("codereview.state")

local note = "unset"
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note)
  end,
})

---@param checkout string
---@param text string
local function annotate_in(checkout, text)
  vim.cmd("cd " .. vim.fn.fnameescape(checkout))
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(checkout, "src/main.lua")))
  note = text
  codereview.annotate("bug")
end

---Every note a document holds, queued and archived alike.
---
---Both halves, because "the other checkout's entry is not in this store" is a claim about
---the document and not about either key in it: a dispatch moves an entry from one to the
---other, so searching the queue alone would go quiet the moment a batch went out.
---@param doc table
---@return string[]
local function notes_in(doc)
  local notes = {}
  for _, entry in ipairs(doc.queue or {}) do
    notes[#notes + 1] = entry.note
  end
  for _, batch in ipairs(doc.archive or {}) do
    for _, entry in ipairs(batch.entries or {}) do
      notes[#notes + 1] = entry.note
    end
  end
  table.sort(notes)
  return notes
end

---Every id a document holds, queued and archived alike.
---@param doc table
---@return integer[]
local function ids_in(doc)
  local ids = {}
  for _, entry in ipairs(doc.queue or {}) do
    ids[#ids + 1] = entry.id
  end
  for _, batch in ipairs(doc.archive or {}) do
    for _, entry in ipairs(batch.entries or {}) do
      ids[#ids + 1] = entry.id
    end
  end
  table.sort(ids)
  return ids
end

describe("the writing process", function()
  -- The child shares this process's throwaway XDG_STATE_HOME and nothing else. It runs
  -- with `--clean` so no user config, and no minimal_init, can hand it a different one.
  local cmd = {
    vim.v.progpath,
    "--clean",
    "-l",
    vim.fs.joinpath(h.root, "tests", "codereview", "checkout_child.lua"),
  }
  local proc = vim.system(cmd, {
    cwd = base,
    text = true,
    env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = base },
  })
  local child = proc:wait(60000)

  it("exits cleanly", function()
    assert.same(0, child.code, (child.stderr or "") .. (child.stdout or ""))
  end)

  it("leaves a store behind for each checkout", function()
    for _, checkout in ipairs({ A, B }) do
      local path = state.path(checkout)
      assert.same(1, vim.fn.filereadable(path), "no state at " .. path .. "\n" .. (child.stdout or ""))
    end
  end)
end)

describe("what the session before this one wrote", function()
  local a, b = state.load(A), state.load(B)

  it("keeps each checkout's annotations in that checkout's store", function()
    assert.same({ "dispatched from agent-a", "left unsent in agent-a" }, notes_in(a))
    assert.same({ "also dispatched from agent-b", "dispatched from agent-b" }, notes_in(b))
  end)

  it("leaves the first checkout's unsent work unsent, and in its own store", function()
    assert.same(
      { "left unsent in agent-a" },
      vim.tbl_map(function(e)
        return e.note
      end, a.queue)
    )
  end)

  -- The second checkout dispatched everything it queued, so what is left of it is an
  -- archive and nothing else. Without this the id block below is about a queue coming back
  -- rather than about an archive being read.
  it("leaves the second checkout with an archive and no queue", function()
    assert.same({}, b.queue)
    assert.same(1, #b.archive)
  end)

  it("archives each dispatch under the checkout it went out of", function()
    assert.same(
      { "dispatched from agent-a" },
      vim.tbl_map(function(e)
        return e.note
      end, a.archive[1].entries)
    )
  end)
end)

-- Runs before this process has touched any queue: the counter has issued no id yet, and
-- each checkout's read-back latch is unset. Both halves of the case depend on that.
describe("a second checkout reached after the restart", function()
  it("starts from an empty queue, so every id below came off the disk", function()
    assert.same(0, queue.count())
  end)

  local a_ids, b_ids = ids_in(state.load(A)), ids_in(state.load(B))

  -- Without this the block is vacuous. Everything the first checkout can teach the counter
  -- sits below everything the second checkout's archive holds, so only that archive being
  -- read can keep a new annotation clear of the entries already drawn on that diff.
  it("has archived ids the first checkout could not have lifted the counter past", function()
    assert.is_true(a_ids[#a_ids] < b_ids[1], ("%s is not below %s"):format(vim.inspect(a_ids), vim.inspect(b_ids)))
  end)

  -- The first checkout, visited first: this is what used to latch the restore for the whole
  -- session and leave the second checkout's store unread.
  vim.cmd("cd " .. vim.fn.fnameescape(A))
  state.ensure_queue()

  it("gives the first checkout back the work it left unsent", function()
    assert.same(
      { "left unsent in agent-a" },
      vim.tbl_map(function(e)
        return e.note
      end, queue.all())
    )
  end)

  annotate_in(B, "queued after the restart")

  it("shows the second checkout its own queue, and not the first's", function()
    assert.same(
      { "queued after the restart" },
      vim.tbl_map(function(e)
        return e.note
      end, queue.all())
    )
  end)

  it("takes an id above every id that checkout's archive holds", function()
    local queued = assert(queue.all()[1], "nothing was queued")
    assert.is_true(queued.id > b_ids[#b_ids], ("%d is not above %s"):format(queued.id, vim.inspect(b_ids)))
  end)

  -- And what the disk says about it afterwards, which is the other half of the same claim:
  -- the annotation just made is in the store of the checkout it is about, and nowhere else.
  it("writes it to the second checkout's store and leaves the first's alone", function()
    assert.is_true(vim.tbl_contains(notes_in(state.load(B)), "queued after the restart"))
    assert.is_false(vim.tbl_contains(notes_in(state.load(A)), "queued after the restart"))
  end)
end)
