-- A **submit** while the **sync** runs: it goes to the fake **queue owner** as `send`, the
-- queue empties only through the queue owner's snapshot, and the **archive** is written only
-- from the `sent` event, also for a `sent` that this process did not cause.
--
-- Driven through the public surface only: `setup()`, `annotate()`, the submit actions and
-- the reads of the queue and the archive. The transport is real: a Unix socket in a
-- temporary directory, served by tests/fake_queue_owner.lua in this process.
--
-- The cases run from top to bottom and build on each other. Each case reads the archive as
-- the case before it left it, so each asserts on the batch that it added.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))
-- A second repository, for a note that another Neovim kept about its own checkout.
local other = assert(vim.uv.fs_realpath(h.fixture("mkfixture")))

local drafts = require("codereview.drafts")
local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

local owner = fake.start()
local messages, restore_notify = h.capture_notify_levels()

local NOTE = "the note"
local PREAMBLE = "Read the config change first."
local TARGET = { short = "pane-7", id = "w1:p7", cwd = root }
-- What the composer gives for a preamble. A case changes it to compose a second one.
local preamble_text = PREAMBLE

local codereview = require("codereview")
codereview.setup({
  syntax = false,
  types = {
    { name = "bug", key = "b", label = "Bugs", directive = "diagnose and fix these" },
    { name = "question", key = "q", label = "Questions" },
  },
  compose = function(ctx, on_accept)
    on_accept(nil, ctx.preamble and preamble_text or NOTE)
  end,
  pick_target = function(cb)
    cb(TARGET)
  end,
  sync = {
    socket = owner.path,
    -- The host's target, mapped. `id` is only in the host's target, so a `send` that carries
    -- it went through this adapter.
    target = function(to)
      return { tool = "herdr", address = to and to.id or "none", cwd = root }
    end,
    -- Short, so that a reply after the wait does not cost the suite the real 5 s.
    wait = 200,
  },
})

vim.wait(3000, function()
  return h.notified(messages, "Queue sync started")
end, 10)
assert(h.notified(messages, "Queue sync started"), "the sync did not start")
view.pick_target()

---@param needle string
---@return integer
local function said(needle)
  local n = 0
  for _, m in ipairs(messages) do
    if type(m.msg) == "string" and m.msg:find(needle, 1, true) then
      n = n + 1
    end
  end
  return n
end

---Capture an entry and wait until the queue owner holds it.
---@param path string|nil Repository-relative; nil for a bare note
---@param line integer|nil
---@return CRAnnotation
local function capture(path, line)
  if path then
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, path)))
    codereview.annotate("bug", { first = line, last = line })
  else
    vim.cmd("enew")
    codereview.annotate("question")
  end
  local entry = queue.entries()[#queue.entries()]
  vim.wait(3000, function()
    return owner:find(entry.uuid) ~= nil
  end, 10)
  return entry
end

---@param uuid string
---@return CRAnnotation|nil
local function queued(uuid)
  for _, e in ipairs(queue.entries()) do
    if e.uuid == uuid then
      return e
    end
  end
end

---@param batch CRBatch|nil
---@return string[]
local function uuids_of(batch)
  return vim.tbl_map(function(e)
    return e.uuid
  end, batch and batch.entries or {})
end

---@return table The last `send` that the queue owner received
local function last_send()
  for i = #owner.requests, 1, -1 do
    if owner.requests[i].op == "send" then
      return owner.requests[i]
    end
  end
  error("no send")
end

---@param op string
---@return integer
local function count_op(op)
  return #vim.tbl_filter(function(o)
    return o == op
  end, owner:ops())
end

