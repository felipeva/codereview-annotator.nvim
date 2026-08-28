-- Sweeping the stored state of **checkouts** that are gone.
--
-- A checkout is **orphaned** when its document is still on disk and its directory is not.
-- A sweep discards orphaned state under three conditions that must **all** hold: the
-- directory is gone, **its parent still exists**, and the document has aged past seven
-- days.
--
-- The parent test is the one that is easy to drop and the one that matters most, so the
-- case holding it is here in full: state whose parent directory is also gone is never
-- swept, at any age. Without that case the parent test can be deleted and everything else
-- in this file still passes.
--
-- **Nothing here moves a clock and nothing waits.** An aged document is written by hand,
-- with an old stamp in it, which is the only way to give a document an age in a spec that
-- finishes in milliseconds.
--
-- Single process. Every claim is about what reached the disk, what stayed on it, and what
-- the reviewer was told. Most of the orphans are plain directories rather than checkouts of
-- the fixture, and deliberately so: the sweep never asks git anything -- it reads a stamp
-- and stats two paths -- so a case that needed a repository would be testing something
-- else. The one case that does need real checkouts is the last, where the sweep runs on a
-- **switch** and git's own worktree listing is behind it.
local h = require("tests.helpers")

h.ui(110, 40)

-- Three checkouts of one repository. Realpathed once: `git rev-parse --show-toplevel`
-- answers resolved, and on macOS a temporary directory is a symlink into /private.
local base = assert(vim.uv.fs_realpath(h.fixture("mkcheckouts")))
local A = vim.fs.joinpath(base, "agent-a")
local B = vim.fs.joinpath(base, "agent-b")

local codereview = require("codereview")
local drafts = require("codereview.drafts")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

-- The checkout the reviewer is standing in for the whole file, and one that is really
-- there: a capture has to reach a live checkout's document.
vim.cmd("cd " .. vim.fn.fnameescape(A))

local note_text = "a note"
local chosen = nil
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, note_text)
  end,
  -- The switch's own adapter, stubbed exactly as the send, target and compose adapters are
  -- stubbed throughout the suite. No test-only seam is added for the sweep.
  pick_checkout = function(_, on_choice)
    on_choice(chosen)
  end,
})

local WEEK = 7 * 24 * 60 * 60
local NOW = os.time()
local AGED = NOW - WEEK - 3600

--- Building documents -----------------------------------------------------------

-- A directory of its own for the orphans, so removing one says nothing about the fixture.
local yard = vim.fn.tempname() .. "-orphans"
vim.fn.mkdir(yard, "p")
yard = assert(vim.uv.fs_realpath(yard))

---A directory under the yard, resolved as a checkout's path always is.
---@param name string
---@return string
local function checkout_dir(name)
  local dir = vim.fs.joinpath(yard, name)
  vim.fn.mkdir(dir, "p")
  return assert(vim.uv.fs_realpath(dir))
end

---Give a checkout a document, and then force keys onto the encoded file.
---
---Built over `state.load` and written through `state.save`, so the document is one the
---store itself would recognise -- version included -- rather than a shape this file would
---have to keep in step with it by hand. Written any other way it decodes to nothing, and
---every case below then passes while measuring an empty document.
---
---The stamp is patched into the encoded file afterwards, which is how a document gets an
---age with no clock moved and nothing waited for. `false` removes a key, which is how a
---document written before this ticket -- carrying neither the checkout nor the stamp --
---is built.
---@param checkout string The checkout the document is filed under
---@param doc table Keys to put on the document the store would write
---@param patch table Keys to force onto the encoded document; `false` removes one
local function store(checkout, doc, patch)
  local data = state.load(checkout)
  for key, value in pairs(doc) do
    data[key] = value
  end
  assert(state.save(checkout, data), "the document was not written: " .. checkout)
  local file = state.path(checkout)
  local raw = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  for key, value in pairs(patch) do
    raw[key] = value ~= false and value or nil
  end
  vim.fn.writefile({ vim.json.encode(raw) }, file)
end

---@param checkout string
---@return boolean
local function stored(checkout)
  return vim.fn.filereadable(state.path(checkout)) == 1
end

