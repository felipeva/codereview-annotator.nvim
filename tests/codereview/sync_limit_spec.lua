-- The queue owner's line limit: a line longer than it closes the connection. The connect
-- gives the queue owner every entry, so a large queue must go in more than one `keep`.
--
-- The fake's limit is set to 2 MiB, so a queue of about 2.8 MiB is enough to pass it. The
-- plugin's own batch size does not change for the test: what is tested is that no line of
-- the connect is longer than the queue owner takes.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local codereview = require("codereview")
local state = require("codereview.state")

local owner = fake.start()
owner.max_line = 2 * 1024 * 1024

local UUIDS = {
  "4a1b2c3d-0e1f-4a2b-8c3d-4e5f6a7b8c9d",
  "4a1b2c3d-1e1f-4a2b-8c3d-4e5f6a7b8c9d",
  "4a1b2c3d-2e1f-4a2b-8c3d-4e5f6a7b8c9d",
  "4a1b2c3d-3e1f-4a2b-8c3d-4e5f6a7b8c9d",
}
local big = {}
for i, uuid in ipairs(UUIDS) do
  big[#big + 1] = {
    id = i,
    uuid = uuid,
    type = "bug",
    kind = "note",
    key = "note:0",
    inline = false,
    note = string.rep("x", 700 * 1024),
    at = os.time(),
  }
end
vim.fn.mkdir(vim.fs.dirname(state.global_path()), "p")
vim.fn.writefile({ vim.json.encode({ version = 1, archive = {}, queue = big }) }, state.global_path())

local messages, restore_notify = h.capture_notify()
codereview.setup({
  syntax = false,
  sync = {
    socket = owner.path,
    target = function()
      return { tool = "custom", address = "agent", cwd = fixture }
    end,
  },
})
vim.wait(5000, function()
  return h.notified(messages, "Queue sync started")
end, 10)
restore_notify()

describe("a queue larger than the queue owner's line limit", function()
  it("goes to the queue owner whole, in lines under the limit", function()
    assert.is_true(h.notified(messages, "Queue sync started"))
    local held = vim.tbl_map(function(n)
      return n.id:lower()
    end, owner.queue)
    assert.same(UUIDS, held)
  end)
end)

owner:stop()
