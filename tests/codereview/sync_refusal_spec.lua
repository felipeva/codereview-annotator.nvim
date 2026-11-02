-- A `keep` that the queue owner refuses: the refused entry stays in Neovim, one bad entry
-- does not keep the others out, and the reviewer is told once per reason in a session.
--
-- The queue owner refuses a whole `keep` when one note in it does not decode. The fake
-- decodes as the owner does, so an entry with a uuid that is not a UUID is refused here as
-- it is there.
--
-- One deliberate wait of about 2 s, for the reconnect that sends the refused entries again.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local codereview = require("codereview")
local queue = require("codereview.queue")
local state = require("codereview.state")

local owner = fake.start()

local GOOD_A = "2b9c6c1e-1f4a-4c55-9d1e-6a7b8c9d0e1f"
local GOOD_B = "3c0d7d2f-2a5b-4d66-8e2f-7b8c9d0e1f2a"
local BAD = "not-a-uuid"

---A bare note as the store keeps it.
local function bare(id, uuid, note)
  return {
    id = id,
    uuid = uuid,
    type = "bug",
    kind = "note",
    key = "note:0",
    inline = false,
    note = note,
    at = os.time(),
  }
end

vim.fn.mkdir(vim.fs.dirname(state.global_path()), "p")
vim.fn.writefile({
  vim.json.encode({
    version = 1,
    archive = {},
    queue = { bare(1, GOOD_A, "first"), bare(2, BAD, "a uuid the queue owner cannot read"), bare(3, GOOD_B, "third") },
  }),
}, state.global_path())

local messages, restore_notify = h.capture_notify()
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, "the note")
  end,
  sync = {
    socket = owner.path,
    target = function()
      return { tool = "custom", address = "agent", cwd = fixture }
    end,
  },
})

---@param needle string
---@return integer
local function said(needle)
  local n = 0
  for _, m in ipairs(messages) do
    if m:find(needle, 1, true) then
      n = n + 1
    end
  end
  return n
end

---@param uuid string
---@return CRAnnotation|nil
local function entry_of(uuid)
  for _, e in ipairs(queue.entries()) do
    if e.uuid:lower() == uuid:lower() then
      return e
    end
  end
end

---@param cond fun(): boolean
local function wait(cond)
  vim.wait(5000, cond, 10)
end

wait(function()
  return said("Queue sync started") > 0
end)

describe("one entry that the queue owner cannot decode, at connect", function()
  it("does not keep the other entries out", function()
    local held = vim.tbl_map(function(n)
      return n.id:lower()
    end, owner.queue)
    assert.same({ GOOD_A, GOOD_B }, held)
  end)

  it("stays in the local queue", function()
    assert.is_not_nil(entry_of(BAD))
    assert.same(3, #queue.entries())
  end)

  it("is said once, with the queue owner's reason", function()
    assert.same(1, said("did not take 1 annotation (bad request: bad value at notes.Index 0.id)"))
  end)
end)

describe("a keep that the queue owner refuses", function()
  local REASON = "bad request: wrong type at notes.Index 0.note"
  owner:refuse("keep", REASON)
  vim.cmd("enew")
  codereview.annotate("bug")
  local entry = queue.all()[#queue.all()]
  wait(function()
    return said(REASON) > 0
  end)
  owner:refuse("keep", nil)

  -- A snapshot that does not hold the entry, with a changed note, so that the wait below can
  -- see that the snapshot was applied.
  local held = vim.deepcopy(owner.queue)
  held[1].note = "seen by the queue owner"
  owner:push_queue(held)
  wait(function()
    return entry_of(GOOD_A).note == "seen by the queue owner"
  end)

  it("stays in the local queue after a snapshot that does not hold it", function()
    assert.is_not_nil(entry_of(entry.uuid))
  end)

  it("stays on disk", function()
    local stored = vim.tbl_map(function(e)
      return e.uuid
    end, state.load_global())
    assert.is_true(vim.tbl_contains(stored, entry.uuid))
  end)

  it("is said once", function()
    assert.same(1, said(REASON))
  end)

  describe("at the next connect", function()
    owner:drop_clients()
    wait(function()
      return said("Queue sync stopped") > 0
    end)
    vim.wait(2100)
    local started = said("Queue sync started")
    vim.cmd("enew")
    codereview.annotate("bug")
    wait(function()
      return said("Queue sync started") > started
    end)
    restore_notify()

    it("is sent again, and the queue owner takes it", function()
      assert.is_not_nil(owner:find(entry.uuid))
    end)

    it("says nothing again about an entry refused for the same reason", function()
      assert.same(1, said("bad value at notes.Index 0.id"))
    end)

    it("still keeps the entry that cannot be decoded in the local queue", function()
      assert.is_not_nil(entry_of(BAD))
      assert.is_nil(owner:find(BAD))
    end)
  end)
end)

owner:stop()