---An entry as a document holds one: about a file in the checkout it is filed under.
---@param checkout string
---@param id integer
---@param note string
---@return CRAnnotation
local function entry(checkout, id, note)
  return {
    id = id,
    type = "bug",
    kind = "file",
    path = "src/main.lua",
    abs_path = vim.fs.joinpath(checkout, "src/main.lua"),
    key = "file:src/main.lua",
    inline = false,
    note = note,
  }
end

---Sweep, catching a sweep that raises or does not exist.
---
---Caught rather than left to fail where it stands, because an error outside an `it` takes
---the rest of the file down with it and every case below would then report nothing. It is
---also a claim worth making on its own: the sweep walks a directory of files it did not
---write, so it must not raise on any of them.
---@return { checkouts: integer, entries: integer } counts, string[] said, string|nil err
local function sweep()
  local said, restore = h.capture_notify()
  local ok, result = pcall(state.sweep_orphans)
  restore()
  if not ok or type(result) ~= "table" then
    return { checkouts = -1, entries = -1 }, said, tostring(result)
  end
  return result, said, nil
end

---@param note string
---@return CRAnnotation
local function queued(note)
  for _, item in ipairs(queue.all()) do
    if item.note == note then
      return item
    end
  end
  error(("no entry noted %q is in the queue"):format(note))
end

--- The two stores that share the directory and are not checkout documents --------

-- Neither can name a checkout that hashes back to its own file name, which is what leaves
-- the sweep needing no list of files to leave alone. A list would be a second copy of
-- where those two stores live, kept in a third place.
state.save_global({
  { id = 20, type = "issue", kind = "note", key = "note:0", note = "a thought with no repository behind it" },
})
drafts.set("/somewhere/else.lua", "half a note, abandoned")

--- The cast --------------------------------------------------------------------

-- Two checkouts that are gone, aged, and whose parent is still there. Two of them, holding
-- three unsent entries between them, so the two figures a sweep reports are different
-- numbers and neither can stand in for the other.
local GONE_ONE = checkout_dir("gone-one")
local GONE_TWO = checkout_dir("gone-two")
store(GONE_ONE, {
  queue = { entry(GONE_ONE, 1, "unsent, and about to go"), entry(GONE_ONE, 2, "so is this one") },
  scopes = { branch = { reviewed = { ["src/main.lua"] = "0000000000000000000000000000000000000000" } } },
  trims = { master = { "0123456789abcdef0123456789abcdef01234567" } },
  -- Already dispatched, so it is not unsent work: the entry figure must not count it.
  archive = { { at = AGED, target = "local", entries = { entry(GONE_ONE, 3, "already sent") } } },
}, { checkout = GONE_ONE, saved = AGED })
store(GONE_TWO, {
  queue = { entry(GONE_TWO, 4, "the third unsent one") },
}, { checkout = GONE_TWO, saved = AGED })
vim.fn.delete(GONE_ONE, "rf")
vim.fn.delete(GONE_TWO, "rf")

-- The directory is still there, and the document is as old as anything here. Never swept:
-- the age test on its own would take it.
local LIVE = checkout_dir("live")
store(LIVE, {
  queue = { entry(LIVE, 5, "unsent, in a checkout that is still there") },
}, { checkout = LIVE, saved = AGED })

-- Gone, parent alive, and inside the window.
local RECENT = checkout_dir("recent")
store(RECENT, {
  queue = { entry(RECENT, 6, "unsent, and gone an hour ago") },
}, { checkout = RECENT, saved = NOW - 3600 })
vim.fn.delete(RECENT, "rf")

-- The volume that is not mounted: the checkout is gone and so is the directory it sat in.
-- Aged by a year past the window, because "at any age" is the claim.
local VOLUME = checkout_dir("volume/work")
store(VOLUME, {
  queue = { entry(VOLUME, 7, "unsent, on a disk that is not here") },
}, { checkout = VOLUME, saved = AGED - 365 * 24 * 60 * 60 })
vim.fn.delete(vim.fs.joinpath(yard, "volume"), "rf")

-- Written before this ticket: no checkout on it, and no stamp. Gone, parent alive, and
-- older than any window -- and unsweepable, because nothing in it says which checkout it
-- is about or when it was last written.
local BEFORE = checkout_dir("before")
store(BEFORE, {
  queue = { entry(BEFORE, 8, "unsent, from a session before this ticket") },
}, { checkout = false, saved = false })
vim.fn.delete(BEFORE, "rf")

