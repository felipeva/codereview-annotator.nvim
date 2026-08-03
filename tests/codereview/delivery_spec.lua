-- What a send adapter is allowed to say, and the one condition that empties the queue.
--
-- The seam is the injected adapter, because that is the plugin's real contract with a
-- host. Every case drives `setup` and the ordinary entry points and asserts on what the
-- stub was handed, on the queue behind it, on the `+` register and on what the reviewer
-- was told -- never on how a surface hands a batch over, which is the plugin's business
-- and has already moved once.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local codereview = require("codereview")
local config = require("codereview.config")
local drafts = require("codereview.drafts")
local queue = require("codereview.queue")

-- Resolved, because capture realpaths every path it records and a draft is keyed by the
-- absolute one. On macOS the fixture lives under a `/var` symlink, so the unresolved form
-- would look up a key nothing ever wrote.
local main = assert(vim.uv.fs_realpath(vim.fs.joinpath(fixture, "src/main.lua")))

local sent = {}

---The adapter every case starts from: it dispatches, and says nothing about it.
local function records(text, target)
  sent[#sent + 1] = { text = text, target = target }
end

codereview.setup({ syntax = false, send = records })

-- Swapped in place rather than through `setup`, which would reset every other adapter
-- with it. Each case puts back what it found.
local cfg = config.get()

---One queued annotation, so every batch is of a known size and carries its own marker.
---@param note string
local function queue_one(note)
  queue.clear()
  queue.add({
    type = "bug",
    kind = "file",
    path = "src/main.lua",
    abs_path = main,
    key = "src/main.lua:f:0",
    note = note,
  })
end

describe("an adapter that returns nothing", function()
  queue_one("returns nothing at all")
  local msgs, restore = h.capture_notify()
  codereview.submit()
  restore()

  it("is handed the rendered batch", function()
    assert.same(1, #sent)
    assert.is_truthy(sent[1].text:find("returns nothing at all", 1, true), sent[1].text)
  end)

  -- The compatibility rule the optional return exists to protect: every adapter wired
  -- today returns nothing, and nothing has to keep meaning it went.
  it("empties the queue", function()
    assert.same(0, queue.count())
  end)

  it("confirms what was submitted", function()
    assert.is_true(h.notified(msgs, "Submitted 1 annotation"), vim.inspect(msgs))
  end)
end)

describe("an adapter that returns true", function()
  cfg.send = function(text, target)
    records(text, target)
    return true
  end
  queue_one("returns true")
  codereview.submit()
  cfg.send = records

  it("is handed the batch", function()
    assert.same(2, #sent)
    assert.is_truthy(sent[2].text:find("returns true", 1, true), sent[2].text)
  end)

  it("empties the queue", function()
    assert.same(0, queue.count())
  end)
end)

describe("an adapter that returns false with a reason", function()
  cfg.send = function(text, target)
    records(text, target)
    return false, "the agent pane is gone"
  end
  queue_one("declined by the adapter")
  local msgs, restore = h.capture_notify()
  codereview.submit()
  restore()
  cfg.send = records

  it("was still handed the batch", function()
    assert.same(3, #sent)
  end)

  -- Nothing consumed it, so dropping it would lose the review.
  it("keeps the queue", function()
    assert.same(1, queue.count())
  end)

  it("warns with the reason the adapter gave", function()
    assert.is_true(h.notified(msgs, "the agent pane is gone"), vim.inspect(msgs))
  end)

  it("does not claim to have submitted anything", function()
    assert.is_false(h.notified(msgs, "Submitted"), vim.inspect(msgs))
  end)

  -- The point of keeping it: the note was typed once, and a host that comes back should
  -- not cost it. The count still describes what is really there.
  it("can be retried without retyping the note", function()
    codereview.submit()
    assert.same(4, #sent)
    assert.is_truthy(sent[4].text:find("declined by the adapter", 1, true), sent[4].text)
    assert.same(0, queue.count())
  end)
end)

describe("an adapter that raises", function()
  cfg.send = function()
    error("herdr: no such pane")
  end
  queue_one("raised at the adapter")
  local msgs, restore = h.capture_notify()
  codereview.submit()
  restore()
  cfg.send = records

  -- Preserved by the rule rather than by the error unwinding past the line that clears
  -- the queue, which is how a missing binary used to leave it intact.
  it("keeps the queue", function()
    assert.same(1, queue.count())
  end)

  it("reads as a sentence rather than a traceback", function()
    assert.is_true(h.notified(msgs, "herdr: no such pane"), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "Submitted"), vim.inspect(msgs))
  end)
end)

describe("no adapter at all", function()
  cfg.send = nil
  vim.fn.setreg("+", "")
  queue_one("nothing consumed this")
  local msgs, restore = h.capture_notify()
  codereview.submit()
  restore()
  cfg.send = records

  it("copies the payload to the + register", function()
    assert.is_truthy(vim.fn.getreg("+"):find("nothing consumed this", 1, true), vim.fn.getreg("+"))
  end)

  -- The same rule as an adapter declining, reached without a branch: the default
  -- implementation of the contract reports that nothing took the batch.
  it("keeps the queue", function()
    assert.same(1, queue.count())
  end)

  it("says where it went instead", function()
    assert.is_true(h.notified(msgs, "No send adapter configured"), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "Submitted"), vim.inspect(msgs))
  end)
end)

-- Submitted through the review's own key, because what a surface hands delivery is not
-- something to assert on directly -- it is observable in the payload the adapter receives.
describe("a batch submitted from a review view", function()
  codereview.open("branch")
  queue_one("submitted from the view")
  local before = #sent
  h.feed("<C-s>")

  it("carries what the review can say about itself", function()
    assert.same(before + 1, #sent)
    local header = vim.split(sent[#sent].text, "\n")[1]
    assert.is_truthy(header:find("on branch vs ", 1, true), header)
    assert.is_truthy(header:find("reviewed)", 1, true), header)
  end)

  it("empties the queue and repaints what is left", function()
    assert.same(0, queue.count())
    assert.same(0, #h.virt_marks(assert(require("codereview.view").current())))
  end)
end)

describe("an immediate send that was dispatched", function()
  drafts.clear()
  cfg.compose = function(_, on_accept)
    on_accept(nil, "an errand that landed")
  end
  queue.clear()
  codereview.close()
  vim.cmd("edit " .. vim.fn.fnameescape(main))
  local msgs, restore = h.capture_notify()
  codereview.annotate("bug", nil, { immediate = true })
  restore()

  it("says it was sent", function()
    assert.is_truthy(sent[#sent].text:find("an errand that landed", 1, true), sent[#sent].text)
    assert.is_true(h.notified(msgs, "Sent bug"), vim.inspect(msgs))
  end)

  -- The composer committed its draft on submit, and a note that reached someone has
  -- nothing left to restore.
  it("leaves no draft behind", function()
    assert.is_nil(drafts.get(main))
  end)
end)

-- A batch of one is governed by the same rule (ADR-0004, ADR-0005), and it has nowhere
-- else to put a note that did not go: the queue is not where an errand lands, and by the
-- time delivery answers, the composer has closed its window, wiped its buffer and
-- committed its draft. Without somewhere to put it, the note the reviewer just typed is
-- unrecoverable.
describe("an immediate send that was not dispatched", function()
  drafts.clear()
  cfg.compose = function(_, on_accept)
    on_accept(nil, "an errand nobody took")
  end
  cfg.send = function(text, target)
    records(text, target)
    return false, "the pane went away mid-errand"
  end
  local before = #sent
  local msgs, restore = h.capture_notify_levels()
  codereview.annotate("bug", nil, { immediate = true })
  restore()
  cfg.send = records

  it("was handed the note", function()
    assert.same(before + 1, #sent)
  end)

  it("says why it did not go", function()
    assert.is_true(h.notified(msgs, "the pane went away mid-errand"), vim.inspect(msgs))
  end)

  it("does not claim to have sent it", function()
    assert.is_false(h.notified(msgs, "Sent bug"), vim.inspect(msgs))
  end)

  -- An errand still does not disturb a batch, whichever way it ended.
  it("leaves the queue out of it", function()
    assert.same(0, queue.count())
  end)

  it("keeps the note as a draft for the file it was about", function()
    assert.same("an errand nobody took", drafts.get(main))
  end)

  it("says the note was kept, and names the file to get it back from", function()
    assert.is_true(h.notified(msgs, "kept as a draft"), vim.inspect(msgs))
    assert.is_true(h.notified(msgs, "src/main.lua"), vim.inspect(msgs))
  end)

  -- An annotation that reached nobody is a failure, not a remark about the weather.
  it("reports it at error level", function()
    assert.same(vim.log.levels.ERROR, h.notified_level(msgs, "the pane went away mid-errand"))
  end)
end)

-- The proof that "kept" means what it says: the draft store is what the composer reads on
-- the way in, so the note comes back the next time that file is annotated.
describe("the note an undispatched send kept", function()
  -- The shipped composer, because it is the one that restores drafts -- a host that wires
  -- its own owns that, exactly as it owns everything else about collecting text.
  cfg.compose = nil
  codereview.annotate("bug", nil, { immediate = true })
  local reopened = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  h.feed("q")

  it("is offered back the next time that file is annotated", function()
    assert.same({ "an errand nobody took" }, reopened)
  end)
end)

describe("an immediate send whose adapter raised", function()
  drafts.clear()
  cfg.compose = function(_, on_accept)
    on_accept(nil, "an errand that blew up")
  end
  cfg.send = function()
    error("herdr: no such pane")
  end
  local msgs, restore = h.capture_notify_levels()
  codereview.annotate("bug", nil, { immediate = true })
  restore()
  cfg.send = records

  it("keeps the note as a draft too", function()
    assert.same("an errand that blew up", drafts.get(main))
  end)

  it("reads as a sentence at error level, not a traceback", function()
    assert.is_true(h.notified(msgs, "herdr: no such pane"), vim.inspect(msgs))
    assert.is_true(h.notified(msgs, "kept as a draft"), vim.inspect(msgs))
    assert.same(vim.log.levels.ERROR, h.notified_level(msgs, "herdr: no such pane"))
  end)

  it("still leaves the queue out of it", function()
    assert.same(0, queue.count())
  end)
end)

-- Nothing wired is a configuration state, not a failure: the payload is in the register,
-- and saying it in red would cry wolf on the plugin's own default. The note is still kept.
describe("an immediate send with no adapter wired", function()
  drafts.clear()
  cfg.compose = function(_, on_accept)
    on_accept(nil, "an errand with nowhere to go")
  end
  cfg.send = nil
  local msgs, restore = h.capture_notify_levels()
  codereview.annotate("bug", nil, { immediate = true })
  restore()
  cfg.send = records
  cfg.compose = nil

  it("reports it at warning level", function()
    assert.same(vim.log.levels.WARN, h.notified_level(msgs, "No send adapter configured"))
  end)

  -- The register holding the payload is not the note having reached anyone, and a
  -- reviewer who wires an adapter tomorrow should still find what they wrote.
  it("keeps the note as a draft anyway", function()
    assert.same("an errand with nowhere to go", drafts.get(main))
  end)
end)