describe("a submit that the queue owner sends", function()
  local file = capture("src/main.lua", 2)
  local bare = capture(nil)
  local batch = vim.tbl_map(function(e)
    return e.uuid
  end, queue.all())
  view.submit_with_preamble()
  vim.wait(3000, function()
    return #state.archive(root) > 0
  end, 10)

  it("sends send with the uuids of the batch, the mapped target and the preamble", function()
    local send = last_send()
    assert.same(batch, send.ids)
    assert.same({ file.uuid, bare.uuid }, batch)
    assert.same({ tool = "herdr", address = "w1:p7", cwd = root }, send.target)
    assert.same(PREAMBLE, send.preamble)
  end)

  it("reports the dispatch as a submit without the sync does", function()
    assert.same(vim.log.levels.INFO, h.notified_level(messages, "Submitted 2 annotations to pane-7"))
  end)

  it("is emptied by the snapshot, and the empty queue is on disk", function()
    assert.same(0, queue.count())
    assert.same({}, state.load(root).queue)
    assert.same({}, state.load_global())
  end)

  it("archives from sent, per store, with the preamble and the target", function()
    local repo, loose = state.archive(root)[1], state.global_archive()[1]
    assert.same({ file.uuid }, uuids_of(repo))
    assert.same({ bare.uuid }, uuids_of(loose))
    assert.same({ PREAMBLE, "w1:p7" }, { repo.preamble, repo.target })
    assert.same({ PREAMBLE, "w1:p7" }, { loose.preamble, loose.target })
    assert.is_string(repo.snapshot)
  end)

  -- The fake renders the `text` of `sent` as `Owner:render` says, from the notes it held
  -- when the `send` came.
  it("archives the text of sent in both stores", function()
    local want =
      table.concat({ PREAMBLE, "", "Annotations — 2 items", "", "### 1.", "", NOTE, "", "### 2.", "", NOTE }, "\n")
    assert.same(want, state.archive(root)[1].text)
    assert.same(want, state.global_archive()[1].text)
  end)
end)

