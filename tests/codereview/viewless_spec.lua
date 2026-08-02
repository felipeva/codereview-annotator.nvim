-- The queue without a review view.
--
-- The float, the target picker and the batch submit already work with nothing open; only
-- persistence was tied to a view, which meant an annotation captured outside a review
-- would queue, submit and then be lost on exit.
--
-- Two processes, like state_spec and for the same reason: persistence is only meaningfully
-- tested across a genuine restart.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local view = require("codereview.view")
local queue = require("codereview.queue")
local state = require("codereview.state")

local sent = {}
local offered = 0
require("codereview").setup({
  syntax = false,
  send = function(text, target)
    sent[#sent + 1] = { text = text, target = target }
  end,
  pick_target = function(cb)
    offered = offered + 1
    cb({ short = "agent", pane_id = "wV:p9", cwd = fixture })
  end,
})

local root = assert(vim.uv.fs_realpath(fixture))

describe("the writing process", function()
  local cmd = {
    vim.v.progpath,
    "--clean",
    "-l",
    vim.fs.joinpath(h.root, "tests", "codereview", "viewless_child.lua"),
  }
  local proc = vim.system(cmd, {
    cwd = fixture,
    text = true,
    env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = fixture },
  })
  local child = proc:wait(60000)

  it("exits cleanly", function()
    assert.same(0, child.code, (child.stderr or "") .. (child.stdout or ""))
  end)

  it("writes the viewless queue to disk", function()
    local data = state.load(root)
    assert.same(2, #data.queue)
  end)

  -- The write happened with no view, so it had no `per_scope` to build a scopes table
  -- from. Writing what it did have would have blanked the reviewed marks phase 1 saved.
  it("does not clobber the reviewed marks it could not see", function()
    local data = state.load(root)
    assert.is_truthy(next(data.scopes), "every reviewed mark was lost")
  end)
end)

describe("a cold start with no review view", function()
  it("starts with nothing open and nothing in memory", function()
    assert.is_nil(view.current())
    assert.same(0, queue.count())
  end)

  it("restores the queue when the float is opened", function()
    view.review_queue()
    assert.same(2, queue.count())
    assert.is_nil(view.current(), "opening the float should not open a review view")
  end)

  it("restores each annotation intact", function()
    assert.same(
      { "bug", "nitpick" },
      vim.tbl_map(function(i)
        return i.type
      end, queue.all())
    )
    assert.same("queued with no view", queue.all()[1].note)
    assert.same("src/routes.lua", queue.all()[1].path)
  end)

  it("continues ids past the restored entries", function()
    local before = queue.count()
    queue.add({ type = "bug", kind = "file", path = "x", key = "x:f:0", note = "n" })

    local seen, dupes = {}, 0
    for _, item in ipairs(queue.all()) do
      dupes = dupes + (seen[item.id] and 1 or 0)
      seen[item.id] = true
    end

    queue.remove(queue.all()[#queue.all()].id)
    assert.same(0, dupes)
    assert.same(before, queue.count())
  end)
end)

describe("opening a review view afterwards", function()
  view.open("branch")
  local V = assert(view.current())

  it("keeps the restored queue rather than discarding it", function()
    assert.same(2, queue.count())
  end)

  it("still has the reviewed mark from the first process", function()
    assert.is_not_nil(V.reviewed["src/main.lua"])
  end)
end)

describe("submitting with no review view", function()
  view.close()

  it("closed the view", function()
    assert.is_nil(view.current())
  end)

  it("sends the batch", function()
    view.submit()
    assert.same(1, #sent)
    assert.same(0, queue.count())
  end)

  -- Submitting used to persist only when a view was open, so a viewless submit emptied
  -- the queue in memory and left the old entries on disk to be restored next start.
  it("clears the persisted queue too", function()
    assert.same(0, #state.load(root).queue)
  end)

  it("still leaves the reviewed marks alone", function()
    assert.is_truthy(next(state.load(root).scopes))
  end)
end)

-- The queue moved off the view because it is what you submit, not what you are looking at.
-- The target is what you submit *to*, and it stayed behind: the picker ran, the answer was
-- thrown away, and the batch went to the default destination having just asked.
describe("choosing a delivery target with no review view", function()
  local before_sent = #sent

  queue.clear()
  queue.add({
    type = "bug",
    kind = "file",
    path = "src/routes.lua",
    abs_path = vim.fs.joinpath(root, "src/routes.lua"),
    key = "src/routes.lua:f:0",
    note = "routed with nothing open",
  })

  assert(view.current() == nil, "this case is about having no view")
  view.pick_target()

  it("asked the configured picker", function()
    assert.same(1, offered)
  end)

  it("names the chosen target in the queue float", function()
    view.review_queue()
    local win = vim.api.nvim_get_current_win()
    local footer = vim.api.nvim_win_get_config(win).footer
    local text = type(footer) == "table" and footer[1][1] or tostring(footer)
    vim.api.nvim_win_close(win, true)
    assert.is_truthy(text:find("agent", 1, true), text)
  end)

  it("submits to it rather than to the default", function()
    view.submit()
    assert.same(before_sent + 1, #sent)
    assert.is_not_nil(sent[#sent].target, "the chosen target was discarded")
    assert.same("wV:p9", sent[#sent].target.pane_id)
  end)
end)

describe("a target chosen while a review was open", function()
  local cfg = require("codereview.config").get()
  local chooses_agent = cfg.pick_target
  local before_sent = #sent

  -- Cleared first, so nothing below can pass on what the previous case left behind.
  cfg.pick_target = function(cb)
    cb(nil)
  end
  view.pick_target()
  cfg.pick_target = chooses_agent

  queue.clear()
  queue.add({
    type = "bug",
    kind = "file",
    path = "src/fresh.lua",
    abs_path = vim.fs.joinpath(root, "src/fresh.lua"),
    key = "src/fresh.lua:f:0",
    note = "routed from inside a review",
  })

  view.open("branch")
  assert(view.current(), "the review did not open")
  view.pick_target()
  view.close()

  it("outlives the review view, the way the queue does", function()
    assert.is_nil(view.current())
    view.submit()
    assert.same(before_sent + 1, #sent)
    assert.is_not_nil(sent[#sent].target, "closing the review dropped the target")
    assert.same("wV:p9", sent[#sent].target.pane_id)
  end)
end)
