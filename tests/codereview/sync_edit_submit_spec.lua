-- A change to an entry while a **submit** goes through the **queue owner**: where the
-- `update` and `remove` of #283 meet the `send` and `sent` of #285.
--
-- The queue owner takes a batch when the `send` comes, and gives it to the agent tool before
-- it empties the queue and writes `sent`. It reads other requests meanwhile. So an edit or a
-- drop can reach it while the batch is on its way, or after the batch went.
--
-- Driven through the public surface only: `setup()`, `annotate()`, the queue float's keys,
-- the submit and the reads of the queue and the archive. The transport is real: a Unix
-- socket in a temporary directory, served by tests/fake_queue_owner.lua in this process.
--
-- The cases run from top to bottom. Each one captures its own bare notes and submits them.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))

local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

local owner = fake.start()
local messages, restore_notify = h.capture_notify()

---What the stub composer answers with.
local reply = "the note"

local codereview = require("codereview")
codereview.setup({
  syntax = false,
  types = {
    { name = "bug", key = "b", label = "Bugs", directive = "diagnose and fix these" },
    { name = "question", key = "q", label = "Questions" },
  },
  compose = function(_, on_accept)
    on_accept(nil, reply)
  end,
  pick_target = function(cb)
    cb({ short = "pane-7", id = "w1:p7", cwd = root })
  end,
  sync = {
    socket = owner.path,
    target = function(to)
      return { tool = "herdr", address = to and to.id or "none", cwd = root }
    end,
    -- Short, so that a `send` the fake holds back outlasts the submit's wait.
    wait = 200,
  },
})

---@param cond fun(): boolean
local function wait(cond)
  vim.wait(3000, cond, 10)
end

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

wait(function()
  return said("Queue sync started") > 0
end)
assert(said("Queue sync started") > 0, "the sync did not start")
view.pick_target()

---@param uuid string
---@return CRAnnotation|nil
local function entry_of(uuid)
  for _, e in ipairs(queue.entries()) do
    if e.uuid == uuid then
      return e
    end
  end
end

---The note that the queue owner holds for an entry.
---@param entry CRAnnotation
---@return table|nil
local function held(entry)
  local i = owner:find(entry.uuid)
  return i and owner.queue[i]
end

