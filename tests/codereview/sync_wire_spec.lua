-- What the plugin writes on the wire, and the replies it waits for: a change that another
-- client makes between `hello` and `subscribe`, text that is not valid UTF-8, and a request
-- whose reply never comes.
--
-- One deliberate wait of about 5 s: a request waits that long for its reply, and the wait is
-- the behavior under test.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local codereview = require("codereview")
local queue = require("codereview.queue")

local owner = fake.start()

-- An entry of this plugin from another Neovim, kept between this client's `hello` and its
-- `subscribe`. The queue owner sends the change to subscribers only, so this client gets no
-- event for it.
local OTHER = "5D4C3B2A-1F0E-4D9C-8B7A-6F5E4D3C2B1A"
owner:after("hello", function(o)
  o.queue[#o.queue + 1] = {
    id = OTHER,
    type = "bug",
    note = "kept by another Neovim before this one subscribed",
    selection = { none = vim.empty_dict() },
    source = { appName = "nvim" },
    createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    review = { kind = "note", inline = false, stale = false },
    origin = { client = "codereview.nvim", key = "note:0", at = os.time() },
  }
  o:changed()
end)

local text = "the note"
local messages, restore_notify = h.capture_notify()
codereview.setup({
  syntax = false,
  compose = function(_, on_accept)
    on_accept(nil, text)
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

vim.wait(5000, function()
  return said("Queue sync started") > 0
end, 10)

describe("a change between hello and subscribe", function()
  it("is in the queue once the connect is complete", function()
    assert.same({ "hello", "subscribe", "list" }, owner:ops())
    assert.is_not_nil(entry_of(OTHER))
  end)
end)

describe("a note that is not valid UTF-8", function()
  text = "a\255b\192\175c"
  local before = #owner.requests
  vim.cmd("enew")
  codereview.annotate("bug")
  local entry = queue.all()[#queue.all()]
  vim.wait(3000, function()
    return owner:find(entry.uuid) ~= nil
  end, 10)
  text = "the note"

  it("reaches the queue owner, with each byte that is not UTF-8 as U+FFFD", function()
    assert.same(before + 1, #owner.requests)
    local R = "\239\191\189"
    assert.same("a" .. R .. "b" .. R .. R .. "c", owner.queue[owner:find(entry.uuid)].note)
  end)
end)

describe("a keep whose reply never comes", function()
  owner:delay("keep", math.huge)
  local started = vim.uv.hrtime() / 1e6
  vim.cmd("enew")
  codereview.annotate("bug")
  local entry = queue.all()[#queue.all()]
  vim.wait(8000, function()
    return said("no reply") > 0
  end, 10)
  local waited = vim.uv.hrtime() / 1e6 - started
  owner:delay("keep", nil)

  -- A snapshot without the entry, made visible by a changed note on one that it holds.
  local held = vim.deepcopy(owner.queue)
  held[1].note = "seen by the queue owner"
  owner:push_queue(held)
  vim.wait(3000, function()
    return entry_of(OTHER).note == "seen by the queue owner"
  end, 10)
  restore_notify()

  it("counts as refused after 5 s, and is said once", function()
    assert.same(1, said("did not take 1 annotation (no reply)"))
    assert.is_true(waited >= 4900, tostring(waited))
  end)

  it("stays in the local queue after a snapshot that does not hold it", function()
    assert.is_not_nil(entry_of(entry.uuid))
    assert.is_nil(owner:find(entry.uuid))
  end)
end)

owner:stop()
