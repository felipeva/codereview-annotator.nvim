-- The **sync** of a change to an entry: an edit and a retype send `update`, a drop sends
-- `remove`, and a reconcile that changes the **stale** mark sends `update` with `review`.
-- A change that the queue owner makes comes back as a `queue` event.
--
-- Driven through the public surface only: `setup()`, `annotate()`, the review keys, the
-- queue float and its keys, and the overlay. The transport is real: a Unix socket in a
-- temporary directory, served by tests/fake_queue_owner.lua in this process.
--
-- The cases run from top to bottom and build on each other. Two deliberate waits: about
-- 5 s for the requests that get no reply, and about 2 s for the reconnect after them.
local h = require("tests.helpers")
local fake = require("tests.fake_queue_owner")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")
local root = assert(vim.uv.fs_realpath(fixture))

local config = require("codereview.config")
local queue = require("codereview.queue")
local state = require("codereview.state")

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
  sync = {
    socket = owner.path,
    target = function()
      return { tool = "custom", address = "agent", cwd = root }
    end,
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

---@param note string
---@return CRAnnotation|nil
local function by_note(note)
  for _, e in ipairs(queue.entries()) do
    if e.note == note then
      return e
    end
  end
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

---The entries in the store for entries with no repository, as written to disk.
---@return CRAnnotation[]
local function stored()
  local doc = vim.json.decode(table.concat(vim.fn.readfile(state.global_path()), "\n"))
  return doc.queue or {}
end

---The note that the queue owner holds for an entry.
---@param entry CRAnnotation
---@return table|nil
local function held(entry)
  local i = owner:find(entry.uuid)
  return i and owner.queue[i]
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

---A bare note, captured from a scratch buffer with the note `note`.
---@param note string
---@return CRAnnotation
local function bare(note)
  vim.cmd("enew")
  reply = note
  codereview.annotate("question")
  local entry = assert(by_note(note))
  wait(function()
    return #vim.tbl_filter(function(r)
      return r.op == "keep" and r.notes[1].id == entry.uuid
    end, owner.requests) > 0
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

---A `queue` event that the queue owner wrote before it read the last request: newer by
---`rev`, older by content. The fake's own queue does not change.
---@param notes table[]
local function late_snapshot(notes)
  owner.rev = owner.rev + 1
  owner:push(vim.tbl_extend("force", { event = "queue" }, owner:snapshot(nil, notes)))
end

---Run the loop long enough for an event that was pushed to be applied.
local function settle()
  vim.wait(150)
end

wait(function()
  return said("Queue sync started") > 0
end)

-- The entries every case below acts on. Bare notes, so the queue float lists each on a
-- row of its own; two buffer captures, for the stale mark; two captures in the review view,
-- for the diff's keys.
local C1 = bare("note one")
local C2 = bare("note two")
local C3 = bare("note three")
local C4 = bare("note four")
local C5 = bare("note five")
local C6 = bare("note six")
local C7 = bare("note seven")
local X = bare("note x")
local Y = bare("note y")

owner:refuse("keep", "bad request: test")
local F = bare("note refused")
wait(function()
  return said("did not take 1 annotation") > 0
end)
owner:refuse("keep", nil)

vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
reply = "worktree range"
codereview.annotate("bug", { first = 2, last = 3 })
local W1 = assert(by_note("worktree range"))
reply = "worktree line"
codereview.annotate("bug", { first = 3, last = 3 })
local W2 = assert(by_note("worktree line"))

local view = require("codereview.view")
view.open("branch")
local V = assert(view.current(), "the review did not open")
vim.api.nvim_set_current_win(V.win)

---The lowest row of the diff anchored to a line of `path`.
---@param path string
---@return integer
local function first_line_row(path)
  local best
  for row, a in pairs(V.render.anchors) do
    if V.files[a.file].path == path and a.kind == "line" and (not best or row < best) then
      best = row
    end
  end
  return assert(best, "no line of " .. path)
end

local fresh_row = first_line_row("src/fresh.lua")
local main_row = first_line_row("src/main.lua")

---Press `keys` in the diff with the cursor on `row`.
---@param row integer
---@param keys string
local function in_diff(row, keys)
  vim.api.nvim_set_current_win(V.win)
  vim.api.nvim_win_set_cursor(V.win, { row, 0 })
  h.feed(keys)
end

reply = "diff line"
in_diff(fresh_row, "ab")
local A = assert(by_note("diff line"))
reply = "diff main"
in_diff(main_row, "ab")
local B = assert(by_note("diff main"))
wait(function()
  return held(A) ~= nil and held(B) ~= nil and held(W1) ~= nil and held(W2) ~= nil
end)

describe("an edit of a note from the diff", function()
  reply = "edited in the diff"
  local r = next_request("update", function()
    in_diff(fresh_row, "e")
  end)

  it("sends update with the uuid and the new note, and nothing else", function()
    assert.same({ op = "update", id = A.uuid, note = "edited in the diff", req = r.req }, r)
  end)

  it("reaches the queue owner", function()
    assert.same("edited in the diff", held(A).note)
  end)
end)

describe("a change of type from the diff", function()
  answer = "question"
  local r = next_request("update", function()
    in_diff(fresh_row, "ct")
  end)

  it("sends update with the new type", function()
    assert.same({ op = "update", id = A.uuid, type = "question", req = r.req }, r)
    assert.same("question", held(A).type)
  end)
end)

describe("an edit of a note from the queue float", function()
  reply = "edited in the float"
  local r = next_request("update", function()
    in_float("note one", "e")
  end)

  it("sends update with the uuid and the new note", function()
    assert.same({ op = "update", id = C1.uuid, note = "edited in the float", req = r.req }, r)
  end)
end)

describe("a change to an untyped annotation from the queue float", function()
  answer = "no type"
  local r = next_request("update", function()
    in_float("edited in the float", "t")
  end)

  it("sends update with the type that has no name", function()
    assert.same({ op = "update", id = C1.uuid, type = "", req = r.req }, r)
    assert.same("", held(C1).type)
  end)

  it("stays untyped in Neovim after the snapshot of the change", function()
    assert.is_nil(entry_of(C1.uuid).type)
  end)
end)

describe("a drop from the diff", function()
  local r = next_request("remove", function()
    in_diff(main_row, "x")
  end)

  it("sends remove with the uuid", function()
    assert.same({ op = "remove", ids = { B.uuid }, req = r.req }, r)
  end)

  it("takes the entry out of both queues", function()
    assert.is_nil(held(B))
    assert.is_nil(entry_of(B.uuid))
  end)
end)

describe("a drop from the queue float", function()
  local r = next_request("remove", function()
    in_float("note two", "x")
  end)

  it("sends remove with the uuid", function()
    assert.same({ op = "remove", ids = { C2.uuid }, req = r.req }, r)
    assert.is_nil(held(C2))
  end)
end)

describe("an edit that waits for its reply", function()
  local before = vim.deepcopy(owner.queue)
  owner:delay("update", 300)
  reply = "edited before the reply"
  in_float("note three", "e")
  local at_once = entry_of(C3.uuid).note
  -- A snapshot that still holds the old note, written before the queue owner read the edit.
  late_snapshot(before)
  settle()
  local during = entry_of(C3.uuid).note
  wait(function()
    return #sent("update") > 0 and held(C3).note == "edited before the reply"
  end)
  vim.wait(300)
  owner:delay("update", nil)

  it("shows in the local queue before the reply arrives", function()
    assert.same("edited before the reply", at_once)
  end)

  it("is not undone by a snapshot that does not hold it yet", function()
    assert.same("edited before the reply", during)
  end)

  describe("and a later snapshot that differs", function()
    local notes = vim.deepcopy(owner.queue)
    notes[owner:find(C3.uuid)].note = "changed in the other tool"
    owner:push_queue(notes)
    wait(function()
      return entry_of(C3.uuid).note == "changed in the other tool"
    end)

    it("wins", function()
      assert.same("changed in the other tool", entry_of(C3.uuid).note)
    end)
  end)
end)

describe("a drop that waits for its reply", function()
  local before = vim.deepcopy(owner.queue)
  owner:delay("remove", 300)
  in_float("note four", "x")
  late_snapshot(before)
  settle()
  local during = entry_of(C4.uuid)
  vim.wait(400)
  owner:delay("remove", nil)

  it("is not undone by a snapshot that still holds the entry", function()
    assert.is_nil(during)
    assert.is_nil(entry_of(C4.uuid))
    assert.is_nil(held(C4))
  end)
end)

describe("an edit that the queue owner refuses", function()
  owner:refuse("update", "bad request: test")
  reply = "refused edit"
  in_float("note five", "e")
  wait(function()
    return said("did not take an edit") > 0
  end)
  owner:push_queue(vim.deepcopy(owner.queue))
  settle()
  reply = "refused again"
  in_float("refused edit", "e")
  wait(function()
    return #sent("update") > 0 and sent("update")[#sent("update")].note == "refused again"
  end)
  settle()
  owner:refuse("update", nil)

  it("stays in Neovim after a snapshot that holds the old note", function()
    assert.same("refused again", entry_of(C5.uuid).note)
    assert.same("note five", held(C5).note)
  end)

  it("stays on disk", function()
    local notes = vim.tbl_map(function(e)
      return e.note
    end, stored())
    assert.is_true(vim.tbl_contains(notes, "refused again"))
  end)

  it("is said once, with the queue owner's reason", function()
    assert.same(1, said("did not take an edit (bad request: test)"))
  end)
end)

describe("a drop that the queue owner refuses", function()
  owner:refuse("remove", "bad request: test")
  in_float("note six", "x")
  wait(function()
    return entry_of(C6.uuid) ~= nil
  end)
  owner:refuse("remove", nil)

  it("comes back at once, as the queue owner still holds it", function()
    assert.is_not_nil(entry_of(C6.uuid))
    assert.same(C6.id, entry_of(C6.uuid).id)
  end)

  it("is said once, with the queue owner's reason", function()
    assert.same(1, said("did not drop an annotation (bad request: test)"))
  end)
end)

describe("an edit of an entry that another tool dropped a moment before", function()
  -- The drop in the other tool: the queue owner has done it, and its event is still on the
  -- way when the edit leaves.
  table.remove(owner.queue, owner:find(C7.uuid))
  owner:delay("update", 300)
  reply = "typed after the drop"
  local keeps = #sent("keep")
  in_float("note seven", "e")
  owner:push_queue(owner.queue)
  settle()
  local during = entry_of(C7.uuid)
  wait(function()
    return held(C7) ~= nil
  end)
  owner:delay("update", nil)

  it("stays on screen while the update waits", function()
    assert.is_not_nil(during)
  end)

  it("goes back to the queue owner with keep, and the note the reviewer typed", function()
    local kept = sent("keep")[keeps + 1]
    assert.same(C7.uuid, kept.notes[1].id)
    assert.same("typed after the drop", kept.notes[1].note)
    assert.same("typed after the drop", held(C7).note)
    assert.same(C7.id, entry_of(C7.uuid).id)
  end)
end)

describe("an edit of an entry whose keep was refused", function()
  local before = #sent("update")
  reply = "edited after the refusal"
  in_float("note refused", "e")
  settle()

  it("sends nothing, as the queue owner does not hold it", function()
    assert.same(before, #sent("update"))
    assert.is_nil(held(F))
  end)

  it("stays in Neovim", function()
    assert.same("edited after the refusal", entry_of(F.uuid).note)
  end)
end)

describe("a reconcile that marks an entry stale", function()
  local path = vim.fs.joinpath(root, "src/main.lua")
  local original = vim.fn.readfile(path)
  -- W2 is dropped in the other tool, and its event is on the way when the reconcile runs.
  table.remove(owner.queue, owner:find(W2.uuid))
  owner:delay("update", 300)
  vim.fn.writefile({ "local app = require('app')", "-- moved", "local cfg = load_config()" }, path)
  local first = #sent("update")
  in_diff(fresh_row, "gr")
  wait(function()
    return #sent("update") >= first + 2
  end)
  local marks = vim.list_slice(sent("update"), first + 1)
  owner:push_queue(owner.queue)
  settle()
  local w2_during = entry_of(W2.uuid)
  vim.wait(400)
  owner:delay("update", nil)

  ---@param entry CRAnnotation
  ---@return table|nil
  local function mark_of(entry)
    for _, r in ipairs(marks) do
      if r.id == entry.uuid then
        return r
      end
    end
  end

  it("sends update with the whole review, stale set", function()
    local r = assert(mark_of(W1))
    assert.same({
      op = "update",
      id = W1.uuid,
      review = { kind = "range", inline = false, stale = true, lines = W1.lines },
      req = r.req,
    }, r)
    assert.is_true(held(W1).review.stale)
  end)

  it("sends no note and no type", function()
    for _, r in ipairs(marks) do
      assert.is_nil(r.note)
      assert.is_nil(r.type)
    end
  end)

  it("lets an entry that the queue owner no longer holds leave", function()
    assert.is_not_nil(mark_of(W2))
    assert.is_not_nil(w2_during)
    assert.is_nil(entry_of(W2.uuid))
    assert.is_nil(held(W2))
  end)

  describe("and a reconcile that clears the mark", function()
    vim.fn.writefile(original, path)
    local r = next_request("update", function()
      in_diff(fresh_row, "gr")
    end)

    it("sends update with stale cleared", function()
      assert.same(W1.uuid, r.id)
      assert.is_false(r.review.stale)
      assert.is_false(held(W1).review.stale)
    end)
  end)

  describe("and a reconcile that changes nothing", function()
    local n = #sent("update")
    in_diff(fresh_row, "gr")
    settle()

    it("sends nothing", function()
      assert.same(n, #sent("update"))
    end)
  end)
end)

describe("an edit and a drop that get no reply", function()
  local before = vim.deepcopy(owner.queue)
  owner:delay("update", math.huge)
  owner:delay("remove", math.huge)
  reply = "edit with no reply"
  in_float("note x", "e")
  in_float("note y", "x")
  late_snapshot(before)
  settle()
  local x_during, y_during = entry_of(X.uuid).note, entry_of(Y.uuid)
  vim.wait(6000, function()
    return said("did not take an edit (no reply)") > 0 and said("did not drop an annotation (no reply)") > 0
  end, 50)
  owner:delay("update", nil)
  owner:delay("remove", nil)
  -- A snapshot after the timeout, which holds the old note of X and still holds Y.
  owner:push_queue(vim.deepcopy(owner.queue))
  settle()

  it("are not undone while they wait", function()
    assert.same("edit with no reply", x_during)
    assert.is_nil(y_during)
  end)

  it("are said once each, after 5 s", function()
    assert.same(1, said("did not take an edit (no reply)"))
    assert.same(1, said("did not drop an annotation (no reply)"))
  end)

  it("keep the edit in Neovim, over the snapshot", function()
    assert.same("edit with no reply", entry_of(X.uuid).note)
  end)

  it("bring the dropped entry back, as the queue owner still holds it", function()
    assert.is_not_nil(entry_of(Y.uuid))
  end)
end)

describe("an edit from the diff while the queue owner is away", function()
  owner:drop_clients()
  wait(function()
    return said("Queue sync stopped") > 0
  end)
  local started = said("Queue sync started")
  vim.wait(2100)
  local first = #owner.requests
  reply = "edited while away"
  in_diff(fresh_row, "e")
  wait(function()
    return said("Queue sync started") > started
  end)
  wait(function()
    return held(A).note == "edited while away" and held(X).note == "edit with no reply"
  end)
  local after = vim.list_slice(owner.requests, first + 1)

  it("tries to connect again, with no float open", function()
    assert.same(
      { "hello", "subscribe", "list", "keep" },
      vim.list_slice(
        vim.tbl_map(function(r)
          return r.op
        end, after),
        1,
        4
      )
    )
  end)

  it("sends each change the queue owner did not take, in full, after the keep", function()
    local ids = {}
    for i = 5, #after do
      assert.same("update", after[i].op)
      ids[after[i].id] = after[i]
    end
    assert.same("edited while away", ids[A.uuid].note)
    assert.same("question", ids[A.uuid].type)
    assert.same("line", ids[A.uuid].review.kind)
    assert.same("edit with no reply", ids[X.uuid].note)
    assert.same("edited while away", held(A).note)
    assert.same("edit with no reply", held(X).note)
  end)

  it("keeps the entry whose keep was refused, with its edit", function()
    assert.same("edited after the refusal", held(F).note)
  end)
end)

view.close()
vim.cmd("silent! only")

describe("a change that the queue owner makes", function()
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
  local buf = vim.api.nvim_get_current_buf()
  assert.is_true(codereview.overlay("inline"))
  local overlay = require("codereview.overlay")

  ---The group of the caption chunk that draws `text`.
  local function group_of(text)
    for _, ns in ipairs({ overlay.NS, overlay.NS_ANCHOR }) do
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        for _, row in ipairs(m[4].virt_lines or {}) do
          for _, chunk in ipairs(row) do
            if chunk[1]:find(text, 1, true) then
              return chunk[2]
            end
          end
        end
      end
    end
  end
  local drawn_before = group_of("worktree range")

  local notes = vim.deepcopy(owner.queue)
  notes[owner:find(W1.uuid)].note = "retold in the other tool"
  notes[owner:find(W1.uuid)].type = "question"
  table.remove(notes, owner:find(C6.uuid))
  owner:push_queue(notes)
  wait(function()
    return entry_of(W1.uuid).note == "retold in the other tool"
  end)

  codereview.queue()
  local float = vim.api.nvim_get_current_win()
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)
  vim.api.nvim_win_close(float, true)

  ---The group heading above the row that holds `text` in the float.
  local function heading_of(text)
    local heading
    for _, line in ipairs(lines) do
      if line:match("^## ") then
        heading = line
      end
      if line:find(text, 1, true) then
        return heading
      end
    end
  end

  it("shows an edited and retyped note in the queue float", function()
    assert.is_truthy(heading_of("retold in the other tool"):find("Questions", 1, true))
  end)

  it("shows an edited and retyped note in the overlay", function()
    local question = require("codereview.types").get(config.get().types, "question")
    assert.is_not_nil(drawn_before)
    assert.are_not.same(question.hl, drawn_before)
    assert.same(question.hl, group_of("retold in the other tool"))
  end)

  it("takes an entry dropped in the queue owner out of the Neovim queue", function()
    assert.is_nil(entry_of(C6.uuid))
  end)
end)

describe("with no queue owner", function()
  owner:stop()
  wait(function()
    return said("Queue sync stopped") > 1
  end)
  local n = #owner.requests
  reply = "edited with no owner"
  in_float("typed after the drop", "e")
  in_float("edited in the float", "x")
  vim.wait(200)
  restore_notify()

  it("sends nothing", function()
    assert.same(n, #owner.requests)
  end)

  it("edits and drops in the local queue, and on disk, as without a sync", function()
    assert.is_nil(entry_of(C1.uuid))
    assert.same("edited with no owner", entry_of(C7.uuid).note)
    local uuids = vim.tbl_map(function(e)
      return e.uuid
    end, stored())
    assert.is_false(vim.tbl_contains(uuids, C1.uuid))
    assert.is_true(vim.tbl_contains(uuids, C7.uuid))
  end)
end)