---Each copy of an entry in the archive of the entries with no repository.
---@param entry CRAnnotation
---@return CRAnnotation[]
local function archived(entry)
  local out = {}
  for _, batch in ipairs(state.global_archive()) do
    for _, e in ipairs(batch.entries or {}) do
      if e.uuid == entry.uuid then
        out[#out + 1] = e
      end
    end
  end
  return out
end

---The text of `sent` that the archive kept with the batch of an entry.
---@param entry CRAnnotation
---@return string|nil
local function text_of(entry)
  for _, batch in ipairs(state.global_archive()) do
    for _, e in ipairs(batch.entries or {}) do
      if e.uuid == entry.uuid then
        return batch.text
      end
    end
  end
end

---The `keep` requests that carried an entry.
---@param entry CRAnnotation
---@return integer
local function keeps_of(entry)
  local n = 0
  for _, r in ipairs(owner.requests) do
    if r.op == "keep" then
      for _, note in ipairs(r.notes) do
        if note.id == entry.uuid then
          n = n + 1
        end
      end
    end
  end
  return n
end

---A bare note with the note `note`, held by the queue owner.
---@param note string
---@return CRAnnotation
local function bare(note)
  vim.cmd("enew")
  reply = note
  codereview.annotate("question")
  local entry = queue.entries()[#queue.entries()]
  assert(entry.note == note)
  wait(function()
    return held(entry) ~= nil
  end)
  return entry
end

---Open the queue float with the cursor on the row of a note, press `keys`, and close the
---float if it is still open.
---@param note string
---@param keys string
local function in_float(note, keys)
  codereview.queue()
  local win = vim.api.nvim_get_current_win()
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  local row
  for i, line in ipairs(lines) do
    if line:find(note, 1, true) then
      row = i
      break
    end
  end
  assert(row, "no row in the queue float holds " .. note)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  h.feed(keys)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

---The last request of `op`.
---@param op string
---@return table|nil
local function last(op)
  for i = #owner.requests, 1, -1 do
    if owner.requests[i].op == op then
      return owner.requests[i]
    end
  end
end

describe("an edit while the queue owner gives the batch to the agent tool", function()
  local X = bare("edit me in the batch")
  local Y = bare("its neighbour")
  owner:delay("send", 1000)
  codereview.submit()
  reply = "edited while the batch goes"
  in_float("edit me in the batch", "e")
  wait(function()
    local r = last("update")
    return r ~= nil and r.id == X.uuid
  end)
  local owner_note = held(X) and held(X).note
  vim.wait(2000, function()
    return #archived(X) > 0 and #archived(Y) > 0
  end, 20)
  owner:delay("send", nil)
  vim.wait(100)

  it("reaches the queue owner before the batch leaves its queue", function()
    assert.same("edited while the batch goes", owner_note)
    assert.same(0, said("did not take an edit"))
  end)

  it("leaves the queue with the batch, and is archived once", function()
    assert.is_nil(entry_of(X.uuid))
    assert.is_nil(entry_of(Y.uuid))
    assert.same(1, #archived(X))
    assert.same(1, #archived(Y))
  end)

  -- The queue owner rendered the batch when the `send` came, so the agent read the note as
  -- it was then. The archive keeps the plugin's own copy of the entry.
  it("is archived with the note as it is in Neovim", function()
    assert.same("edited while the batch goes", archived(X)[1].note)
  end)

  -- The record of what the agent read is the text of `sent`, beside that entry.
  it("is archived with the text that the agent read, which holds the note from before the edit", function()
    local text = text_of(X) or ""
    assert.is_truthy(text:find("\nedit me in the batch\n", 1, true), text)
    assert.is_falsy(text:find("edited while the batch goes", 1, true), text)
  end)

  it("is not kept again", function()
    assert.same(1, keeps_of(X))
    assert.is_nil(held(X))
  end)
end)

describe("an edit that the queue owner reads after the batch went", function()
  local Z = bare("edit me after it went")
  owner:delay("update", math.huge)
  reply = "edited too late"
  in_float("edit me after it went", "e")
  wait(function()
    local r = last("update")
    return r ~= nil and r.id == Z.uuid
  end)
  local r = last("update")
  codereview.submit()
  wait(function()
    return #archived(Z) > 0
  end)
  local during = entry_of(Z.uuid)
  -- The queue owner reads the `update` now, after its `sent`: it no longer holds the entry.
  owner:delay("update", nil)
  owner:write(owner.clients[#owner.clients], { ok = false, error = "unknown id", req = r.req })
  vim.wait(150)

  it("is archived from the `sent`, as the update guard keeps it in the queue", function()
    assert.is_not_nil(during)
    assert.same(1, #archived(Z))
    assert.same("edited too late", archived(Z)[1].note)
  end)

  it("is archived with the text that the agent read, which does not hold the edit", function()
    local text = text_of(Z) or ""
    assert.is_truthy(text:find("edit me after it went", 1, true), text)
    assert.is_falsy(text:find("edited too late", 1, true), text)
  end)

  it("is not kept again, as it went to the agent", function()
    assert.same(1, keeps_of(Z))
    assert.is_nil(held(Z))
  end)

  it("leaves the queue once the reply comes", function()
    assert.is_nil(entry_of(Z.uuid))
  end)
end)

describe("a drop while the queue owner gives the batch to the agent tool", function()
  local W1 = bare("drop me in the batch")
  local W2 = bare("the one that stays in it")
  owner:delay("send", 1000)
  codereview.submit()
  in_float("drop me in the batch", "x")
  wait(function()
    local r = last("remove")
    return r ~= nil and r.ids[1] == W1.uuid
  end)
  vim.wait(2000, function()
    return #archived(W2) > 0
  end, 20)
  owner:delay("send", nil)
  vim.wait(100)

  it("is out of the queue at once", function()
    assert.is_nil(entry_of(W1.uuid))
    assert.is_nil(held(W1))
  end)

  -- The queue owner took the batch when the `send` came, so the entry still went, and its
  -- `sent` names it.
  it("is archived with the batch it went in", function()
    assert.same(1, #archived(W1))
    assert.same(1, #archived(W2))
  end)
end)

describe("a submit of an entry whose edit the queue owner refused", function()
  local V = bare("refuse my edit")
  owner:refuse("update", "bad request: test")
  reply = "the refused edit"
  in_float("refuse my edit", "e")
  wait(function()
    return said("did not take an edit") > 0
  end)
  owner:refuse("update", nil)
  local owner_note = held(V).note
  codereview.submit()
  wait(function()
    return #archived(V) > 0
  end)
  restore_notify()

  it("sends the note that the queue owner holds", function()
    assert.same("refuse my edit", owner_note)
  end)

  it("leaves the queue, as the snapshot took it out", function()
    assert.is_nil(entry_of(V.uuid))
  end)

  -- The entry is not in the snapshot, so the guard for a change on `unsent` does not hold it,
  -- and it departs as any submitted entry does. The archive keeps the plugin's own copy.
  it("is archived once, with the note as it is in Neovim", function()
    assert.same(1, #archived(V))
    assert.same("the refused edit", archived(V)[1].note)
  end)

  it("is archived with the text that the agent read, which holds the note the owner kept", function()
    local text = text_of(V) or ""
    assert.is_truthy(text:find("refuse my edit", 1, true), text)
    assert.is_falsy(text:find("the refused edit", 1, true), text)
  end)
end)

owner:stop()