-- A document whose stored checkout is not the checkout it is filed under. Reachable by a
-- state directory carried between machines, and by a file written half way. All three
-- conditions hold for the path it names -- gone, parent there, aged -- and it is still not
-- swept, because that path does not hash back to the file the document is in.
local MISFILED = checkout_dir("misfiled")
local IMPOSTOR = vim.fs.joinpath(yard, "impostor")
store(MISFILED, {
  queue = { entry(MISFILED, 9, "unsent, in a document naming somewhere else") },
}, { checkout = IMPOSTOR, saved = AGED })
vim.fn.delete(MISFILED, "rf")

-- A checkout this session has already read back. Its entries are in memory, and memory is
-- the truth: a sweep that took this document would report unsent work as destroyed while
-- it sits in the queue, and the next write about this checkout would put it straight back.
-- Four entries, so a figure that counted them is visibly wrong rather than plausibly so.
--
-- Read back last of everything built here, because the read-back points the queue at this
-- checkout. The first capture below points it back, resolving the checkout for itself.
local VISITED = checkout_dir("visited")
store(VISITED, {
  queue = {
    entry(VISITED, 10, "read back, and still in memory"),
    entry(VISITED, 11, "and so is this one"),
    entry(VISITED, 12, "and this one"),
    entry(VISITED, 13, "and this one too"),
  },
}, { checkout = VISITED, saved = AGED })
state.ensure_queue_for(VISITED)
vim.fn.delete(VISITED, "rf")

--- The schema ------------------------------------------------------------------

-- A capture in a checkout that is really there, which is what writes a document today.
note_text = "about a file in this checkout"
vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(A, "src", "main.lua")))
codereview.annotate("bug")

-- A **bare note**: an unnamed buffer has no file behind it, so the entry belongs to no
-- checkout and goes to the store that needs no root.
note_text = "with no file behind it"
vim.cmd("enew")
codereview.annotate("issue")

describe("the document", function()
  local doc = state.load(A)

  it("records the checkout it belongs to", function()
    assert.same(A, doc.checkout)
  end)

  it("carries a stamp written on the save", function()
    assert.same("number", type(doc.saved))
    -- Within the run rather than an exact second: what is asserted is that the stamp is of
    -- this save and not of some fixed moment.
    assert.is_true(doc.saved >= NOW and doc.saved <= os.time())
  end)

  it("keeps the queue it was written for", function()
    assert.same(
      { "about a file in this checkout" },
      vim.tbl_map(function(e)
        return e.note
      end, doc.queue)
    )
  end)
end)

describe("an entry", function()
  it("is stamped when it is captured, owned and loose alike", function()
    local owned = queued("about a file in this checkout")
    local loose = queued("with no file behind it")
    assert.same({ "number", "number" }, { type(owned.at), type(loose.at) })
  end)

  it("is stamped at capture, not at the moment it happens to be written", function()
    local owned = queued("about a file in this checkout")
    assert.is_true(owned.at >= NOW and owned.at <= os.time())
  end)
end)

describe("before any switch", function()
  -- No startup scan and no timer: the orphans above were built before the capture, and a
  -- capture writes a document without looking at any other.
  it("sweeps nothing on setup or on a capture", function()
    assert.same({ true, true }, { stored(GONE_ONE), stored(GONE_TWO) })
  end)
end)

--- The sweep -------------------------------------------------------------------

local swept, said, sweep_error = sweep()

describe("a sweep", function()
  it("does not raise on a directory of files it did not write", function()
    assert.is_nil(sweep_error, tostring(sweep_error))
  end)
end)

describe("what a sweep removes", function()
  it("takes a checkout that is gone, whose parent is there, and that has aged out", function()
    assert.is_false(stored(GONE_ONE), state.path(GONE_ONE))
  end)

  it("takes a second one in the same pass", function()
    assert.is_false(stored(GONE_TWO), state.path(GONE_TWO))
  end)

  it("takes the whole document, not the queue inside it", function()
    local left = state.load(GONE_ONE)
    assert.same({ 0, 0, true, true }, {
      #(left.queue or {}),
      #(left.archive or {}),
      vim.tbl_isempty(left.scopes or {}),
      vim.tbl_isempty(left.trims or {}),
    })
  end)
end)

