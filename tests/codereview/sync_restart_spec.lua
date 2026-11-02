-- **Pending removals** across a restart of Neovim.
--
-- Three sessions. The first two are child processes (sync_restart_child.lua); the third is
-- this process. The queue is read back once per session, so only a new process can show
-- what a session left on the disk.
--
--   1. A queue owner listens. The child captures three bare notes, and the queue owner
--      holds them.
--   2. No queue owner listens. The child drops one, submits the other two through the
--      `send` adapter, and captures a fourth.
--   3. This process starts the sync against the same queue owner, which still holds the
--      first three.
--
-- The fake queue owner runs in this process. A child is waited for with `vim.wait`, not
-- with `SystemObj:wait`, which runs only fast events: the fake answers in the main loop.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))

local state = require("codereview.state")
local queue = require("codereview.queue")

local owner = fake.start()

---Run one session of the child, and give the uuid of each entry it printed, by note.
---@param env table<string, string>
---@return table<string, string> uuids, string text, integer code
local function session(env)
  local done
  vim.system(
    { vim.v.progpath, "--clean", "-l", vim.fs.joinpath(h.root, "tests", "codereview", "sync_restart_child.lua") },
    {
      cwd = fixture,
      text = true,
      env = vim.tbl_extend("force", { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = fixture }, env),
    },
    function(out)
      done = out
    end
  )
  assert(vim.wait(60000, function()
    return done ~= nil
  end, 10))
  -- `-l` prints to stderr, so both streams are read.
  local text = (done.stdout or "") .. (done.stderr or "")
  local uuids = {}
  for line in text:gmatch("[^\r\n]+") do
    local note, uuid = line:match("^entry: (.-) (%S+)$")
    if note then
      uuids[note] = uuid
    end
  end
  return uuids, text, done.code
end

---The store for entries with no repository, as written to disk.
---@return table
local function stored()
  return vim.json.decode(
    table.concat(vim.fn.readfile(state.global_path()), "\n"),
    { luanil = { object = true, array = true } }
  )
end

---@param marks table[]|nil
---@return string[]
local function uuids_of(marks)
  local out = vim.tbl_map(function(m)
    return m.uuid
  end, marks or {})
  table.sort(out)
  return out
end

---@param list string[]
---@return string[]
local function sorted(list)
  list = vim.deepcopy(list)
  table.sort(list)
  return list
end

local first, first_text, first_code = session({
  MODE = "capture",
  SOCKET = owner.path,
  NOTES = "dropped away,sent away one,sent away two",
})
local A, B, C = first["dropped away"], first["sent away one"], first["sent away two"]

describe("the first session, with a queue owner", function()
  it("exits cleanly", function()
    assert.same(0, first_code, first_text)
  end)

  -- The control: without it, a `remove` that removes nothing would pass every case below.
  it("leaves the three notes with the queue owner", function()
    assert.same(3, #owner.queue)
    for _, uuid in ipairs({ A, B, C }) do
      assert.is_not_nil(owner:find(uuid), first_text)
    end
  end)
end)

local second, second_text, second_code = session({
  MODE = "away",
  SOCKET = vim.fn.tempname() .. ".sock",
  DROP = "dropped away",
  SUBMIT = "1",
  CAPTURE = "captured away",
})
local E = second["captured away"]

describe("the second session, with no queue owner", function()
  it("exits cleanly, with only the new capture in its queue", function()
    assert.same(0, second_code, second_text)
    assert.same({ "captured away" }, vim.tbl_keys(second))
  end)

  it("writes the drop and the dispatch as pending removals, in the store with no root", function()
    assert.same(sorted({ A, B, C }), uuids_of(stored().removals))
  end)

  it("does not make the new capture a pending removal", function()
    assert.is_false(vim.tbl_contains(uuids_of(stored().removals), E))
  end)
end)

describe("the next connect, after the restart", function()
  local before = #owner.requests
  -- An event between `subscribe` and the reply to `list` that still holds the three notes,
  -- as another client's change makes one. Without a guard from the start of the handshake,
  -- the three come back into the queue, and `keep` gives them to the queue owner again.
  owner:after("subscribe", function(o)
    o:push_queue(vim.deepcopy(o.queue))
  end)
  local messages, restore = h.capture_notify()
  require("codereview").setup({
    syntax = false,
    sync = {
      socket = owner.path,
      target = function()
        return { tool = "custom", address = "agent", cwd = root }
      end,
    },
  })
  vim.wait(5000, function()
    return h.notified(messages, "Queue sync started") and stored().removals == nil
  end, 10)
  vim.wait(200)
  restore()
  local after = vim.list_slice(owner.requests, before + 1)

  it("sends remove with the pending removals after list, and before keep", function()
    assert.same(
      { "hello", "subscribe", "list", "remove", "keep" },
      vim.tbl_map(function(r)
        return r.op
      end, after)
    )
    assert.same(sorted({ A, B, C }), sorted(after[4].ids))
  end)

  it("gives the queue owner the capture made while it was away, and only that", function()
    assert.same(
      { E },
      vim.tbl_map(function(n)
        return n.id:lower()
      end, after[5].notes)
    )
  end)

  it("leaves the queue owner with only that capture", function()
    assert.same(
      { E },
      vim.tbl_map(function(n)
        return n.id:lower()
      end, owner.queue)
    )
  end)

  it("does not bring the dropped and the dispatched entries back", function()
    assert.same(
      { E },
      vim.tbl_map(function(e)
        return e.uuid
      end, queue.entries())
    )
  end)

  it("clears the pending removals after the reply", function()
    assert.is_nil(stored().removals)
  end)

  owner:stop()
end)
