-- A manual check of the **sync** against a real **queue owner**. Not a spec: CI has no queue
-- owner, and `make test` collects only `*_spec.lua`.
--
--   nvim --headless --clean -l tests/sync_manual.lua            # the real queue owner
--   FAKE=1 nvim --headless --clean -l tests/sync_manual.lua     # the fake, for comparison
--
-- `QUEUE_SOCKET` names another socket; the default is Anymark's. What it does, in order:
--
--   0. A raw `hello` with no types (so the queue owner adopts none) and a raw `list`. It
--      stops when the queue is not empty, or when one of the plugin's five built-in types is
--      missing, because the plugin's `hello` would then add it to the queue owner's types.
--   1. Starts the plugin with `sync` pointed at a recording proxy in front of the socket, in a
--      temporary repository and a temporary state directory, with the plugin's own five
--      types. Two entries are in the store before the connect: one good, and one whose uuid
--      is not a UUID, which the queue owner must refuse.
--   2. Captures a line, a deleted line and a hunk in a review, a range and a whole file from
--      a buffer, a bare note, an untyped entry and a note that is not valid UTF-8.
--   3. Reads the queue back with a raw `list`, and compares each stored note with the note
--      that was sent, and each entry the snapshot rebuilt with the entry as captured.
--   4. Shows the refusal: the queue owner's error, the entry still local, one warning.
--   5. Closes the plugin's connection at the proxy (not the queue owner), shows that the
--      entries stay, then reconnects and shows that the warning is not said again.
--
-- It never sends `send`. In a `finally` path it removes every uuid that the plugin kept, with
-- a raw `remove`, and shows that the queue is then what step 0 read. Every raw line is
-- printed. It exits 0 when every check passed, 1 when one failed, 2 when it refused to start.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname() .. "-state"
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_SYSTEM = "/dev/null"
vim.o.columns, vim.o.lines = 110, 40

local function say(...)
  io.stdout:write(table.concat(vim.tbl_map(tostring, { ... }), " ") .. "\n")
end

local failures = 0
local function check(ok, what)
  say(ok and "PASS" or "FAIL", what)
  if not ok then
    failures = failures + 1
  end
end

local owner
local SOCKET = vim.env.QUEUE_SOCKET or vim.fn.expand("~/Library/Application Support/Anymark/anymark.sock")
if vim.env.FAKE then
  owner = require("tests.fake_queue_owner").start()
  SOCKET = owner.path
end
say("socket:", SOCKET)

--- A raw client ------------------------------------------------------------------

