-- The **mirrored entries** of the **sync**: the notes that other tools made, in the queue
-- while a queue owner listens, with a label, and never persisted or placed.
--
-- Driven through the public surface only: `setup()`, `annotate()`, the queue float and its
-- keys, the review view, the overlay, the copy, the submit and the queue's reads. The
-- transport is real: a Unix socket in a temporary directory, served by
-- tests/fake_queue_owner.lua in this process. The restart case runs two child Neovim
-- processes (sync_mirrored_child.lua) against the same fake.
--
-- The cases run from top to bottom and build on each other. One deliberate wait of about
-- 2 s, for the reconnect after the queue owner closes the connection.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))
-- A second checkout, to see that the mirrored entries are in every checkout's queue.
local other = assert(vim.uv.fs_realpath(h.fixture("mkfixture")))

local queue = require("codereview.queue")
local state = require("codereview.state")
local view = require("codereview.view")

local owner = fake.start()
local messages, restore_notify = h.capture_notify()

---What the stub composer answers with.
local reply = "the note"
---What the stub type picker chooses: the row that holds this text.
local answer = "bug"
vim.ui.select = function(items, _, cb)
  for i, item in ipairs(items) do
    if type(item) == "string" and item:find(answer, 1, true) then
      return cb(item, i)
    end
  end
  cb(nil, nil)
end

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
      return { tool = "custom", address = to and to.id or "none", cwd = root }
    end,
    wait = 1000,
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

---@param uuid string
---@return CRAnnotation|nil
local function entry_of(uuid)
  for _, e in ipairs(queue.entries()) do
    if e.uuid == uuid:lower() then
      return e
    end
  end
end

---The requests of one op, in order.
---@param op string
---@return table[]
local function sent(op)
  return vim.tbl_filter(function(r)
    return r.op == op
  end, owner.requests)
end

---Wait for one more request of `op` than there are now, after `fn` runs.
---@param op string
---@param fn fun()
---@return table|nil request
local function next_request(op, fn)
  local before = #sent(op)
  fn()
  wait(function()
    return #sent(op) > before
  end)
  return sent(op)[before + 1]
end

---The rows of the queue float, opened for the read and closed after it.
---@return string
local function float_text()
  codereview.queue()
  local win = vim.api.nvim_get_current_win()
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
  vim.api.nvim_win_close(win, true)
  return text
end

---Open the queue float with the cursor on the row that holds `needle`, press `keys`, and
---close the float if it is still open.
---@param needle string
---@param keys string
local function in_float(needle, keys)
  codereview.queue()
  local win = vim.api.nvim_get_current_win()
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  local row
  for i, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      row = i
      break
    end
  end
  assert(row, "no row in the queue float holds " .. needle)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  h.feed(keys)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

---Every uuid that a file holds, found in its raw text, in lower case.
---@param file string
---@return string
local function raw(file)
  if vim.fn.filereadable(file) == 0 then
    return ""
  end
  return table.concat(vim.fn.readfile(file), "\n"):lower()
end

---The two state files that this checkout's entries can be written to.
---@return string
local function stores()
  return raw(state.global_path()) .. "\n" .. raw(state.path(root))
end