describe("an ok reply alone", function()
  local kept = capture("src/main.lua", 1)
  -- An entry that the queue owner does not take: it stays in Neovim, and no snapshot has it.
  owner:refuse("keep", "bad request: refused by the test")
  vim.cmd("enew")
  codereview.annotate("question")
  local refused = queue.entries()[#queue.entries()]
  vim.wait(3000, function()
    return h.notified(messages, "refused by the test")
  end, 10)
  owner:refuse("keep", nil)
  local archived = #state.archive(root)
  local submitted = said("Submitted 2 annotations to pane-7")

  codereview.submit()
  vim.wait(3000, function()
    return #state.archive(root) > archived
  end, 10)

  it("is a dispatch", function()
    assert.same(submitted + 1, said("Submitted 2 annotations to pane-7"))
  end)

  it("does not empty the queue: what the snapshot still lacks stays", function()
    assert.is_nil(queued(kept.uuid))
    assert.is_not_nil(queued(refused.uuid))
    local stored = vim.tbl_map(function(e)
      return e.uuid
    end, state.load_global())
    assert.same({ refused.uuid }, stored)
  end)

  it("archives only what the sent event holds", function()
    assert.same({ kept.uuid }, uuids_of(state.archive(root)[1]))
  end)
end)

describe("an error reply", function()
  local entry = capture("src/routes.lua", 1)
  local archived, sends = #state.archive(root), count_op("send")
  owner:refuse("send", "herdr: no pane w1:p7")
  codereview.submit()
  owner:refuse("send", nil)

  it("is reported as a non-dispatch, with the reason", function()
    assert.same(count_op("send"), sends + 1)
    assert.same(
      vim.log.levels.ERROR,
      h.notified_level(messages, "Not submitted: the queue owner refused it (herdr: no pane w1:p7)")
    )
  end)

  it("leaves the batch in the queue and the archive as it was", function()
    assert.is_not_nil(queued(entry.uuid))
    assert.same(archived, #state.archive(root))
  end)
end)

describe("a reply after the wait", function()
  local entry = assert(queued(capture("src/main.lua", 3).uuid))
  local pending = queue.count()
  local archived, sends = #state.archive(root), count_op("send")
  local submitted = said("Submitted")
  -- Later than the 5 s in which every other request counts as refused.
  owner:delay("send", 5300)
  local started = vim.uv.hrtime()
  codereview.submit()
  local took = (vim.uv.hrtime() - started) / 1e6
  local count_after_wait = queue.count()
  -- A second submit before the reply.
  codereview.submit()
  local sends_after_second = count_op("send")
  owner:delay("send", nil)

  vim.wait(8000, function()
    return said("Submitted") > submitted and #state.archive(root) > archived
  end, 20)

  it("returns after the configured wait, not after the reply", function()
    assert.is_true(took < 1000, ("the submit took %d ms"):format(took))
  end)

  it("says that it did not go yet, and that the result will follow", function()
    assert.is_true(h.notified(messages, "did not reply in 0.2 s"))
    assert.is_true(h.notified(messages, "the result will follow"))
  end)

  it("keeps the batch in the queue until the snapshot", function()
    assert.same(pending, count_after_wait)
  end)

  it("refuses a second submit while the first has no reply", function()
    assert.same(sends + 1, sends_after_second)
    assert.is_true(h.notified(messages, "the last submit has no reply from the queue owner yet"))
  end)

  it("reports the reply when it comes", function()
    assert.same(submitted + 1, said("Submitted"))
    assert.is_false(h.notified(messages, "refused it (no reply)"))
  end)

  it("then empties the batch through the snapshot, and archives it from sent", function()
    assert.is_nil(queued(entry.uuid))
    assert.same(archived + 1, #state.archive(root))
    assert.is_true(vim.tbl_contains(uuids_of(state.archive(root)[1]), entry.uuid))
  end)
end)

describe("a sent that this process did not cause", function()
  assert.same({}, owner.queue)
  local changed = capture("src/main.lua", 1)
  local unchanged = capture("src/nonl.md", 1)
  local bare = capture(nil)
  -- A note that another Neovim kept, about its own checkout.
  local ELSEWHERE = "7A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
  local note = vim.deepcopy(owner.queue[owner:find(changed.uuid)])
  note.id = ELSEWHERE
  note.selection.text.file.path = vim.fs.joinpath(other, "src/main.lua")
  local notes = vim.deepcopy(owner.queue)
  notes[#notes + 1] = note
  owner:push_queue(notes)
  vim.wait(3000, function()
    return queued(ELSEWHERE:lower()) ~= nil
  end, 10)

  local ids = vim.tbl_map(function(n)
    return n.id
  end, owner.queue)
  local sends = count_op("send")
  local archived, archived_loose = #state.archive(root), #state.global_archive()
  local sent = {
    event = "sent",
    ids = ids,
    target = { tool = "hc", address = "tab-3", cwd = "/somewhere/else" },
    preamble = "Sent from the other tool",
    text = "the payload",
    at = "2026-11-02T10:00:00Z",
  }
  -- The other tool sends: its snapshot takes the batch out, then it says what went.
  owner:push_queue({})
  owner:push(sent)
  vim.wait(3000, function()
    return #state.archive(other) > 0
  end, 10)

  it("sends nothing from this process", function()
    assert.same(sends, count_op("send"))
  end)

  it("archives this checkout's entries with the event's preamble and target", function()
    assert.same(archived + 1, #state.archive(root))
    local batch = state.archive(root)[1]
    assert.same({ changed.uuid, unchanged.uuid }, uuids_of(batch))
    assert.same({ "Sent from the other tool", "tab-3" }, { batch.preamble, batch.target })
  end)

  it("archives the bare note in the store with no root", function()
    assert.same(archived_loose + 1, #state.global_archive())
    local loose = state.global_archive()[1]
    assert.same({ bare.uuid }, uuids_of(loose))
    assert.same({ "Sent from the other tool", "tab-3" }, { loose.preamble, loose.target })
  end)

  it("archives the entry of another checkout in that checkout", function()
    assert.same({ ELSEWHERE:lower() }, uuids_of(state.archive(other)[1]))
  end)

  -- The event's own field, in each record of the batch: not a payload that this process
  -- renders again.
  it("archives the event's text with each record", function()
    assert.same("the payload", state.archive(root)[1].text)
    assert.same("the payload", state.global_archive()[1].text)
    assert.same("the payload", state.archive(other)[1].text)
  end)

  it("shows that text in the float of the last batch, on p, and the entries again on p", function()
    codereview.last_batch()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local footer = function()
      return vim.api.nvim_win_get_config(win).footer[1][1]
    end
    local entries = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.is_truthy(footer():find("p payload", 1, true), footer())
    h.feed("p")
    assert.same({ "the payload" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_truthy(footer():find("p entries", 1, true), footer())
    assert.is_false(vim.bo[buf].modifiable)
    h.feed("p")
    assert.same(entries, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_win_close(win, true)
  end)

  it("archives nothing again when the same sent comes again", function()
    owner:push(sent)
    vim.wait(200)
    assert.same(archived + 1, #state.archive(root))
    assert.same(archived_loose + 1, #state.global_archive())
    assert.same(1, #state.archive(other))
  end)

  it("lets touched judge the archived entries", function()
    local path = vim.fs.joinpath(root, "src/main.lua")
    vim.fn.writefile(vim.list_extend(vim.fn.readfile(path), { "-- changed by the agent" }), path)
    local touched, untouched = state.reconcile_archive(root, { { path = "src/main.lua" }, { path = "src/nonl.md" } })
    assert.is_true(touched[changed.id])
    assert.is_false(touched[unchanged.id])
    assert.same(1, untouched)
  end)
end)

describe("a sent that another Neovim archived first", function()
  local entry = capture("src/main.lua", 2)
  local bare = capture(nil)
  local ids = vim.tbl_map(function(n)
    return n.id
  end, owner.queue)
  owner:push_queue({})
  vim.wait(3000, function()
    return queued(entry.uuid) == nil
  end, 10)
  -- The other process got the same event first, and wrote the same state files.
  state.archive_batch({ vim.deepcopy(entry), vim.deepcopy(bare) }, "tab-3", root, "first")
  local archived, archived_loose = #state.archive(root), #state.global_archive()
  local writes = state.archive_writes()
  owner:push({
    event = "sent",
    ids = ids,
    target = { tool = "hc", address = "tab-3", cwd = root },
    preamble = "first",
    text = "the payload",
    at = "2026-11-02T10:00:00Z",
  })
  -- Short: in the case that passes, nothing is written, and the wait runs out.
  vim.wait(500, function()
    return state.archive_writes() > writes
  end, 10)

  it("does not archive the batch a second time", function()
    assert.same(archived, #state.archive(root))
    assert.same(archived_loose, #state.global_archive())
  end)
end)

-- The preamble's draft, under the key the composer reads it from.
local DRAFT = drafts.key({ preamble = true, root = root })

describe("a late ok after a submit with a preamble", function()
  capture("src/main.lua", 2)
  local submitted = said("Submitted")
  owner:delay("send", 400)
  view.submit_with_preamble()
  owner:delay("send", nil)
  local kept = drafts.get(DRAFT)
  vim.wait(3000, function()
    return said("Submitted") > submitted
  end, 20)

  it("keeps the preamble as a draft while the result is not known", function()
    assert.same(PREAMBLE, kept)
  end)

  it("removes the draft when the batch went", function()
    assert.same(submitted + 1, said("Submitted"))
    assert.is_nil(drafts.get(DRAFT))
  end)
end)

describe("a late ok when a newer preamble was kept as a draft", function()
  capture("src/main.lua", 2)
  local submitted = said("Submitted")
  owner:delay("send", 400)
  view.submit_with_preamble()
  owner:delay("send", nil)
  -- A second submit before the reply is refused, and its preamble is kept as a draft.
  preamble_text = "a newer preamble"
  view.submit_with_preamble()
  preamble_text = PREAMBLE
  vim.wait(3000, function()
    return said("Submitted") > submitted
  end, 20)

  it("keeps the newer draft", function()
    assert.same(submitted + 1, said("Submitted"))
    assert.same("a newer preamble", drafts.get(DRAFT))
  end)
end)

describe("a late error after a submit with a preamble", function()
  local entry = capture("src/main.lua", 3)
  owner:refuse("send", "the agent tool failed")
  owner:delay("send", 400)
  view.submit_with_preamble()
  owner:delay("send", nil)
  vim.wait(3000, function()
    return h.notified(messages, "the agent tool failed")
  end, 20)
  owner:refuse("send", nil)

  it("keeps the draft and the batch", function()
    assert.is_true(h.notified(messages, "Not submitted: the queue owner refused it (the agent tool failed)"))
    assert.same(PREAMBLE, drafts.get(DRAFT))
    assert.is_not_nil(queued(entry.uuid))
  end)
end)

describe("a sent while a review is open", function()
  local first = capture("src/main.lua", 1)
  local second = capture("src/nonl.md", 1)
  view.open("branch")
  local V = assert(view.current(), "the review did not open")
  local writes = state.archive_writes()
  owner:push_queue({})
  owner:push({
    event = "sent",
    ids = { first.uuid:upper(), second.uuid:upper() },
    target = { tool = "hc", address = "tab-3", cwd = root },
    preamble = "",
    text = "the payload",
    at = "2026-11-02T10:00:00Z",
  })
  vim.wait(3000, function()
    return state.archive_writes() > writes
  end, 10)
  vim.wait(100)
  local winbar = h.winbar(V.win)
  codereview.close()

  it("judges the archive again, so the winbar shows the untouched tally at once", function()
    assert.is_truthy(winbar:find("↺2", 1, true), winbar)
  end)
end)

describe("<C-c> during the wait", function()
  local entry = capture("src/routes.lua", 2)
  local submitted = said("Submitted")
  local sync = require("codereview.config").get().sync
  -- A wait far longer than the reply, so only the interrupt can end it early.
  sync.wait = 5000
  owner:delay("send", 1000)
  vim.defer_fn(function()
    vim.api.nvim_input("<C-c>")
  end, 100)
  local started = vim.uv.hrtime()
  codereview.submit()
  local took = (vim.uv.hrtime() - started) / 1e6
  local still_queued = queued(entry.uuid) ~= nil
  sync.wait = 200
  owner:delay("send", nil)
  vim.wait(3000, function()
    return said("Submitted") > submitted
  end, 20)

  it("stops the wait, and the batch stays until the snapshot", function()
    assert.is_true(took < 900, ("the submit took %d ms"):format(took))
    assert.is_true(still_queued)
  end)

  it("still reports the reply when it comes", function()
    assert.same(submitted + 1, said("Submitted"))
    assert.is_nil(queued(entry.uuid))
  end)
end)

describe("a close during the wait", function()
  local entry = capture("src/routes.lua", 1)
  local sync = require("codereview.config").get().sync
  -- A wait far longer than the close, so only the close can end it early.
  sync.wait = 5000
  owner:delay("send", math.huge)
  vim.defer_fn(function()
    owner:drop_clients()
  end, 50)
  local started = vim.uv.hrtime()
  codereview.submit()
  local took = (vim.uv.hrtime() - started) / 1e6
  sync.wait = 200
  owner:delay("send", nil)

  it("ends the wait at once, and says that the result is unknown", function()
    assert.is_true(took < 1000, ("the submit took %d ms"):format(took))
    assert.same(1, said("The result is unknown"))
    assert.is_not_nil(queued(entry.uuid))
  end)
end)

describe("a close after the wait", function()
  -- The close above stopped the sync. A capture is a queue operation, so it connects again.
  local entry = capture("src/main.lua", 2)
  vim.wait(3000, function()
    return said("Queue sync started") == 2
  end, 10)
  owner:delay("send", math.huge)
  codereview.submit()
  owner:delay("send", nil)
  local before = said("The result is unknown")
  owner:drop_clients()
  vim.wait(3000, function()
    return said("The result is unknown") > before
  end, 10)

  it("says once that the result is unknown, and what to do", function()
    assert.same(before + 1, said("The result is unknown"))
    assert.is_true(
      h.notified(
        messages,
        "Queue sync stopped before the queue owner replied to the submit. The result is unknown, and the batch is still in the Neovim queue. Check the agent before you submit again."
      )
    )
    assert.same(vim.log.levels.WARN, h.notified_level(messages, "The result is unknown"))
    assert.is_not_nil(queued(entry.uuid))
  end)
end)

describe("teardown", function()
  it("stops the fake queue owner", function()
    restore_notify()
    owner:stop()
  end)
end)
