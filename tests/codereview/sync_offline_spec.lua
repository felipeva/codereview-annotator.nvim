-- The `sync` option at setup, and the **sync** while no **queue owner** listens: the checks
-- on a wrong value, the silent failed connect, and the retry at most once every 2 s.
--
-- One deliberate wait of about 2 s, in the retry case: the interval is the behavior, and a
-- shorter interval for tests would be an option that no host needs.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local codereview = require("codereview")
local config = require("codereview.config")
local queue = require("codereview.queue")

local function target()
  return { tool = "custom", address = "agent", cwd = fixture }
end

local function compose(_, on_accept)
  on_accept(nil, "the note")
end

---@param sync any
---@return string message
local function refused(sync)
  local ok, err = pcall(codereview.setup, { syntax = false, sync = sync })
  assert.is_false(ok)
  return tostring(err)
end

local function capture()
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
  codereview.annotate("bug")
end

describe("the sync option at setup", function()
  it("is off when the host does not give it", function()
    codereview.setup({ syntax = false })
    assert.is_nil(config.get().sync)
  end)

  it("refuses a value that is not a table", function()
    assert.is_truthy(refused("/tmp/q.sock"):find("`sync` must be a table", 1, true))
  end)

  it("refuses a socket that is not a path", function()
    assert.is_truthy(
      refused({ socket = 1, target = target }):find("`sync.socket` must be the path of a socket", 1, true)
    )
    assert.is_truthy(
      refused({ socket = "", target = target }):find("`sync.socket` must be the path of a socket", 1, true)
    )
  end)

  it("refuses a target that is not a function", function()
    assert.is_truthy(refused({ socket = "/tmp/q.sock" }):find("`sync.target` must be a function", 1, true))
  end)

  it("expands the socket path", function()
    codereview.setup({ syntax = false, sync = { socket = "~/codereview-nowhere.sock", target = target } })
    assert.same(vim.fs.joinpath(vim.fn.expand("~"), "codereview-nowhere.sock"), config.get().sync.socket)
  end)
end)

describe("a socket that refuses the connect", function()
  -- Bound and not listening: a connect to it fails with ECONNREFUSED.
  local path = vim.fn.tempname() .. ".sock"
  local bound = vim.uv.new_pipe(false)
  assert(bound:bind(path))

  local messages, restore = h.capture_notify()
  codereview.setup({ syntax = false, compose = compose, sync = { socket = path, target = target } })
  vim.wait(200)
  capture()
  vim.wait(200)
  restore()
  bound:close()

  it("says nothing about the sync", function()
    for _, m in ipairs(messages) do
      assert.is_falsy(m:lower():find("sync", 1, true), m)
    end
  end)

  it("keeps the capture in the plugin's own queue, as without sync", function()
    assert.same(1, queue.count())
    assert.is_true(h.notified(messages, "Queued bug src/main.lua (whole file) (1 in queue)"))
  end)
end)

describe("a socket that does not exist", function()
  local path = vim.fn.tempname() .. ".sock"
  local messages, restore = h.capture_notify()
  local started = vim.uv.hrtime() / 1e6
  codereview.setup({ syntax = false, compose = compose, sync = { socket = path, target = target } })
  vim.wait(100)

  -- The queue owner starts after the failed connect, and a capture comes at once.
  local owner = fake.start(path)
  capture()
  vim.wait(300)
  local early = #owner.requests

  -- The next queue operation, 2 s after the first attempt.
  vim.wait(math.max(0, 2100 - (vim.uv.hrtime() / 1e6 - started)))
  capture()
  vim.wait(3000, function()
    return #owner.requests >= 3
  end, 10)
  vim.wait(3000, function()
    return h.notified(messages, "Queue sync started")
  end, 10)
  restore()

  it("does not try again sooner than 2 s after the last attempt", function()
    assert.same(0, early)
  end)

  it("tries again on the next queue operation after that, in the fixed order", function()
    assert.same({ "hello", "subscribe", "keep" }, owner:ops())
  end)

  it("gives the queue owner every entry in the local queue", function()
    local kept = vim.tbl_map(function(n)
      return n.id:lower()
    end, owner.requests[3].notes)
    local here = vim.tbl_map(function(e)
      return e.uuid
    end, queue.entries())
    assert.same(here, kept)
    assert.same(3, #kept)
  end)

  owner:stop()
end)