---Send `hello` (no types) and then each request on one new connection, and give the reply
---to each request, by its index.
---@param requests table[]
---@return table[] replies, string[] lines
local function raw(requests)
  local pipe = vim.uv.new_pipe(false)
  local lines, buffer, failed = {}, "", nil
  pipe:connect(SOCKET, function(err)
    if err then
      failed = err
      return
    end
    pipe:read_start(function(_, data)
      if not data then
        return
      end
      buffer = buffer .. data
      while buffer:find("\n", 1, true) do
        local i = buffer:find("\n", 1, true)
        lines[#lines + 1] = buffer:sub(1, i - 1)
        buffer = buffer:sub(i + 1)
      end
    end)
    local all = { { op = "hello", protocol = 1, client = "codereview.nvim manual check" } }
    vim.list_extend(all, requests)
    for i, r in ipairs(all) do
      pipe:write(vim.json.encode(vim.tbl_extend("force", r, { req = "raw" .. i })) .. "\n")
    end
  end)
  local replies = {}
  vim.wait(5000, function()
    if failed then
      return true
    end
    replies = {}
    for _, line in ipairs(lines) do
      local msg = vim.json.decode(line, { luanil = { object = true, array = true } })
      local n = msg.req and tonumber(msg.req:match("^raw(%d+)$"))
      if n and n > 1 then
        replies[n - 1] = msg
      end
    end
    return vim.tbl_count(replies) == #requests
  end, 10)
  pipe:close()
  assert(not failed, ("cannot connect to %s: %s"):format(SOCKET, tostring(failed)))
  return replies, lines
end

--- Step 0 ------------------------------------------------------------------------

local before_replies, before_lines = raw({ { op = "list" } })
local before = before_replies[1]
say("--- step 0: the queue before")
for _, line in ipairs(before_lines) do
  say("<", line)
end
if not before or not before.ok or #(before.queue or {}) > 0 then
  say("REFUSED: the queue is not empty, or list failed; nothing was changed")
  os.exit(2)
end
local have = {}
for _, t in ipairs(before.types or {}) do
  have[t.id] = true
end
for _, name in ipairs({ "bug", "fix", "suggestion", "nitpick", "issue" }) do
  if not have[name] then
    say("REFUSED: the queue owner has no type " .. name .. ", and the plugin's hello would add it")
    os.exit(2)
  end
end

--- The recording proxy -----------------------------------------------------------

---@type { dir: string, line: string }[]
local record = {}
local proxy_path = vim.fn.tempname() .. ".sock"
local proxy = vim.uv.new_pipe(false)
assert(proxy:bind(proxy_path))
---@type table|nil
local pair = nil

---Split a stream into lines for the record, and hand the bytes on as they came.
local function tap(dir)
  local buffer = ""
  return function(data)
    buffer = buffer .. data
    while buffer:find("\n", 1, true) do
      local i = buffer:find("\n", 1, true)
      record[#record + 1] = { dir = dir, line = buffer:sub(1, i - 1) }
      buffer = buffer:sub(i + 1)
    end
  end
end

proxy:listen(4, function()
  local client, upstream = vim.uv.new_pipe(false), vim.uv.new_pipe(false)
  proxy:accept(client)
  local this = { client = client, upstream = upstream, waiting = {}, open = false }
  pair = this
  local out, back = tap(">"), tap("<")
  local function close()
    for _, p in ipairs({ client, upstream }) do
      if not p:is_closing() then
        p:close()
      end
    end
  end
  this.close = close
  client:read_start(function(_, data)
    if not data then
      return close()
    end
    out(data)
    if this.open then
      upstream:write(data)
    else
      this.waiting[#this.waiting + 1] = data
    end
  end)
  upstream:connect(SOCKET, function(err)
    if err then
      return close()
    end
    this.open = true
    for _, data in ipairs(this.waiting) do
      upstream:write(data)
    end
    upstream:read_start(function(_, data)
      if not data then
        return close()
      end
      back(data)
      client:write(data)
    end)
  end)
end)

--- The plugin --------------------------------------------------------------------

local h = require("tests.helpers")
local fixture = h.fixture("mkfixture")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local function uuid()
  local b = { vim.uv.random(16):byte(1, 16) }
  b[7] = b[7] % 16 + 0x40
  b[9] = b[9] % 64 + 0x80
  return ("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"):format(unpack(b))
end

local state = require("codereview.state")
local GOOD, BAD = uuid(), "not-a-uuid"
local function bare(id, u, note)
  return { id = id, uuid = u, type = "bug", kind = "note", key = "note:0", inline = false, note = note, at = os.time() }
end
vim.fn.mkdir(vim.fs.dirname(state.global_path()), "p")
vim.fn.writefile({
  vim.json.encode({
    version = 1,
    archive = {},
    queue = { bare(1, GOOD, "left by the last session"), bare(2, BAD, "a uuid the queue owner cannot read") },
  }),
}, state.global_path())

local messages = {}
local notify = vim.notify
vim.notify = function(msg, ...)
  messages[#messages + 1] = msg
  return notify(msg, ...)
end
local function said(needle)
  local n = 0
  for _, m in ipairs(messages) do
    n = n + (m:find(needle, 1, true) and 1 or 0)
  end
  return n
end

local compose_text = "the note"
local codereview = require("codereview")
local queue = require("codereview.queue")

local function entry_of(u)
  for _, e in ipairs(queue.entries()) do
    if e.uuid:lower() == u:lower() then
      return e
    end
  end
end

---Every field path where two values differ.
local function diff(a, b, path, out)
  out = out or {}
  path = path or ""
  if type(a) == "table" and type(b) == "table" then
    local keys = {}
    for k in pairs(a) do
      keys[k] = true
    end
    for k in pairs(b) do
      keys[k] = true
    end
    for k in pairs(keys) do
      diff(a[k], b[k], path .. "." .. tostring(k), out)
    end
  elseif a ~= b then
    out[#out + 1] = ("%s: %s ≠ %s"):format(path, vim.inspect(a), vim.inspect(b))
  end
  return out
end

local function main()
  codereview.setup({
    syntax = false,
    compose = function(_, on_accept)
      on_accept(nil, compose_text)
    end,
    sync = {
      socket = proxy_path,
      target = function()
        return { tool = "custom", address = "none", cwd = fixture }
      end,
    },
  })
  vim.wait(8000, function()
    return said("Queue sync started") > 0
  end, 10)

  say("--- step 1: the connect, as it went over the wire")
  for _, r in ipairs(record) do
    say(r.dir, r.line)
  end
  local ops = {}
  for _, r in ipairs(record) do
    if r.dir == ">" then
      ops[#ops + 1] = vim.json.decode(r.line).op
    end
  end
  check(
    vim.deep_equal({ "hello", "subscribe", "list" }, { ops[1], ops[2], ops[3] }) and ops[4] == "keep",
    "connect order: hello, subscribe, list, keep (" .. table.concat(ops, ", ") .. ")"
  )
  check(said("Queue sync started") == 1, "the start is said once")
  local connect_lines = #record

  say("--- step 2: one capture of each shape")
  local captured = {}
  local function keep_last(label)
    local all = queue.all()
    local e = all[#all]
    captured[#captured + 1] = { label = label, uuid = e.uuid, entry = vim.deepcopy(e) }
  end
  local view = require("codereview.view")
  local annotate = require("codereview.annotate")
  view.open("branch")
  local V = assert(view.current(), "the review did not open")
  local function at(row)
    vim.api.nvim_set_current_win(V.win)
    vim.api.nvim_win_set_cursor(V.win, { assert(row, "no such row"), 0 })
  end
  at(h.row_of(V, "src/fresh.lua", function(a)
    return a.kind == "line"
  end))
  annotate.annotate("bug")
  keep_last("line (review)")
  at(h.row_of(V, "src/main.lua", function(a)
    return a.kind == "line" and V.files[a.file].hunks[a.hunk].lines[a.line].side == "del"
  end))
  annotate.annotate("fix")
  keep_last("deleted line (review, inline)")
  at(h.row_of(V, "src/main.lua", function(a)
    return a.kind == "hunk"
  end))
  annotate.annotate("suggestion")
  keep_last("hunk (review)")
  view.close()

  vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fixture, "src/main.lua")))
  codereview.annotate("nitpick", { first = 1, last = 2 })
  keep_last("range (buffer)")
  codereview.annotate("issue")
  keep_last("whole file (buffer)")
  vim.cmd("enew")
  codereview.annotate("bug")
  keep_last("bare note")
  local select = vim.ui.select
  vim.ui.select = function(items, _, cb)
    cb(items[#items], #items)
  end
  vim.cmd("enew")
  codereview.annotate(nil)
  vim.ui.select = select
  keep_last("untyped")
  compose_text = "bad \255 byte and \192\175 an overlong one"
  vim.cmd("enew")
  codereview.annotate("bug")
  compose_text = "the note"
  keep_last("not valid UTF-8")
  -- Until the last `queue` event holds every capture, so each entry was rebuilt from it.
  vim.wait(5000, function()
    local last
    for _, r in ipairs(record) do
      if r.dir == "<" and r.line:find('"event":"queue"', 1, true) then
        last = r.line:upper()
      end
    end
    for _, c in ipairs(captured) do
      if not last or not last:find(c.uuid:upper(), 1, true) then
        return false
      end
    end
    return true
  end, 50)
  vim.wait(200)

  for i = connect_lines + 1, #record do
    say(record[i].dir, record[i].line)
  end

  say("--- step 3: what the queue owner stored, beside what the plugin sent")
  local sent = {}
  for _, r in ipairs(record) do
    if r.dir == ">" then
      local msg = vim.json.decode(r.line, { luanil = { object = true, array = true } })
      for _, note in ipairs(msg.op == "keep" and msg.notes or {}) do
        sent[note.id:lower()] = note
      end
    end
  end
  local listed = raw({ { op = "list" } })[1]
  local stored = {}
  for _, note in ipairs(listed.queue or {}) do
    stored[note.id:lower()] = note
  end
  for _, c in ipairs(captured) do
    local u = c.uuid:lower()
    say("## " .. c.label .. " " .. u)
    say("sent:   " .. vim.json.encode(sent[u] or {}))
    say("stored: " .. vim.json.encode(stored[u] or {}))
    local d = stored[u]
        and diff(vim.tbl_extend("force", sent[u], { id = u }), vim.tbl_extend("force", stored[u], { id = u }))
      or { "not stored" }
    check(stored[u] ~= nil, c.label .. ": the queue owner took it")
    say("stored differs from sent at: " .. (#d == 0 and "nothing" or table.concat(d, "; ")))
    local rebuilt = entry_of(u)
    local r = rebuilt and diff(c.entry, rebuilt) or { "not in the local queue" }
    say("rebuilt differs from captured at: " .. (#r == 0 and "nothing" or table.concat(r, "; ")))
    check(#r == 0 or c.label == "not valid UTF-8", c.label .. ": the snapshot rebuilds it exactly")
  end
  check(stored[GOOD] ~= nil, "the good entry from the store went with the connect")

  say("--- step 4: the refusal")
  for _, r in ipairs(record) do
    if r.dir == "<" and r.line:find('"ok":false', 1, true) then
      say("<", r.line)
    end
  end
  for _, m in ipairs(messages) do
    if m:find("did not take", 1, true) then
      say("warning:", m)
    end
  end
  check(entry_of(BAD) ~= nil and stored[BAD] == nil, "the refused entry stays local and is not in the queue owner")
  check(said("did not take") == 1, "the refusal is said once")

  say("--- step 5: the plugin's connection closes")
  local held = vim.tbl_map(function(e)
    return e.uuid
  end, queue.entries())
  pair.close()
  vim.wait(3000, function()
    return said("Queue sync stopped") > 0
  end, 10)
  check(said("Queue sync stopped") == 1, "the stop is said once")
  check(
    vim.deep_equal(
      held,
      vim.tbl_map(function(e)
        return e.uuid
      end, queue.entries())
    ),
    "every entry stays in the local queue (" .. #held .. ")"
  )
  vim.wait(2100)
  vim.cmd("enew")
  codereview.annotate("bug")
  keep_last("bare note after the reconnect")
  vim.wait(8000, function()
    return said("Queue sync started") > 1
  end, 10)
  check(said("Queue sync started") == 2, "the reconnect starts the sync again")
  check(said("did not take") == 1, "the reconnect does not say the refusal again")
  vim.wait(1000)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  failures = failures + 1
  say("ERROR", err)
end

--- Cleanup, whatever happened ------------------------------------------------------

if pair then
  pair.close()
end
proxy:close()
local ids = {}
for _, r in ipairs(record) do
  if r.dir == ">" then
    local msg = vim.json.decode(r.line, { luanil = { object = true, array = true } })
    for _, note in ipairs(msg.op == "keep" and msg.notes or {}) do
      if note.id:match("^%x+%-%x+%-%x+%-%x+%-%x+$") and not vim.tbl_contains(ids, note.id) then
        ids[#ids + 1] = note.id
      end
    end
  end
end
say("--- cleanup: remove " .. #ids .. " ids")
local after_replies, after_lines = raw({ { op = "remove", ids = ids }, { op = "list" } })
for _, line in ipairs(after_lines) do
  say("<", line)
end
local after = after_replies[2]
check(after and vim.deep_equal(before.queue, after.queue), "the queue after equals the queue before")
check(after and vim.deep_equal(before.types, after.types), "the types after equal the types before")
if owner then
  owner:stop()
end
say(("--- %d failed"):format(failures))
os.exit(failures == 0 and 0 or 1)
