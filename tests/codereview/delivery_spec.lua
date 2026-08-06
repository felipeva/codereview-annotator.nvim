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
local state = require("codereview.state")

-- Resolved, because capture realpaths every path it records and a draft is keyed by the
-- absolute one. On macOS the fixture lives under a `/var` symlink, so the unresolved form
-- would look up a key nothing ever wrote.
local main = assert(vim.uv.fs_realpath(vim.fs.joinpath(fixture, "src/main.lua")))
local root = assert(vim.uv.fs_realpath(fixture))

---The batches this repository has kept, through the accessor a surface would use.
---
---A dispatch is the one condition that empties the queue, and it is the one condition that
---writes here (ADR-0005): a payload sitting in a register is not something an agent
---received. Every case below therefore asserts on this exactly as it asserts on the queue.
---@return CRBatch[]
local function archived()
  return state.archive(root)
end

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
  local before = #archived()
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

  -- The same condition, doing its second job: what left the queue is kept rather than
  -- forgotten, so a reviewer can still read what they asked for after asking for it.
  it("records the batch in the archive", function()
    assert.same(before + 1, #archived())
    assert.same("returns nothing at all", archived()[1].entries[1].note)
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
  local before = #archived()
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

  -- Nothing received it, so recording that it went would make a failed send look like a
  -- delivered one for as long as the archive is kept.
  it("leaves the archive exactly as it was", function()
    assert.same(before, #archived())
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
  local before = #archived()
  local msgs, restore = h.capture_notify()
  codereview.submit()
  restore()
  cfg.send = records

  -- Preserved by the rule rather than by the error unwinding past the line that clears
  -- the queue, which is how a missing binary used to leave it intact.
  it("keeps the queue", function()
    assert.same(1, queue.count())
  end)

  it("leaves the archive alone too", function()
    assert.same(before, #archived())
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
  local before = #archived()
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

  -- A register is not a consumer, so there is nothing to record having been asked for.
  it("archives nothing, because a copy is not a dispatch", function()
    assert.same(before, #archived())
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

  -- What went is still on the diff, dimmed, which is the archive's whole point -- so the
  -- repaint is observable as the queue's own projection being empty while the rows below
  -- the code are drawn in the archive's groups rather than a type's.
  it("empties the queue and repaints what is left", function()
    assert.same(0, queue.count())
    local V = assert(require("codereview.view").current())
    assert.same({}, V.notes)
    local groups = h.virt_groups(V)
    assert.is_true(groups.CodeReviewArchived or false, vim.inspect(vim.tbl_keys(groups)))
    assert.is_nil(groups.CodeReviewBug, vim.inspect(vim.tbl_keys(groups)))
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
  local before = #archived()
  local msgs, restore = h.capture_notify()
  codereview.annotate("bug", nil, { immediate = true })
  restore()

  it("says it was sent", function()
    assert.is_truthy(sent[#sent].text:find("an errand that landed", 1, true), sent[#sent].text)
    assert.is_true(h.notified(msgs, "Sent bug"), vim.inspect(msgs))
  end)

  -- An errand is a batch of one (ADR-0004) and is archived as one, by the same rule and
  -- through the same function -- not by a second path that agrees with this one today.
  it("archives as a batch of one", function()
    assert.same(before + 1, #archived())
    assert.same(1, #archived()[1].entries)
    assert.is_truthy(archived()[1].entries[1].note:find("an errand that landed", 1, true))
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

--- Copying the batch, which is not delivering it -------------------------------

-- The other way a payload reaches the `+` register: on purpose, whatever the host has
-- wired, rather than as the consequence of nothing being. Nothing is handed to the
-- adapter, so a copy is not a **dispatch**, and the one condition this file exists to pin
-- down never comes up: the queue and the archive are exactly where they were.
--
-- Driven through the public entry point rather than a key, as every case above is -- the
-- surfaces that reach it have already moved once, and the contract has not.
describe("copying the batch with a send adapter wired", function()
  queue.clear()
  local notes = { "the first, copied", "the second, copied", "the third, copied" }
  for i, note in ipairs(notes) do
    queue.add({
      -- Two types, so "the same entries in the same order" is a claim about the queue and
      -- not about a single group that could only come back one way.
      type = i == 2 and "nitpick" or "bug",
      kind = "file",
      path = "src/main.lua",
      abs_path = main,
      key = ("src/main.lua:f:%d"):format(i),
      note = note,
    })
  end
  local ids = vim.tbl_map(function(entry)
    return entry.id
  end, queue.all())

  local before_sent, before_archive = #sent, #archived()
  vim.fn.setreg("+", "")
  local msgs, restore = h.capture_notify()
  codereview.copy()
  restore()

  -- Submitting works with nothing open and so does this, which is the reason there is a
  -- public entry point at all. Asserted rather than assumed: with a review open, every
  -- case below would be measuring the surface instead of the batch.
  it("works with no review view open", function()
    assert.is_nil(require("codereview.view").current())
  end)

  it("puts the payload in the + register", function()
    assert.is_truthy(vim.fn.getreg("+"):find("the second, copied", 1, true), vim.fn.getreg("+"))
  end)

  -- The whole point of the key: a host whose adapter takes the batch somewhere real has
  -- no other way to read what that adapter is handed.
  it("hands the send adapter nothing", function()
    assert.same(before_sent, #sent)
  end)

  it("leaves the queue with the same entries in the same order", function()
    assert.same(3, queue.count())
    assert.same(
      notes,
      vim.tbl_map(function(entry)
        return entry.note
      end, queue.all())
    )
    assert.same(
      ids,
      vim.tbl_map(function(entry)
        return entry.id
      end, queue.all())
    )
  end)

  -- The claim the unwired case above already makes, said the other way round: a register
  -- is not a consumer, whether the payload got there by default or deliberately.
  it("archives nothing, because a copy is not a dispatch", function()
    assert.same(before_archive, #archived())
  end)

  -- The queue looks identical afterwards, so the count is the only evidence a reviewer
  -- gets that it was this batch that went to the register.
  it("names how many annotations were copied", function()
    assert.is_true(h.notified(msgs, "Copied 3 annotations to the + register"), vim.inspect(msgs))
  end)

  it("does not claim to have submitted anything", function()
    assert.is_false(h.notified(msgs, "Submitted"), vim.inspect(msgs))
  end)
end)

-- What the split renderer exists for, and the one claim a second renderer could pass
-- today and fail the first time either side grew a rule of its own.
describe("the text a copy leaves in the register", function()
  queue_one("byte for byte")
  vim.fn.setreg("+", "")
  codereview.copy()
  local copied = vim.fn.getreg("+")
  local before = #sent
  codereview.submit()

  it("is what the send adapter is handed, byte for byte", function()
    assert.same(before + 1, #sent)
    assert.same(sent[#sent].text, copied)
  end)
end)

-- `@ref`s resolve against wherever the payload is going, and a copy is going wherever the
-- batch is. The same rule delivery already applies, reached through the same function --
-- not a second one that agrees today.
describe("a copy routed to a target", function()
  cfg.pick_target = function(cb)
    cb({ short = "elsewhere", cwd = "/somewhere/else" })
  end
  -- The one way the batch's target is set, whichever surface asked; the picker is the
  -- seam here, exactly as `send` is.
  require("codereview.delivery").pick_target()
  queue_one("routed somewhere else")
  vim.fn.setreg("+", "")
  codereview.copy()
  local copied = vim.fn.getreg("+")

  it("resolves refs against the target's working directory", function()
    assert.is_falsy(copied:find("@src/main.lua", 1, true), copied)
    assert.is_truthy(copied:find(main, 1, true), copied)
  end)
end)

-- The same batch, still queued because copying it did not spend it, going to the default
-- instead. Which is what makes the pair a test of the base rather than of the entry.
describe("a copy with no target chosen", function()
  cfg.pick_target = function(cb)
    cb(nil)
  end
  require("codereview.delivery").pick_target()
  cfg.pick_target = nil
  vim.fn.setreg("+", "")
  codereview.copy()
  local copied = vim.fn.getreg("+")

  it("resolves refs against the repository root", function()
    assert.is_truthy(copied:find("@src/main.lua", 1, true), copied)
  end)
end)

-- The command exists so a host can reach this from anywhere -- its own keymap, a
-- statusline, another plugin -- with no review view and without a Lua call.
describe("the user command", function()
  queue_one("copied by name")
  vim.fn.setreg("+", "")
  vim.cmd("CodeReviewCopy")

  it("copies the batch exactly as the entry point does", function()
    assert.is_truthy(vim.fn.getreg("+"):find("copied by name", 1, true), vim.fn.getreg("+"))
  end)

  it("leaves the queue where it was", function()
    assert.same(1, queue.count())
  end)
end)

describe("copying an empty queue", function()
  queue.clear()
  vim.fn.setreg("+", "left alone")
  local msgs, restore = h.capture_notify()
  codereview.copy()
  restore()

  it("takes the guard submitting an empty queue takes, worded the same", function()
    assert.is_true(h.notified(msgs, "Queue is empty — annotate something first"), vim.inspect(msgs))
  end)

  it("leaves the register holding whatever was in it", function()
    assert.same("left alone", vim.fn.getreg("+"))
  end)
end)

-- With a review open the payload's first line describes it, which is the part of the text
-- a copy could most easily get wrong: the context is the surface's to hand over, and copy
-- reaching it by a route of its own is exactly how the two would drift.
--
-- Both keys are fed rather than called, as the submit case above is: what a surface hands
-- delivery is not something to assert on directly, and `gy` being bound in the diff at all
-- is only observable this way.
describe("a copy taken with a review view open", function()
  codereview.open("branch")
  queue_one("copied out of a review")
  vim.fn.setreg("+", "")
  h.feed("gy")
  local copied = vim.fn.getreg("+")
  h.feed("<C-s>")

  it("describes the review in its header", function()
    local header = vim.split(copied, "\n")[1]
    assert.is_truthy(header:find("on branch vs ", 1, true), header)
    assert.is_truthy(header:find("reviewed)", 1, true), header)
  end)

  it("is still byte-identical to what the adapter was handed", function()
    assert.same(sent[#sent].text, copied)
  end)
end)

--- The preamble, which is composed and never queued ----------------------------

-- `<C-a>` is `<C-s>` with a composer in front of it. What the composer collects is rendered
-- above the batch's header; the submit that follows is the same submit, under the same one
-- rule about what empties the queue (ADR-0005).
--
-- The compose adapter is the seam here, exactly as `send` is below it: the composer the
-- plugin ships is the default implementation of that contract and not a lesser path beside
-- it (ADR-0003), so a stub that answers is the honest way to drive the flow.
describe("a batch submitted with a preamble", function()
  codereview.open("branch")
  local composed = {}
  cfg.compose = function(ctx, on_accept, label)
    composed[#composed + 1] = { ctx = ctx, label = label }
    on_accept(nil, "read the second one first")
  end
  queue_one("submitted under a preamble")
  local before, before_archive = #sent, #archived()
  local msgs, restore = h.capture_notify()
  h.feed("<C-a>")
  restore()

  it("opens a composer", function()
    assert.same(1, #composed)
  end)

  -- A preamble is about the batch, so the composer is told nothing about a file: there is
  -- none, and a path there would key its draft to code the preamble is not about.
  it("tells the composer it is writing a preamble, not annotating a file", function()
    assert.is_nil(composed[1].ctx.file_path)
    assert.is_nil(composed[1].ctx.rel_path)
    assert.is_true(composed[1].ctx.preamble)
    assert.same(root, composed[1].ctx.root)
  end)

  it("hands the adapter the preamble above the batch's header", function()
    assert.same(before + 1, #sent)
    assert.same("read the second one first", vim.split(sent[#sent].text, "\n")[1])
    assert.is_truthy(sent[#sent].text:find("\n\nCode review — 1 annotation", 1, true), sent[#sent].text)
  end)

  it("empties the queue, because a dispatch is a dispatch", function()
    assert.same(0, queue.count())
  end)

  it("records the batch in the archive", function()
    assert.same(before_archive + 1, #archived())
  end)

  it("confirms it in the words `<C-s>` confirms a submit in", function()
    assert.is_true(h.notified(msgs, "Submitted 1 annotation"), vim.inspect(msgs))
  end)

  -- The queue keeps **entries** and nothing else, and a preamble is not one: it is composed
  -- at submit time and joins them nowhere. Read out of the decoded document rather than out
  -- of the file's text, because the **archive** in that same file keeps the preamble on
  -- purpose -- what must carry it nowhere is an entry, queued or archived alike.
  it("writes the preamble into no entry, queued or archived", function()
    local doc = vim.json.decode(table.concat(vim.fn.readfile(state.path(root)), "\n"))
    local entries = vim.deepcopy(doc.queue or {})
    for _, batch in ipairs(doc.archive or {}) do
      vim.list_extend(entries, batch.entries or {})
    end
    -- Or the case is satisfied by a document with no entry in it to have been written into.
    assert.is_true(#entries > 0, "nothing reached the document, so this measures nothing")
    assert.is_nil(vim.json.encode(entries):find("read the second one first", 1, true), vim.inspect(entries))
  end)
end)

-- The other surface a batch is submitted from. The float lists the batch, so a submit
-- through it closes it exactly as `<C-s>` does: what has gone must not be left on screen.
describe("a batch submitted with a preamble from the queue float", function()
  queue_one("submitted from the list")
  cfg.compose = function(_, on_accept)
    on_accept(nil, "written over the queue")
  end
  codereview.queue()
  local float = vim.api.nvim_get_current_win()
  local before = #sent
  h.feed("<C-a>")

  it("opened a float to submit from", function()
    assert.is_truthy(float)
  end)

  it("closes the float", function()
    assert.is_false(vim.api.nvim_win_is_valid(float))
  end)

  it("dispatches with the preamble above the header", function()
    assert.same(before + 1, #sent)
    assert.same("written over the queue", vim.split(sent[#sent].text, "\n")[1])
  end)

  it("empties the queue", function()
    assert.same(0, queue.count())
  end)
end)

-- The float opens with no review view, as a batch is submitted with none. The view is what
-- closes a float over a batch that has gone, and with nothing open there is no view to do
-- it -- so the float closing is the float's own business on this path and nobody else's.
describe("a preamble submitted from the queue float with no review open", function()
  codereview.close()
  queue_one("submitted from a float with nothing behind it")
  cfg.compose = function(_, on_accept)
    on_accept(nil, "written with no review open")
  end
  codereview.queue()
  local float = vim.api.nvim_get_current_win()
  local before = #sent
  h.feed("<C-a>")

  it("had no review view to lean on", function()
    assert.is_nil(require("codereview.view").current())
  end)

  it("closes the float", function()
    assert.is_false(vim.api.nvim_win_is_valid(float))
  end)

  it("dispatches with the preamble above the header", function()
    assert.same(before + 1, #sent)
    assert.same("written with no review open", vim.split(sent[#sent].text, "\n")[1])
    assert.same(0, queue.count())
  end)
end)

-- The submit key means submit. A reviewer who opens the composer and decides they have
-- nothing to write still asked for a batch to go, and an empty preamble renders nothing --
-- so what goes is exactly what `<C-s>` would have sent.
describe("a preamble left empty", function()
  -- Back on the diff, where both keys are bound: the block above submitted with the review
  -- closed, and the pair below is a claim about what the two keys produce from one surface.
  codereview.open("branch")
  cfg.compose = nil
  queue_one("byte for byte")
  h.feed("<C-s>")
  local plain = sent[#sent].text
  cfg.compose = function(_, on_accept)
    on_accept(nil, "")
  end
  queue_one("byte for byte")
  local before = #sent
  h.feed("<C-a>")

  it("submits anyway", function()
    assert.same(before + 1, #sent)
    assert.same(0, queue.count())
  end)

  it("hands over the payload `<C-s>` produces, byte for byte", function()
    assert.same(plain, sent[#sent].text)
  end)
end)

-- Backing out of the note backs out of the send. A composer that never calls back is what
-- abandoning one looks like from here: nothing was collected, so nothing was submitted.
describe("a preamble composer that was abandoned", function()
  queue_one("still here, because nothing was submitted")
  cfg.compose = function() end
  local before, before_archive = #sent, #archived()
  local msgs, restore = h.capture_notify()
  h.feed("<C-a>")
  restore()

  it("hands the send adapter nothing", function()
    assert.same(before, #sent)
  end)

  it("leaves the queue whole", function()
    assert.same(1, queue.count())
    assert.same("still here, because nothing was submitted", queue.all()[1].note)
  end)

  it("archives nothing, because nothing was dispatched", function()
    assert.same(before_archive, #archived())
  end)

  it("claims nothing was submitted", function()
    assert.is_false(h.notified(msgs, "Submitted"), vim.inspect(msgs))
  end)

  -- The batch is exactly where it was, so the fast path still takes it.
  it("leaves the batch submittable", function()
    h.feed("<C-s>")
    assert.same(before + 1, #sent)
    assert.same(0, queue.count())
  end)
end)

-- An empty queue is an empty queue whichever key was pressed, and there is no covering note
-- worth writing for a batch that does not exist.
describe("a preamble asked for with nothing queued", function()
  queue.clear()
  local composed = 0
  cfg.compose = function(_, on_accept)
    composed = composed + 1
    on_accept(nil, "nothing to cover")
  end
  local before = #sent
  local msgs, restore = h.capture_notify()
  h.feed("<C-a>")
  restore()

  it("opens no composer", function()
    assert.same(0, composed)
  end)

  it("takes the guard `<C-s>` takes, worded the same", function()
    assert.is_true(h.notified(msgs, "Queue is empty — annotate something first"), vim.inspect(msgs))
    assert.same(before, #sent)
  end)
end)

-- A batch that did not go is still queued and can be retried. The preamble has no queue to
-- wait in, so it goes where an undispatched errand's note goes (ADR-0005): the draft store,
-- under the key the composer wrote it from.
describe("a preamble whose batch was not dispatched", function()
  drafts.clear()
  cfg.compose = function(_, on_accept)
    on_accept(nil, "kept, because nothing took the batch")
  end
  cfg.send = function(text, target)
    records(text, target)
    return false, "the agent pane is gone"
  end
  queue_one("queued still")
  local msgs, restore = h.capture_notify()
  h.feed("<C-a>")
  restore()
  cfg.send = records

  it("keeps the queue", function()
    assert.same(1, queue.count())
  end)

  it("says why it did not go", function()
    assert.is_true(h.notified(msgs, "the agent pane is gone"), vim.inspect(msgs))
    assert.is_false(h.notified(msgs, "Submitted"), vim.inspect(msgs))
  end)

  -- Written once. The shipped composer is what reads a draft back, so the proof that
  -- "kept" means what it says is the next `<C-a>` holding it.
  it("offers the preamble back the next time one is asked for", function()
    cfg.compose = nil
    h.feed("<C-a>")
    local reopened = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    h.feed("q")
    assert.same({ "kept, because nothing took the batch" }, reopened)
  end)
end)

-- Copy is deliberately not a dispatch, and a preamble belongs to a send: `gy` performs no
-- submit, so it composes nothing and carries nothing.
describe("copying a batch with a compose adapter wired", function()
  drafts.clear()
  queue_one("copied without a preamble")
  local composed = 0
  cfg.compose = function(_, on_accept)
    composed = composed + 1
    on_accept(nil, "never in a copy")
  end
  vim.fn.setreg("+", "")
  h.feed("gy")
  local copied = vim.fn.getreg("+")

  it("opens no composer", function()
    assert.same(0, composed)
  end)

  it("heads the register with the batch's own header", function()
    assert.is_truthy(vim.split(copied, "\n")[1]:find("Code review — 1 annotation", 1, true), copied)
  end)

  it("carries no preamble at all", function()
    assert.is_nil(copied:find("never in a copy", 1, true), copied)
  end)
end)

-- An immediate send is a batch of one (ADR-0004) and the smallest act there is: it bypasses
-- the queue, so there is no batch for a preamble to cover.
describe("an immediate send", function()
  queue.clear()
  codereview.close()
  vim.cmd("edit " .. vim.fn.fnameescape(main))
  cfg.compose = function(_, on_accept)
    on_accept(nil, "an errand under no preamble")
  end
  codereview.annotate("bug", nil, { immediate = true })
  cfg.compose = nil

  it("heads its payload with the batch header, with nothing above it", function()
    assert.is_truthy(vim.split(sent[#sent].text, "\n")[1]:find("Code review — 1 annotation", 1, true))
  end)

  it("carries the note it collected as an annotation, not as a preamble", function()
    assert.is_truthy(sent[#sent].text:find("### 1. ", 1, true), sent[#sent].text)
  end)
end)
