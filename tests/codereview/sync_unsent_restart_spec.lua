-- An edit made while no **queue owner** listens, across a restart of Neovim.
--
-- Three sessions, as in sync_restart_spec. The first two are child processes
-- (sync_restart_child.lua); the third is this process.
--
--   1. A queue owner listens. The child captures two bare notes, and the queue owner holds
--      them.
--   2. No queue owner listens. The child edits the note of one.
--   3. This process starts the sync against the same queue owner, which still holds the
--      old note.
--
-- Without the unsent list on the disk, the third session does not know that the edit is
-- not with the queue owner. The `keep` of the connect is skipped, as the queue owner holds
-- the id, and the snapshot gives back the old note, which is then written over the disk.
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
  -- Not `SystemObj:wait`, which runs only fast events: the fake answers in the main loop.
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

---The note of an entry in a list of entries or notes, by uuid without regard to case.
---@param list table[]|nil
---@param uuid string
---@return string|nil
local function note_in(list, uuid)
  for _, item in ipairs(list or {}) do
    if (item.uuid or item.id):lower() == uuid then
      return item.note
    end
  end
end

local first, first_text, first_code = session({
  MODE = "capture",
  SOCKET = owner.path,
  NOTES = "the old note,left alone",
})
local D = first["the old note"]

describe("the first session, with a queue owner", function()
  it("exits cleanly", function()
    assert.same(0, first_code, first_text)
  end)

  it("leaves the note with the queue owner", function()
    assert.same("the old note", note_in(owner.queue, D), first_text)
  end)
end)

local _, second_text, second_code = session({
  MODE = "away",
  SOCKET = vim.fn.tempname() .. ".sock",
  EDIT = "the old note=typed while away",
})

describe("the second session, with no queue owner", function()
  it("exits cleanly", function()
    assert.same(0, second_code, second_text)
  end)

  it("writes the edit to the disk, and the entry on the unsent list", function()
    assert.same("typed while away", note_in(stored().queue, D))
    assert.same(
      { D },
      vim.tbl_map(function(m)
        return m.uuid
      end, stored().unsent or {})
    )
  end)

  -- The control: the queue owner must still hold the old note, or the next connect has
  -- nothing to lose.
  it("leaves the old note with the queue owner", function()
    assert.same("the old note", note_in(owner.queue, D))
  end)
end)

describe("the next connect, after the restart", function()
  local before = #owner.requests
  local messages, restore = h.capture_notify()
  require("codereview").setup({
    syntax = false,
    types = { { name = "question", key = "q", label = "Questions" } },
    sync = {
      socket = owner.path,
      target = function()
        return { tool = "custom", address = "agent", cwd = root }
      end,
    },
  })
  vim.wait(5000, function()
    return h.notified(messages, "Queue sync started") and note_in(owner.queue, D) ~= "the old note"
  end, 10)
  vim.wait(200)
  restore()
  local after = vim.list_slice(owner.requests, before + 1)

  it("sends the edit with update, after keep", function()
    assert.same(
      { "hello", "subscribe", "list", "keep", "update" },
      vim.tbl_map(function(r)
        return r.op
      end, after)
    )
    assert.same(D, after[5].id:lower())
    assert.same("typed while away", after[5].note)
  end)

  it("gives the queue owner the note typed while it was away", function()
    assert.same("typed while away", note_in(owner.queue, D))
  end)

  it("keeps the typed note in the queue and on disk", function()
    assert.same("typed while away", note_in(queue.entries(), D))
    assert.same("typed while away", note_in(stored().queue, D))
  end)

  it("takes the entry off the unsent list", function()
    assert.is_nil(stored().unsent)
  end)

  owner:stop()
end)
