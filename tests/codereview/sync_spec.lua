-- The **sync** against a fake **queue owner**: the connect, the plugin's own entries going
-- out with `keep`, and the snapshot that comes back becoming the queue.
--
-- Driven through the public surface only: `setup()`, `annotate()`, the review keys, the
-- queue float and the queue's reads. The transport is real: a Unix socket in a temporary
-- directory, served by tests/fake_queue_owner.lua in this process.
--
-- The cases run from top to bottom and build on each other: the connect, three captures,
-- a snapshot, a lower `rev`, and the queue owner going away.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))
-- A second repository, for a note about a checkout that is not this one.
local other = assert(vim.uv.fs_realpath(h.fixture("mkfixture")))

local queue = require("codereview.queue")
local state = require("codereview.state")

local owner = fake.start()

-- The entry the last session left: a bare note in the store that needs no root, written by
-- hand before setup. This process has not read the queue back, so only the restore of the
-- connect can put it in the `keep`.
local PERSISTED = "0b6f2a1e-5c3d-4e8f-9a7b-2c1d0e9f8a7b"
local now = os.time()
vim.fn.mkdir(vim.fs.dirname(state.global_path()), "p")
vim.fn.writefile({
  vim.json.encode({
    version = 1,
    archive = {},
    queue = {
      {
        id = 1,
        uuid = PERSISTED,
        type = "bug",
        kind = "note",
        key = "note:0",
        inline = false,
        note = "left by the last session",
        at = now,
      },
    },
  }),
}, state.global_path())

local messages, restore_notify = h.capture_notify()

local codereview = require("codereview")
codereview.setup({
  syntax = false,
  types = {
    { name = "bug", key = "b", label = "Bugs", directive = "diagnose and fix these" },
    { name = "question", key = "q", label = "Questions" },
  },
  compose = function(_, on_accept)
    on_accept(nil, "the note")
  end,
  sync = {
    socket = owner.path,
    target = function()
      return { tool = "custom", address = "agent", cwd = root }
    end,
  },
})

---Wait until the queue owner has received `n` requests.
---@param n integer
local function requests(n)
  vim.wait(3000, function()
    return #owner.requests >= n
  end, 10)
  return owner.requests
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

---@param uuid string
---@return CRAnnotation|nil
local function entry_of(uuid)
  for _, e in ipairs(queue.entries()) do
    if e.uuid:lower() == uuid:lower() then
      return e
    end
  end
end

