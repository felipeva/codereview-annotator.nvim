-- **Pending removals** in one session: none without `sync`, a drop during the handshake,
-- and the sweep after 7 days. sync_restart_spec has the restart.
--
-- Driven through the public surface only: `setup()`, `annotate()`, `submit()` and the queue
-- float. The transport is real: a Unix socket in a temporary directory, served by
-- tests/fake_queue_owner.lua in this process.
--
-- The cases run from top to bottom and build on each other.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))

local codereview = require("codereview")
local queue = require("codereview.queue")
local state = require("codereview.state")

local reply = "the note"
local function compose(_, on_accept)
  on_accept(nil, reply)
end

---@param cond fun(): boolean
local function wait(cond)
  vim.wait(3000, cond, 10)
end

---@param sync table|nil
local function setup(sync)
  codereview.setup({
    syntax = false,
    types = { { name = "question", key = "q", label = "Questions" } },
    compose = compose,
    send = function() end,
    sync = sync,
  })
end

---@param owner FakeQueueOwner
---@return table
local function sync_to(owner)
  return {
    socket = owner.path,
    target = function()
      return { tool = "custom", address = "agent", cwd = root }
    end,
  }
end

---@param note string
---@return CRAnnotation|nil
local function by_note(note)
  for _, e in ipairs(queue.entries()) do
    if e.note == note then
      return e
    end
  end
end

---@param note string
local function bare(note)
  vim.cmd("enew")
  reply = note
  codereview.annotate("question")
end

---Press `keys` in the queue float on the row that holds `note`, and close the float.
---@param note string
---@param keys string
local function in_float(note, keys)
  codereview.queue()
  local win = vim.api.nvim_get_current_win()
  assert(vim.fn.search(note) > 0, "the float does not show " .. note)
  h.feed(keys)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

---The store for entries with no repository, as written to disk.
---@return table
local function stored()
  return vim.json.decode(
    table.concat(vim.fn.readfile(state.global_path()), "\n"),
    { luanil = { object = true, array = true } }
  )
end

---@param owner FakeQueueOwner
---@param op string
---@return table[]
local function requests(owner, op)
  return vim.tbl_filter(function(r)
    return r.op == op
  end, owner.requests)
end

describe("without sync", function()
  setup(nil)
  bare("dropped without sync")
  bare("edited without sync")
  in_float("dropped without sync", "x")
  reply = "edited again without sync"
  in_float("edited without sync", "e")
  codereview.submit()

  -- The control: the edit, the drop and the submit all ran.
  it("drops, edits and submits as before", function()
    assert.same(0, queue.count())
    assert.same(1, #state.global_archive())
    assert.same("edited again without sync", state.global_archive()[1].entries[1].note)
  end)

  it("writes no pending removal and no unsent edit", function()
    local doc = stored()
    assert.is_nil(doc.removals)
    assert.is_nil(doc.unsent)
  end)
end)

local owner = fake.start()
local messages, restore_notify = h.capture_notify()

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

setup(sync_to(owner))
wait(function()
  return said("Queue sync started") > 0
end)
bare("dropped in the handshake")
bare("kept in the handshake")
local X, Y = assert(by_note("dropped in the handshake")), assert(by_note("kept in the handshake"))
wait(function()
  return owner:find(X.uuid) ~= nil and owner:find(Y.uuid) ~= nil
end)

describe("a drop during the handshake, before keep is written", function()
  local started = said("Queue sync started")
  local before = #owner.requests
  -- The `list` is held, so the drop comes while the handshake waits for its reply.
  owner:delay("list", math.huge)
  setup(sync_to(owner))
  wait(function()
    return #requests(owner, "list") == 2
  end)
  in_float("dropped in the handshake", "x")
  local during = stored().removals
  owner:delay("list", nil)
  local r = requests(owner, "list")[2]
  owner:write(owner.clients[#owner.clients], vim.tbl_extend("force", { ok = true, req = r.req }, owner:snapshot()))
  wait(function()
    return said("Queue sync started") > started
  end)
  vim.wait(150)
  local after = vim.list_slice(owner.requests, before + 1)

  it("is a pending removal until the handshake sends it", function()
    assert.same(
      { X.uuid },
      vim.tbl_map(function(m)
        return m.uuid
      end, during or {})
    )
  end)

  it("goes in the remove of this handshake, before keep", function()
    assert.same(
      { "hello", "subscribe", "list", "remove", "keep" },
      vim.tbl_map(function(q)
        return q.op
      end, after)
    )
    assert.same({ X.uuid }, after[4].ids)
  end)

  it("leaves the queue owner and does not come back", function()
    assert.is_nil(owner:find(X.uuid))
    assert.is_nil(by_note("dropped in the handshake"))
    assert.is_not_nil(by_note("kept in the handshake"))
  end)

  it("is cleared after the reply", function()
    assert.is_nil(stored().removals)
  end)
end)

describe("a drop while the sync runs", function()
  local ran, r = false, nil
  owner:after("remove", function()
    ran, r = true, stored().removals
  end)
  in_float("kept in the handshake", "x")
  wait(function()
    return owner:find(Y.uuid) == nil
  end)

  it("goes to the queue owner at once, and is never a pending removal", function()
    assert.is_nil(owner:find(Y.uuid))
    assert.is_true(ran)
    assert.is_nil(r)
  end)
end)

describe("a pending removal older than 7 days", function()
  local OLD = "00000000-0000-4000-8000-000000000001"
  local FRESH = "00000000-0000-4000-8000-000000000002"
  local OLD_EDIT = "00000000-0000-4000-8000-000000000003"
  local now = os.time()
  local doc = stored()
  doc.removals = { { uuid = OLD, at = now - 8 * 24 * 60 * 60 }, { uuid = FRESH, at = now } }
  doc.unsent = { { uuid = OLD_EDIT, at = now - 8 * 24 * 60 * 60 } }
  vim.fn.writefile({ vim.json.encode(doc) }, state.global_path())
  local raw = stored()

  local started = said("Queue sync started")
  local before = #owner.requests
  setup(sync_to(owner))
  wait(function()
    return said("Queue sync started") > started and stored().removals == nil
  end)
  local removes = vim.tbl_filter(function(q)
    return q.op == "remove"
  end, vim.list_slice(owner.requests, before + 1))
  restore_notify()

  -- The control: both are on the disk before a read.
  it("is on the disk until the store is read", function()
    assert.same(2, #raw.removals)
    assert.same(1, #raw.unsent)
  end)

  it("is swept, and only the newer one goes in the remove", function()
    assert.same(1, #removes)
    assert.same({ FRESH }, removes[1].ids)
  end)

  it("is cleared with the newer one, also when the queue owner held neither", function()
    assert.is_nil(stored().removals)
  end)

  it("sweeps an unsent edit older than 7 days in the same way", function()
    assert.is_nil(state.unsent()[OLD_EDIT])
  end)

  owner:stop()
end)