---Answer a request that the fake held back with `delay(op, math.huge)`, as the queue owner
---does: the change and its `queue` event, then the reply.
---@param r table
---@param change fun()|nil
---@param answer_with table|nil The reply; `ok` when nil
local function finish(r, change, answer_with)
  if change then
    change()
    owner:changed()
  end
  owner:write(owner.clients[#owner.clients], vim.tbl_extend("force", answer_with or { ok = true }, { req = r.req }))
end

---A note that another tool made.
---@param id string
---@param fields table
---@return table
local function foreign(id, fields)
  return vim.tbl_extend("force", {
    id = id,
    type = "bug",
    note = "a note",
    selection = { none = vim.empty_dict() },
    source = vim.empty_dict(),
    createdAt = "2026-11-02T10:00:00Z",
  }, fields)
end

local AREA = "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"
local PAGE = "2C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"
local APP = "3C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"
local NONE = "4C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"
local FILE = "5C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"
local HERDR = "6C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"
local MIRRORED = { AREA, PAGE, APP, NONE, FILE, HERDR }

local NOTES = {
  foreign(AREA, {
    note = "the button is cut off",
    selection = { area = { imagePath = "/tmp/shot.png" } },
    source = { appName = "Helium", windowTitle = "Checkout" },
  }),
  foreign(PAGE, {
    type = "question",
    note = "why this wording",
    selection = { text = { _0 = "Sign in" } },
    source = { appName = "Helium", url = "https://www.github.com/acme/web/pull/411", pageTitle = "PR 411" },
  }),
  -- A type of the queue owner that the host does not declare.
  foreign(APP, {
    type = "issue",
    note = "said in the channel",
    selection = { text = { _0 = "it crashes" } },
    source = { appName = "Slack" },
  }),
  foreign(NONE, { note = "a thought from elsewhere" }),
  foreign(FILE, {
    note = "from another editor",
    selection = { text = { _0 = "x", file = { path = "/elsewhere/LeadForm.tsx", first = 12, last = 18 } } },
    source = { appName = "Zed" },
  }),
  foreign(HERDR, { note = "from a pane", source = { editor = "herdr", appName = "Ghostty" } }),
}

local LABELS = {
  [AREA] = "Area · Helium",
  [PAGE] = "Text · github.com",
  [APP] = "Text · Slack",
  [NONE] = "Note",
  [FILE] = "LeadForm.tsx · 12–18 · Zed",
  [HERDR] = "Note · herdr",
}

wait(function()
  return said("Queue sync started") > 0
end)

-- The plugin's own entries: a bare note, and a capture from a buffer, for the overlay.
vim.cmd("enew")
reply = "own bare note"
codereview.annotate("question")
vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
reply = "own line note"
codereview.annotate("bug", { first = 2, last = 2 })
wait(function()
  return #owner.queue == 2
end)
local own = vim.tbl_map(function(e)
  return e.uuid
end, queue.entries())

describe("a snapshot with notes of other tools", function()
  local highest = 0
  for _, e in ipairs(queue.entries()) do
    highest = math.max(highest, e.id)
  end
  -- Between the plugin's two entries, so that the order cannot come from the kind.
  local held = vim.deepcopy(owner.queue)
  local notes = { held[1] }
  vim.list_extend(notes, vim.deepcopy(NOTES))
  notes[#notes + 1] = held[2]
  owner:push_queue(notes)
  wait(function()
    return entry_of(HERDR) ~= nil
  end)

  it("makes each a mirrored entry: a loose entry of the bare-note kind, with its note and type", function()
    for i, uuid in ipairs(MIRRORED) do
      local e = assert(entry_of(uuid), uuid)
      assert.same({ true, "note", NOTES[i].type, NOTES[i].note }, { e.mirrored, e.kind, e.type, e.note })
      assert.is_nil(e.path)
      assert.is_nil(e.abs_path)
    end
  end)

  it("labels each from its selection and its source", function()
    for _, uuid in ipairs(MIRRORED) do
      assert.same(LABELS[uuid], entry_of(uuid).label)
    end
  end)

  it("gives the mirrored entries the next ids, in snapshot order", function()
    for i, uuid in ipairs(MIRRORED) do
      assert.same(highest + i, entry_of(uuid).id)
    end
  end)

  it("counts them in the queue count, in this checkout and in every other one", function()
    assert.same(2 + #MIRRORED, codereview.count())
    assert.same(queue.count_in(other) + 1 + #MIRRORED, queue.count_for(other))
  end)

  it("lists each in the queue float with its label and its note", function()
    local text = float_text()
    for i, uuid in ipairs(MIRRORED) do
      assert.is_truthy(text:find(LABELS[uuid], 1, true), LABELS[uuid])
      assert.is_truthy(text:find(NOTES[i].note, 1, true), NOTES[i].note)
    end
  end)

  it("writes none of them to a state file", function()
    assert.is_truthy(stores():find(own[1], 1, true))
    for _, uuid in ipairs(MIRRORED) do
      assert.is_falsy(stores():find(uuid:lower(), 1, true), uuid)
    end
  end)
end)

describe("placement", function()
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
  local buf = vim.api.nvim_get_current_buf()
  local overlay = require("codereview.overlay")
  local ok_overlay, err_overlay = pcall(codereview.overlay, "inline")

  ---Every chunk of text the captions on the buffer draw, as one string.
  local function captions()
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

  local ok_open, err_open = pcall(view.open, "branch")
  local V = assert(view.current(), "the review did not open")
  local drawn = {}
  for _, m in ipairs(h.virt_marks(V)) do
    for _, line in ipairs(m[4].virt_lines) do
      for _, chunk in ipairs(line) do
        drawn[#drawn + 1] = chunk[1]
      end
    end
  end
  drawn = table.concat(drawn)

  local jumped = said("there is nowhere to jump to")
  local win_before = vim.api.nvim_get_current_win()
  local ok_jump, err_jump = pcall(in_float, LABELS[AREA], "<CR>")

  it("paints the overlay without them", function()
    assert.is_true(ok_overlay, err_overlay)
    assert.is_truthy(captions():find("own line note", 1, true))
    for i = 1, #MIRRORED do
      assert.is_falsy(captions():find(NOTES[i].note, 1, true))
    end
  end)

  it("paints the review view without them", function()
    assert.is_true(ok_open, err_open)
    assert.is_truthy(drawn:find("own line note", 1, true))
    for i = 1, #MIRRORED do
      assert.is_falsy(drawn:find(NOTES[i].note, 1, true))
    end
  end)

  it("does not jump from the queue float to a mirrored entry, and says why", function()
    assert.is_true(ok_jump, err_jump)
    assert.same(jumped + 1, said("there is nowhere to jump to"))
    assert.same(win_before, vim.api.nvim_get_current_win())
  end)

  view.close()
  codereview.overlay("inline")
end)

describe("a copy to a register", function()
  vim.fn.setreg("+", "")
  local ok, err = pcall(codereview.copy)
  local text = vim.fn.getreg("+")

  it("renders each mirrored entry as a bare note headed by its label", function()
    assert.is_true(ok, err)
    for i, uuid in ipairs(MIRRORED) do
      assert.is_truthy(text:find(LABELS[uuid], 1, true), LABELS[uuid])
      assert.is_truthy(text:find(NOTES[i].note, 1, true), NOTES[i].note)
    end
    assert.is_truthy(text:find("Annotations — 8 items", 1, true))
  end)
end)

describe("a copy of a mirrored entry with an empty note", function()
  local EMPTY = "7C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"
  local held = vim.deepcopy(owner.queue)
  owner:push_queue(vim.list_extend(vim.deepcopy(held), {
    foreign(EMPTY, {
      note = "  ",
      selection = { area = { imagePath = "/tmp/empty.png" } },
      source = { appName = "Preview" },
    }),
  }))
  wait(function()
    return entry_of(EMPTY) ~= nil
  end)
  vim.fn.setreg("+", "")
  codereview.copy()
  local lines = vim.split(vim.fn.getreg("+"), "\n")
  local at
  for i, line in ipairs(lines) do
    if line:match("^### %d+%. Area · Preview$") then
      at = i
    end
  end
  owner:push_queue(held)
  wait(function()
    return entry_of(EMPTY) == nil
  end)

  it("renders its heading only, as the queue owner leaves an empty note out", function()
    assert.is_not_nil(at, table.concat(lines, "\n"))
    local after = lines[at + 1]
    assert.is_true(after == nil or (after == "" and (lines[at + 2] or ""):match("^##") ~= nil), after)
  end)
end)

describe("a sent that names only a mirrored entry", function()
  local batches = #state.global_archive() + #state.archive(root)
  owner:push({
    event = "sent",
    ids = { PAGE },
    target = { tool = "custom", address = "agent", cwd = root },
    preamble = "",
    text = "Annotations — 1 item\n\n## Questions (1)\n\n### 1. Selected text from Helium",
    at = "2026-11-02T10:00:00Z",
  })
  vim.wait(150)

  it("archives nothing, also with the text of the event", function()
    assert.same(batches, #state.global_archive() + #state.archive(root))
    assert.is_falsy(stores():find(PAGE:lower(), 1, true))
    assert.is_falsy(stores():find("selected text from helium", 1, true))
  end)
end)

describe("an edit of a mirrored entry from the queue float", function()
  owner:delay("update", math.huge)
  reply = "edited in Neovim"
  local r = assert(next_request("update", function()
    in_float(NOTES[1].note, "e")
  end))
  local waiting = float_text()
  -- A snapshot that the queue owner wrote before it read the `update`.
  owner.rev = owner.rev + 1
  owner:push(vim.tbl_extend("force", { event = "queue" }, owner:snapshot()))
  vim.wait(150)
  local after_snapshot = float_text()
  owner:delay("update", nil)
  finish(r, function()
    owner.queue[owner:find(AREA)].note = "edited in Neovim"
  end)
  wait(function()
    return owner.queue[owner:find(AREA)].note == "edited in Neovim"
  end)

  it("sends update with the uuid and the new note only", function()
    assert.same({ op = "update", id = AREA:lower(), note = "edited in Neovim", req = r.req }, r)
  end)

  it("shows the new note in the float while the update waits, also over an older snapshot", function()
    assert.is_truthy(waiting:find("edited in Neovim", 1, true))
    assert.is_truthy(after_snapshot:find("edited in Neovim", 1, true))
    assert.is_falsy(after_snapshot:find(NOTES[1].note, 1, true))
  end)

  it("names it by its label in the message", function()
    assert.same(1, said("Edited bug Area · Helium"))
  end)

  it("writes it to no state file", function()
    assert.is_falsy(stores():find(AREA:lower(), 1, true))
  end)
end)

describe("a change of type of a mirrored entry from the queue float", function()
  answer = "question"
  local r = assert(next_request("update", function()
    in_float(LABELS[NONE], "t")
  end))

  it("sends update with the new type only", function()
    assert.same({ op = "update", id = NONE:lower(), type = "question", req = r.req }, r)
    assert.same("question", owner.queue[owner:find(NONE)].type)
  end)
end)

describe("an edit of a mirrored entry that the queue owner refuses", function()
  owner:refuse("update", "bad request: test")
  reply = "refused in Neovim"
  next_request("update", function()
    in_float(NOTES[2].note, "e")
  end)
  owner:refuse("update", nil)
  wait(function()
    return entry_of(PAGE).note == NOTES[2].note
  end)
  local refused = float_text()
  -- The queue owner's next change of the note wins: the refused edit is not kept in Neovim.
  owner.queue[owner:find(PAGE)].note = "changed in the other tool"
  owner:changed()
  wait(function()
    return entry_of(PAGE).note == "changed in the other tool"
  end)

  it("shows the note that the queue owner holds again", function()
    assert.is_falsy(refused:find("refused in Neovim", 1, true))
    assert.is_truthy(refused:find(NOTES[2].note, 1, true))
  end)

  it("says so once", function()
    assert.same(1, said("did not take an edit (bad request: test)"))
  end)

  it("lets the next snapshot of the queue owner win", function()
    assert.same("changed in the other tool", entry_of(PAGE).note)
  end)
end)

describe("an edit of a mirrored entry that another tool dropped a moment before", function()
  owner:delay("update", math.huge)
  reply = "edited after the drop"
  local r = assert(next_request("update", function()
    in_float(LABELS[HERDR], "e")
  end))
  owner:delay("update", nil)
  -- The other tool drops it before the queue owner reads the `update`.
  table.remove(owner.queue, owner:find(HERDR))
  owner:changed()
  vim.wait(150)
  local keeps = #sent("keep")
  finish(r, nil, { ok = false, error = "unknown id" })
  wait(function()
    return entry_of(HERDR) == nil
  end)
  vim.wait(150)

  it("leaves the queue, and is not kept again as an entry of this plugin", function()
    assert.is_nil(entry_of(HERDR))
    assert.same(keeps, #sent("keep"))
    assert.is_nil(owner:find(HERDR))
  end)
end)

describe("a drop of a mirrored entry from the queue float", function()
  local r = assert(next_request("remove", function()
    in_float(LABELS[APP], "x")
  end))
  wait(function()
    return owner:find(APP) == nil
  end)

  it("sends remove with the uuid", function()
    assert.same({ op = "remove", ids = { APP:lower() }, req = r.req }, r)
    assert.is_nil(entry_of(APP))
  end)
end)

describe("a submit that holds mirrored entries", function()
  view.pick_target()
  local batch = vim.tbl_map(function(e)
    return e.uuid
  end, queue.all())
  local r = assert(next_request("send", function()
    codereview.submit()
  end))
  wait(function()
    return #queue.entries() == 0
  end)
  vim.wait(150)

  it("sends the uuids of the whole batch, mirrored entries too", function()
    assert.same(batch, r.ids)
    for _, uuid in ipairs({ AREA, PAGE, NONE, FILE }) do
      assert.is_true(vim.tbl_contains(r.ids, uuid:lower()), uuid)
    end
  end)

  it("keeps the text of sent with the batch", function()
    local archived = state.archive(root)[1]
    assert.same("string", type(archived.text))
    assert.is_truthy(archived.text:find("Annotations —", 1, true))
  end)

  it("archives the plugin's own entries from sent, and no mirrored entry", function()
    local archived = vim.json.encode({ state.global_archive(), state.archive(root) }):lower()
    assert.is_truthy(archived:find(own[1], 1, true))
    assert.is_truthy(archived:find(own[2], 1, true))
    for _, uuid in ipairs(MIRRORED) do
      assert.is_falsy(archived:find(uuid:lower(), 1, true), uuid)
    end
    assert.is_falsy(stores():find(AREA:lower(), 1, true))
  end)
end)

describe("the queue owner closing the connection", function()
  vim.cmd("enew")
  reply = "own note kept"
  codereview.annotate("question")
  local kept = assert(queue.all()[1])
  wait(function()
    return owner:find(kept.uuid) ~= nil
  end)
  owner:push_queue({ owner.queue[1], foreign(AREA, { note = "back again" }) })
  wait(function()
    return entry_of(AREA) ~= nil
  end)

  -- A drop whose `remove` the queue owner never reads: then the connection closes.
  owner:delay("remove", math.huge)
  next_request("remove", function()
    in_float("back again", "x")
  end)
  owner:delay("remove", nil)
  assert.is_nil(entry_of(AREA))

  owner:push_queue({ owner.queue[1], owner.queue[2], foreign(NONE, { note = "left behind" }) })
  wait(function()
    return entry_of(NONE) ~= nil
  end)
  local float_before = float_text()
  codereview.queue()
  local float = vim.api.nvim_get_current_win()
  local stopped = said("Queue sync stopped")
  owner:drop_clients()
  wait(function()
    return said("Queue sync stopped") > stopped
  end)
  local float_after = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")
  vim.api.nvim_win_close(float, true)

  it("takes the mirrored entries out of the queue and the float, and keeps the plugin's own", function()
    assert.is_truthy(float_before:find("left behind", 1, true))
    assert.is_nil(entry_of(NONE))
    assert.same(
      { kept.uuid },
      vim.tbl_map(function(e)
        return e.uuid
      end, queue.entries())
    )
    assert.is_falsy(float_after:find("left behind", 1, true))
    assert.is_truthy(float_after:find("own note kept", 1, true))
  end)

  it("writes no mirrored entry to a state file", function()
    assert.is_truthy(stores():find(kept.uuid, 1, true))
    for _, uuid in ipairs(MIRRORED) do
      assert.is_falsy(stores():find(uuid:lower(), 1, true), uuid)
    end
  end)

  -- The next connect: a queue operation 2 s after the last attempt. Its `list` is held, and
  -- a snapshot comes before the reply, so the mirrored entry is in the queue before the
  -- connect keeps anything. An edit of it then cannot be sent yet.
  local from = #owner.requests + 1
  owner:delay("list", math.huge)
  vim.wait(2100)
  wait(function()
    codereview.queue()
    vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
    return #sent("list") > 0 and sent("list")[#sent("list")].req ~= nil and #owner.requests >= from + 2
  end)
  owner:delay("list", nil)
  owner:changed()
  wait(function()
    return entry_of(AREA) ~= nil
  end)
  reply = "edited before the keep"
  in_float("back again", "e")
  local edited = entry_of(AREA).note
  local list = sent("list")[#sent("list")]
  owner:write(owner.clients[#owner.clients], vim.tbl_extend("force", { ok = true, req = list.req }, owner:snapshot()))
  wait(function()
    return said("Queue sync started") > 1
  end)
  vim.wait(150)

  it("sends nothing for the mirrored entry: not the drop whose remove had no reply, not the edit", function()
    assert.same("edited before the keep", edited)
    local after = { unpack(owner.requests, from) }
    assert.same(
      { "hello", "subscribe", "list", "keep" },
      vim.tbl_map(function(r)
        return r.op
      end, after)
    )
    for _, r in ipairs(after) do
      local text = vim.json.encode(r):lower()
      assert.is_falsy(text:find(AREA:lower(), 1, true), r.op)
    end
  end)

  it("shows it again from the snapshot, with the note the queue owner holds", function()
    assert.is_true(entry_of(AREA).mirrored)
    assert.same("back again", entry_of(AREA).note)
  end)
end)

describe("a restart in a second process", function()
  ---@param mode string
  ---@return vim.SystemCompleted
  local function session(mode)
    local result
    vim.system({
      vim.v.progpath,
      "--clean",
      "-l",
      vim.fs.joinpath(h.root, "tests", "codereview", "sync_mirrored_child.lua"),
    }, {
      cwd = fixture,
      text = true,
      env = {
        XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
        FIXTURE = fixture,
        SOCKET = owner.path,
        MODE = mode,
      },
    }, function(r)
      result = r
    end)
    -- Not `SystemObj:wait`: it runs only fast events, and the fake queue owner handles each
    -- line in a scheduled callback, so the child would get no reply.
    vim.wait(60000, function()
      return result ~= nil
    end, 10)
    return assert(result, "the child did not exit")
  end

  -- The queue owner holds a mirrored entry for the child to see.
  owner:push_queue({ owner.queue[1], foreign(PAGE, { note = "seen by the child" }) })
  local wrote = session("write")
  local wrote_out = (wrote.stdout or "") .. (wrote.stderr or "")
  local on_disk = stores()
  local read = session("read")
  local read_out = (read.stdout or "") .. (read.stderr or "")

  it("the first process saw the mirrored entry and captured its own", function()
    assert.same(0, wrote.code, wrote_out)
    assert.is_truthy(wrote_out:find("mirrored: " .. PAGE:lower(), 1, true), wrote_out)
    assert.is_truthy(wrote_out:find("captured: ", 1, true), wrote_out)
  end)

  it("wrote no mirrored entry to a state file", function()
    assert.is_falsy(on_disk:find(PAGE:lower(), 1, true))
    assert.is_truthy(on_disk:find(wrote_out:match("captured: (%S+)"), 1, true))
  end)

  it("the second process, with no queue owner, restores no mirrored entry", function()
    assert.same(0, read.code, read_out)
    assert.is_truthy(read_out:find(wrote_out:match("captured: (%S+)"), 1, true), read_out)
    assert.is_falsy(read_out:find(PAGE:lower(), 1, true), read_out)
  end)
end)

restore_notify()
owner:stop()