---The note in the last `keep` the queue owner received.
---@return table
local function last_kept()
  local r = owner.requests[#owner.requests]
  assert.same("keep", r.op)
  assert.same(1, #r.notes)
  return r.notes[1]
end

describe("on connect", function()
  requests(4)
  vim.wait(3000, function()
    return said("Queue sync started") > 0
  end, 10)

  it("sends hello, subscribe, list and keep, in that order", function()
    assert.same({ "hello", "subscribe", "list", "keep" }, owner:ops())
  end)

  it("restores the persisted queue first, so keep has the entry the last session left", function()
    local ids = vim.tbl_map(function(n)
      return n.id:lower()
    end, owner.requests[4].notes)
    assert.same({ PERSISTED }, ids)
    assert.same("left by the last session", owner.requests[4].notes[1].note)
  end)

  it("says hello with protocol 1, its name, and the host's types in host order", function()
    local hello = owner.requests[1]
    assert.same(1, hello.protocol)
    assert.same("codereview.nvim", hello.client)
    assert.same({
      { name = "bug", label = "Bugs", directive = "diagnose and fix these" },
      { name = "question", label = "Questions" },
    }, hello.types)
  end)

  it("says once that the sync started", function()
    assert.same(1, said("Queue sync started"))
  end)
end)

describe("a capture from a buffer", function()
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
  codereview.annotate("bug", { first = 2, last = 3 })
  requests(5)
  local entry = queue.all()[#queue.all()]

  it("sends keep with the entry as a note", function()
    local note = last_kept()
    assert.same(entry.uuid, note.id)
    assert.same("bug", note.type)
    assert.same("the note", note.note)
    assert.same(os.date("!%Y-%m-%dT%H:%M:%SZ", entry.at), note.createdAt)
    assert.same({ appName = "nvim" }, note.source)
  end)

  it("selects the file by its absolute path and the range", function()
    assert.same({
      text = {
        _0 = "local cfg = load_config()\napp.listen(cfg.port)",
        file = { path = vim.fs.joinpath(root, "src/main.lua"), first = 2, last = 3 },
      },
    }, last_kept().selection)
  end)

  it("carries the kind, the inline flag, the stale flag and the lines in review", function()
    assert.same({ kind = "range", inline = false, stale = false, lines = entry.lines }, last_kept().review)
  end)

  it("carries in origin what the note does not, and the mark of this plugin", function()
    assert.same({
      client = "codereview.nvim",
      path = "src/main.lua",
      key = entry.key,
      blob = entry.blob,
      worktree = true,
      at = entry.at,
    }, last_kept().origin)
  end)
end)

describe("a bare note", function()
  vim.cmd("enew")
  codereview.annotate("question")
  requests(6)

  it("selects nothing, and is of the bare-note kind", function()
    local note = last_kept()
    assert.same({ none = {} }, note.selection)
    assert.same("note", note.review.kind)
    assert.same("question", note.type)
    assert.is_nil(note.origin.path)
  end)
end)

local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "the review did not open")

describe("a capture in the review view", function()
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { assert(h.line_row(V, "src/fresh.lua")), 0 })
  h.feed("ab")
  requests(7)

  it("sends keep with the line it is anchored to", function()
    local note = last_kept()
    assert.same("line", note.review.kind)
    assert.same(vim.fs.joinpath(root, "src/fresh.lua"), note.selection.text.file.path)
    assert.same({ 1, 1 }, { note.selection.text.file.first, note.selection.text.file.last })
    assert.same("src/fresh.lua:n:1", note.origin.key)
  end)
end)

local FOREIGN = "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"

describe("a snapshot from the queue owner", function()
  codereview.queue()
  local float = vim.api.nvim_get_current_win()

  local before = {}
  local highest = 0
  for _, e in ipairs(queue.entries()) do
    before[e.uuid] = vim.deepcopy(e)
    highest = math.max(highest, e.id)
  end
  local range = queue.all()[2]
  local review = queue.all()[4]
  assert.same({ "range", "line" }, { range.kind, review.kind })

  -- The notes as the queue owner holds them, ids in upper case.
  local held = vim.deepcopy(owner.queue)
  local function held_note(uuid)
    for _, n in ipairs(held) do
      if n.id:lower() == uuid then
        return n
      end
    end
  end
  held_note(review.uuid).note = "edited in the other tool"

  local FRESH = "6F9619FF-8B86-4011-B42D-00CF4FC964FF"
  local fresh = vim.deepcopy(held_note(range.uuid))
  fresh.id = FRESH
  fresh.note = "kept by another Neovim"

  local ELSEWHERE = "7A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
  local elsewhere = vim.deepcopy(held_note(range.uuid))
  elsewhere.id = ELSEWHERE
  elsewhere.selection.text.file.path = vim.fs.joinpath(other, "src/main.lua")

  local foreign = {
    id = FOREIGN,
    type = "bug",
    note = "a screenshot",
    selection = { area = { imagePath = "/tmp/shot.png" } },
    source = { appName = "Helium" },
    createdAt = "2026-11-02T10:00:00Z",
  }

  vim.list_extend(held, { foreign, fresh, elsewhere })
  owner:push_queue(held)
  vim.wait(3000, function()
    return entry_of(FRESH) ~= nil
  end, 10)

  it("keeps the id and the uuid of each entry it knew", function()
    for uuid, old in pairs(before) do
      local now_entry = entry_of(uuid)
      assert.is_not_nil(now_entry, uuid)
      assert.same({ old.id, old.uuid }, { now_entry.id, now_entry.uuid })
    end
  end)

  it("takes the note from the snapshot", function()
    assert.same("edited in the other tool", entry_of(review.uuid).note)
  end)

  it("rebuilds an entry exactly from its note and its origin", function()
    assert.same(before[range.uuid], entry_of(range.uuid))
  end)

  it("gives each uuid not seen before the next integer id, in snapshot order", function()
    assert.same(
      { highest + 1, highest + 2, highest + 3 },
      { entry_of(foreign.id).id, entry_of(FRESH).id, entry_of(ELSEWHERE).id }
    )
  end)

  it("files an entry by its checkout", function()
    assert.same(1, queue.count_in(other))
    local here = vim.tbl_map(function(e)
      return e.uuid
    end, queue.all())
    assert.is_false(vim.tbl_contains(here, ELSEWHERE:lower()))
    assert.is_true(vim.tbl_contains(here, FRESH:lower()))
  end)

  it("makes a note that another tool made a mirrored entry, loose and labelled", function()
    local mirrored = entry_of(foreign.id)
    assert.same({ true, "Area · Helium", "note", "bug", "a screenshot" }, {
      mirrored.mirrored,
      mirrored.label,
      mirrored.kind,
      mirrored.type,
      mirrored.note,
    })
    assert.is_nil(mirrored.path)
  end)

  it("repaints the queue float", function()
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")
    assert.is_truthy(text:find("edited in the other tool", 1, true))
    assert.is_truthy(text:find("kept by another Neovim", 1, true))
  end)

  it("repaints the review view", function()
    local drawn = {}
    for _, m in ipairs(h.virt_marks(V)) do
      for _, line in ipairs(m[4].virt_lines) do
        for _, chunk in ipairs(line) do
          drawn[#drawn + 1] = chunk[1]
        end
      end
    end
    assert.is_truthy(table.concat(drawn):find("edited in the other tool", 1, true))
  end)

  it("writes the plugin's own entries to disk as today", function()
    local stored = vim.tbl_map(function(e)
      return e.uuid
    end, state.load(root).queue)
    assert.is_true(vim.tbl_contains(stored, FRESH:lower()))
    assert.is_true(vim.tbl_contains(stored, review.uuid))
    local notes = vim.tbl_map(function(e)
      return e.note
    end, state.load(root).queue)
    assert.is_true(vim.tbl_contains(notes, "edited in the other tool"))
  end)
end)

describe("a snapshot with a lower rev", function()
  local held = #queue.entries()
  owner:push_queue({}, 1)
  vim.wait(200)

  it("is ignored", function()
    assert.same(held, #queue.entries())
  end)
end)

describe("a snapshot with the overlay on", function()
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    vim.cmd("close")
  end
  view.close()
  vim.cmd("silent! only")
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
  local buf = vim.api.nvim_get_current_buf()
  assert.is_true(codereview.overlay("inline"))
  local overlay = require("codereview.overlay")

  ---Every chunk of text the captions on the buffer draw, as one string.
  local function drawn()
    local text = {}
    for _, ns in ipairs({ overlay.NS, overlay.NS_ANCHOR }) do
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        for _, row in ipairs(m[4].virt_lines or {}) do
          for _, chunk in ipairs(row) do
            text[#text + 1] = chunk[1]
          end
        end
      end
    end
    return table.concat(text)
  end
  local before = drawn()

  local range = queue.all()[2]
  local held = vim.deepcopy(owner.queue)
  for _, n in ipairs(held) do
    if n.id:lower() == range.uuid then
      n.note = "retold in the other tool"
    end
  end
  owner:push_queue(held)
  vim.wait(3000, function()
    return entry_of(range.uuid).note == "retold in the other tool"
  end, 10)

  it("repaints the overlay", function()
    assert.is_falsy(before:find("retold in the other tool", 1, true))
    assert.is_truthy(drawn():find("retold in the other tool", 1, true))
  end)
end)

describe("a capture about a file in another checkout", function()
  local count_before = queue.count()
  local other_before = queue.count_in(other)
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(other, "src/main.lua")))
  codereview.annotate("bug")
  local entry = queue.all()[#queue.all()]
  assert.same(vim.fs.joinpath(other, "src/main.lua"), entry.abs_path)
  vim.wait(3000, function()
    return owner:find(entry.uuid) ~= nil
  end, 10)

  -- A snapshot that holds the entry with a new note, so that the wait below can see that
  -- the snapshot was applied: the list the entry is in looks the same before it.
  local held = vim.deepcopy(owner.queue)
  held[owner:find(entry.uuid)].note = "about the other checkout"
  owner:push_queue(held)
  vim.wait(3000, function()
    return entry_of(entry.uuid).note == "about the other checkout"
  end, 10)

  it("stays in the queue of the checkout it was captured in", function()
    local here = vim.tbl_map(function(e)
      return e.uuid
    end, queue.all())
    assert.is_true(vim.tbl_contains(here, entry.uuid))
    assert.same(count_before + 1, queue.count())
    assert.same(other_before, queue.count_in(other))
  end)

  it("is still an entry with nowhere to be saved, as the warning says", function()
    assert.same(1, said(queue.unfiled_phrase(1)))
    for _, checkout in ipairs({ root, other }) do
      for _, stored in ipairs(state.load(checkout).queue) do
        assert.are_not.same(entry.uuid, stored.uuid)
      end
    end
  end)
end)

describe("the queue owner closing the connection", function()
  local held = vim.tbl_map(function(e)
    return e.uuid
  end, queue.entries())
  owner:drop_clients()
  vim.wait(3000, function()
    return said("Queue sync stopped") > 0
  end, 10)
  restore_notify()

  it("says once that the sync stopped", function()
    assert.same(1, said("Queue sync stopped"))
  end)

  it("keeps the plugin's own entries in the queue, and takes the mirrored entry out", function()
    assert.is_true(vim.tbl_contains(held, FOREIGN:lower()))
    assert.same(
      vim.tbl_filter(function(uuid)
        return uuid ~= FOREIGN:lower()
      end, held),
      vim.tbl_map(function(e)
        return e.uuid
      end, queue.entries())
    )
  end)
end)

owner:stop()