describe("what a sweep must not remove", function()
  it("leaves a checkout that still exists, at any age", function()
    assert.is_true(stored(LIVE), state.path(LIVE))
  end)

  it("leaves an orphan that is inside the window", function()
    assert.is_true(stored(RECENT), state.path(RECENT))
  end)

  it("leaves an orphan whose parent directory is also gone, at any age", function()
    assert.is_true(stored(VOLUME), state.path(VOLUME))
  end)

  it("leaves a document written before the checkout and the stamp existed", function()
    assert.is_true(stored(BEFORE), state.path(BEFORE))
  end)

  it("leaves a document whose stored checkout is not the one it is filed under", function()
    assert.is_true(stored(MISFILED), state.path(MISFILED))
  end)

  it("leaves a checkout this session has already read back", function()
    assert.is_true(stored(VISITED), state.path(VISITED))
  end)

  it("leaves the store that needs no root, and the drafts beside it", function()
    assert.same({ 1, "half a note, abandoned" }, {
      vim.fn.filereadable(state.global_path()),
      drafts.get("/somewhere/else.lua"),
    })
  end)
end)

describe("what a sweep reports", function()
  it("says one line", function()
    assert.same(1, #said, vim.inspect(said))
  end)

  it("answers with the two counts", function()
    assert.same({ checkouts = 2, entries = 3 }, swept)
  end)

  it("gives the checkouts and the unsent annotations as separate figures", function()
    local line = said[1] or ""
    assert.is_truthy(line:find("2", 1, true), line)
    assert.is_truthy(line:find("3", 1, true), line)
    -- What this rules out is one figure standing for both: a sum reads 5, and a checkout
    -- count on its own never mentions 3 at all.
    assert.is_nil(line:find("5", 1, true), line)
  end)

  it("counts the unsent entries, and not everything the documents held", function()
    -- Four entries were in those two documents; one of them had already been dispatched.
    assert.same(3, swept.entries)
  end)
end)

describe("a sweep with nothing to take", function()
  local again, quiet = sweep()

  it("removes nothing", function()
    assert.same({ checkouts = 0, entries = 0 }, again)
  end)

  it("says nothing at all", function()
    assert.same({}, quiet)
  end)
end)

describe("a sweep that destroys work", function()
  local UNASKED = checkout_dir("unasked")
  store(UNASKED, {
    queue = { entry(UNASKED, 30, "unsent, and taken without a question") },
  }, { checkout = UNASKED, saved = AGED })
  vim.fn.delete(UNASKED, "rf")

  local asked = {}
  local was = { select = vim.ui.select, input = vim.ui.input, confirm = vim.fn.confirm }
  vim.ui.select = function()
    asked[#asked + 1] = "select"
  end
  vim.ui.input = function()
    asked[#asked + 1] = "input"
  end
  vim.fn.confirm = function()
    asked[#asked + 1] = "confirm"
    return 1
  end
  local taken = sweep()
  vim.ui.select, vim.ui.input, vim.fn.confirm = was.select, was.input, was.confirm

  it("takes it", function()
    assert.same({ checkouts = 1, entries = 1 }, taken)
  end)

  it("never prompts", function()
    assert.same({}, asked)
  end)
end)

--- On a switch -----------------------------------------------------------------

-- A checkout of the fixture, really removed. This is the shape the sweep is built for: a
-- checkout taken out from beside a repository that stays, so the directory holding the
-- three of them is still there as its parent.
store(B, {
  queue = { entry(B, 40, "left in a checkout that was then removed") },
}, { checkout = B, saved = AGED })
vim.fn.delete(B, "rf")

local orphan_before_switch = stored(B)
chosen = A
local switch_said, restore_switch = h.capture_notify()
codereview.switch()
restore_switch()

describe("a switch", function()
  it("had the orphan on disk on the way in", function()
    assert.is_true(orphan_before_switch)
  end)

  it("sweeps", function()
    assert.is_false(stored(B), state.path(B))
  end)

  it("says what it took", function()
    assert.is_true(h.notified(switch_said, "orphaned checkout"), vim.inspect(switch_said))
  end)

  it("still opens the review it was asked for", function()
    assert.same(A, assert(view.current(), "no review view open").root)
  end)
end)
