---A fake **queue owner**: a `vim.uv` pipe server on a real Unix socket in a temporary
---directory, which speaks version 1 of the queue socket protocol.
---
---It runs in the process of the spec, on the same event loop as the plugin. So a spec waits
---with `vim.wait`, which runs the loop for both sides. Every message is handled in the main
---loop, in the order it arrived.
---
---**As strict as the real queue owner where the plugin can get it wrong.** The checks
---follow the queue owner's Swift codec (`QueueProtocol.swift`, `QueueOps.swift`,
---`Annotation.swift`, `AnnotationType.swift`, `QueueServer.swift`):
---  * A line longer than `owner.max_line` bytes (8 MiB, as the owner's) closes the
---    connection. A line that is not valid UTF-8 or not a JSON object gets a reply with no
---    `req`: `not a JSON object`. A line with no `req` gets `no req`.
---  * `hello` with another protocol replies `error: "protocol"` and closes the connection.
---    Any other request before `hello` gets `hello first`.
---  * `keep` decodes every note as the owner does, and refuses the whole request with
---    `bad request: …` when one note is bad (see `check_note`).
---  * `update` with a JSON `null` for `review` or `origin` clears it. `send` that names no
---    queued id refuses `nothing to send`.
---  * Replies and `queue` events carry `rev`, `queue`, a `types` list of the owner's shape and
---    `default`. `sent` always carries `preamble` as a string.
---
---What a spec controls:
---  * `owner.requests`: every request it decoded, in order. `owner:ops()` gives the `op` of
---    each. A line it could not decode is not in it.
---  * `owner:push_queue(notes)`: replace the queue and send a `queue` event.
---    `owner:push_queue(notes, rev)` sends a stale event with that rev and changes nothing.
---  * `owner:push(event)`: send any event, for example `sent`.
---  * `owner:delay(op, ms)`: do `op` at once and reply that much later. With `math.huge`,
---    the request is recorded and lost: nothing changes, and no reply comes.
---    `owner:refuse(op, error)`: reply `ok: false` with that error. Give nil to stop either.
---  * `owner:after(op, fn)`: run `fn(owner)` once, just after the reply to the next `op`.
---  * `owner.max_line`: set it small to test the line limit.
---  * `owner:drop_clients()`: close every connection, as a queue owner that quits does.
---  * `owner:stop()`: close the connections and the server. The socket file goes with it.
local M = {}

---The owner's limit on one line, in bytes.
M.MAX_LINE = 8 * 1024 * 1024

---The owner's five built-in types, as its `AnnotationType` encodes them. `symbol` is nil for
---all five, and the owner's encoder leaves a nil out.
local BUILT_IN = {
  { "bug", "Bug", "Bugs", "diagnose and fix these", "Diagnose and fix", "red" },
  { "fix", "Fix", "Fixes", "apply these changes", "Apply this change", "amber" },
  { "suggestion", "Suggestion", "Suggestions", "evaluate; apply if sound", "Evaluate; apply if sound", "blue" },
  { "nitpick", "Nitpick", "Nitpicks", "low priority — batch these together", "Low priority, batch it", "gray" },
  { "issue", "Issue", "Issues", "do NOT fix — summarize these for tracking", "Don't fix; track it", "purple" },
}

---The most types the owner holds.
local MAX_TYPES = 16

---@class FakeQueueOwner
---@field path string
---@field requests table[]
---@field queue table[]
---@field rev integer
---@field types table[]
---@field default string
---@field clients table[]
---@field max_line integer
local Owner = {}
Owner.__index = Owner

---@param s string
---@return boolean
local function utf8_valid(s)
  if not s:find("[\128-\255]") then
    return true
  end
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1
      or (c >= 0xC2 and c <= 0xDF) and 2
      or (c >= 0xE0 and c <= 0xEF) and 3
      or (c >= 0xF0 and c <= 0xF4) and 4
      or 0
    if len == 0 or i + len - 1 > n then
      return false
    end
    for k = 1, len - 1 do
      local b = s:byte(i + k)
      if b < 0x80 or b > 0xBF then
        return false
      end
    end
    local b = s:byte(i + 1)
    if (c == 0xE0 and b < 0xA0) or (c == 0xED and b > 0x9F) or (c == 0xF0 and b < 0x90) or (c == 0xF4 and b > 0x8F) then
      return false
    end
    i = i + len
  end
  return true
end

local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
local ISO = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"
local KINDS = { line = true, range = true, hunk = true, file = true, note = true }

---@param v any
---@return boolean
local function opt_string(v)
  return v == nil or type(v) == "string"
end

---@param v any
---@return boolean
local function opt_int(v)
  return v == nil or (type(v) == "number" and v % 1 == 0)
end

---Why one note of a `keep` does not decode as the owner's `Annotation`, or nil.
---
---The owner's decoder needs `id` (a UUID), `type`, `note`, `selection`, `source` and
---`createdAt`; `review` and `origin` are optional. `selection` is one of three shapes, and
---`createdAt` is ISO 8601. This fake asks for whole seconds with `Z`, which is what the
---plugin writes: the owner also takes an offset.
---@param note any
---@param i integer The index of the note, from 0, as the owner's error names it
---@return string|nil
local function check_note(note, i)
  local at = ("notes.%d."):format(i)
  if type(note) ~= "table" then
    return "wrong type at notes." .. i
  end
  for _, field in ipairs({ "id", "type", "note", "selection", "source", "createdAt" }) do
    if note[field] == nil then
      return "missing " .. field
    end
  end
  if type(note.id) ~= "string" or not note.id:match(UUID) then
    return "bad value at " .. at .. "id"
  end
  for _, field in ipairs({ "type", "note" }) do
    if type(note[field]) ~= "string" then
      return "wrong type at " .. at .. field
    end
  end
  local sel = note.selection
  if type(sel) ~= "table" then
    return "wrong type at " .. at .. "selection"
  end
  if sel.text ~= nil then
    local text = sel.text
    if type(text) ~= "table" or type(text._0) ~= "string" then
      return "wrong type at " .. at .. "selection.text"
    end
    local file = text.file
    if file ~= nil then
      if type(file) ~= "table" or type(file.path) ~= "string" or not opt_int(file.first) or not opt_int(file.last) then
        return "wrong type at " .. at .. "selection.text.file"
      end
    end
  elseif sel.area ~= nil then
    if type(sel.area) ~= "table" or type(sel.area.imagePath) ~= "string" then
      return "wrong type at " .. at .. "selection.area"
    end
  elseif sel.none == nil then
    return "bad value at " .. at .. "selection"
  end
  if type(note.source) ~= "table" then
    return "wrong type at " .. at .. "source"
  end
  for _, field in ipairs({ "appName", "bundleID", "windowTitle", "editor", "url", "pageTitle", "herdrTab" }) do
    if not opt_string(note.source[field]) then
      return "wrong type at " .. at .. "source." .. field
    end
  end
  if type(note.createdAt) ~= "string" or not note.createdAt:match(ISO) then
    return "bad value at " .. at .. "createdAt"
  end
  local review = note.review
  if review ~= nil then
    if type(review) ~= "table" then
      return "wrong type at " .. at .. "review"
    end
    if review.kind == nil then
      return "missing kind"
    end
    if not KINDS[review.kind] then
      return "bad value at " .. at .. "review.kind"
    end
    if review.inline ~= nil and type(review.inline) ~= "boolean" then
      return "wrong type at " .. at .. "review.inline"
    end
    if review.stale ~= nil and type(review.stale) ~= "boolean" then
      return "wrong type at " .. at .. "review.stale"
    end
    if not opt_string(review.tag) then
      return "wrong type at " .. at .. "review.tag"
    end
    if review.lines ~= nil then
      if type(review.lines) ~= "table" then
        return "wrong type at " .. at .. "review.lines"
      end
      for _, l in ipairs(review.lines) do
        if type(l) ~= "string" then
          return "wrong type at " .. at .. "review.lines"
        end
      end
    end
  end
  return nil
end

---Why a `keep` line does not decode, from the raw line: `{}` and `[]` decode to the same
---empty table, and the owner tells them apart where it decodes an object.
---@param line string
---@return string|nil
local function check_raw(line)
  if line:find('"none":%[%]') then
    return "wrong type at selection.none"
  end
  if line:find('"source":%[%]') then
    return "wrong type at source"
  end
  return nil
end

---@param client table
---@param msg table
function Owner:write(client, msg)
  if not client.pipe:is_closing() then
    client.pipe:write(vim.json.encode(msg) .. "\n")
  end
end

---@param client table
function Owner:close(client)
  if not client.pipe:is_closing() then
    client.pipe:close()
  end
end

---The fields of a snapshot: in the `hello` and `list` replies and in each `queue` event.
---@param rev integer|nil
---@param queue table[]|nil
---@return table
function Owner:snapshot(rev, queue)
  return { rev = rev or self.rev, queue = queue or self.queue, types = self.types, default = self.default }
end

---Send an event to every client that subscribed.
---@param event table
function Owner:push(event)
  for _, client in ipairs(self.clients) do
    if client.subscribed then
      self:write(client, event)
    end
  end
end

function Owner:changed()
  self.rev = self.rev + 1
  self:push(vim.tbl_extend("force", { event = "queue" }, self:snapshot()))
end

---Replace the queue and send a `queue` event.
---@param notes table[]
---@param rev integer|nil With a rev given, the event is a stale one, as a real queue owner
---       can never send: the queue and the rev that the fake holds stay as they are, so a
---       later push still counts up from them.
function Owner:push_queue(notes, rev)
  if rev then
    self:push(vim.tbl_extend("force", { event = "queue" }, self:snapshot(rev, notes)))
    return
  end
  self.queue = notes
  self:changed()
end

---@param op string
---@param ms integer|nil
function Owner:delay(op, ms)
  self.delays[op] = ms
end

---@param op string
---@param err string|nil
function Owner:refuse(op, err)
  self.refusals[op] = err
end

---@param op string
---@param fn fun(owner: FakeQueueOwner)
function Owner:after(op, fn)
  self.hooks[op] = fn
end

---@return string[]
function Owner:ops()
  return vim.tbl_map(function(r)
    return r.op
  end, self.requests)
end

---The index in the queue of a note, by id without regard to case.
---@param id string
---@return integer|nil
function Owner:find(id)
  for i, note in ipairs(self.queue) do
    if note.id:upper() == id:upper() then
      return i
    end
  end
end

---Each client type the catalog lacks, after the nearest earlier one it has, as the owner
---adopts them. Gives the ids it added.
---@param types table[]|nil
---@return string[]
function Owner:adopt(types)
  local added = {}
  local function index_of(id)
    for i, t in ipairs(self.types) do
      if t.id == id then
        return i
      end
    end
  end
  for position, incoming in ipairs(types or {}) do
    local id = vim.trim(incoming.name or "")
    if id ~= "" and not index_of(id) and #self.types < MAX_TYPES then
      local label = vim.trim(incoming.label or "")
      local name = label ~= "" and label or id
      local before
      for k = position - 1, 1, -1 do
        before = index_of(vim.trim(types[k].name or ""))
        if before then
          break
        end
      end
      table.insert(self.types, (before or 0) + 1, {
        id = id,
        singular = name,
        label = name,
        directive = incoming.directive or "",
        menuHint = incoming.directive or "",
        color = "gray",
      })
      added[#added + 1] = id
    end
  end
  return added
end

---What the queue owner does for one request, without the reply's `req`.
---@param client table
---@param msg table
---@param line string The raw line, for what decoding cannot tell apart
---@return table reply, fun()|nil after Run after the reply is written
function Owner:answer(client, msg, line)
  if msg.op == "hello" then
    if msg.protocol ~= 1 then
      return { ok = false, error = "protocol" }, function()
        self:close(client)
      end
    end
    client.hello = true
    local added = self:adopt(msg.types)
    return vim.tbl_extend("force", { ok = true, protocol = 1, added = added }, self:snapshot())
  end
  if not client.hello then
    return { ok = false, error = "hello first" }
  end
  if msg.op == "subscribe" then
    client.subscribed = true
    return { ok = true }
  end
  if msg.op == "list" then
    return vim.tbl_extend("force", { ok = true }, self:snapshot())
  end
  if msg.op == "keep" then
    if type(msg.notes) ~= "table" then
      return { ok = false, error = "bad request: missing notes" }
    end
    local bad = check_raw(line)
    for i, note in ipairs(msg.notes) do
      bad = bad or check_note(note, i - 1)
    end
    if bad then
      return { ok = false, error = "bad request: " .. bad }
    end
    local added = {}
    for _, note in ipairs(msg.notes) do
      if not self:find(note.id) then
        note = vim.deepcopy(note)
        note.id = note.id:upper()
        self.queue[#self.queue + 1] = note
        added[#added + 1] = note.id
      end
    end
    if #added > 0 then
      self:changed()
    end
    return { ok = true, ids = added }
  end
  if msg.op == "update" then
    local i = type(msg.id) == "string" and self:find(msg.id)
    if not i then
      return { ok = false, error = "unknown id" }
    end
    for _, field in ipairs({ "note", "type", "review", "origin" }) do
      if msg[field] ~= nil then
        self.queue[i][field] = msg[field]
      elseif line:find(('"%s":null'):format(field)) and (field == "review" or field == "origin") then
        self.queue[i][field] = nil
      end
    end
    self:changed()
    return { ok = true }
  end
  if msg.op == "remove" or msg.op == "send" then
    if type(msg.ids) ~= "table" then
      return { ok = false, error = "bad request: missing ids" }
    end
    if msg.op == "send" then
      local any = false
      for _, id in ipairs(msg.ids) do
        any = any or self:find(id) ~= nil
      end
      if not any then
        return { ok = false, error = "nothing to send" }
      end
    end
    local removed = {}
    for _, id in ipairs(msg.ids) do
      local i = self:find(id)
      if i then
        removed[#removed + 1] = self.queue[i].id
        table.remove(self.queue, i)
      end
    end
    if #removed > 0 then
      self:changed()
    end
    if msg.op == "remove" then
      return { ok = true, removed = removed }
    end
    return { ok = true }, function()
      self:push({
        event = "sent",
        ids = removed,
        target = msg.target,
        preamble = msg.preamble or "",
        text = "",
        at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      })
    end
  end
  return { ok = false, error = "unknown op" }
end

---@param client table
---@param line string
function Owner:receive(client, line)
  local ok, msg = false, nil
  if utf8_valid(line) then
    ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  end
  if not ok or type(msg) ~= "table" or vim.islist(msg) and next(msg) ~= nil then
    self:write(client, { ok = false, error = "not a JSON object" })
    return
  end
  if type(msg.req) ~= "string" then
    self:write(client, { ok = false, error = "no req" })
    return
  end
  self.requests[#self.requests + 1] = msg
  local ms = self.delays[msg.op]
  if ms == math.huge then
    return
  end
  local refused = self.refusals[msg.op]
  local reply, after
  if refused then
    reply = { ok = false, error = refused }
  else
    reply, after = self:answer(client, msg, line)
  end
  reply.req = msg.req
  local hook = self.hooks[msg.op]
  self.hooks[msg.op] = nil
  local function send()
    self:write(client, reply)
    if after then
      after()
    end
    if hook then
      hook(self)
    end
  end
  if ms then
    vim.defer_fn(send, ms)
  else
    send()
  end
end

---Close every connection, as a queue owner that quits does. The server still listens.
function Owner:drop_clients()
  for _, client in ipairs(self.clients) do
    self:close(client)
  end
  self.clients = {}
end

function Owner:stop()
  self:drop_clients()
  if not self.server:is_closing() then
    self.server:close()
  end
end

---Start a fake queue owner.
---@param path string|nil The socket path. Defaults to a new one in Neovim's temporary
---       directory, which is short enough for the limit of about 104 bytes on macOS.
---@return FakeQueueOwner
function M.start(path)
  local types = {}
  for _, t in ipairs(BUILT_IN) do
    types[#types + 1] = { id = t[1], singular = t[2], label = t[3], directive = t[4], menuHint = t[5], color = t[6] }
  end
  local self = setmetatable({
    path = path or (vim.fn.tempname() .. ".sock"),
    requests = {},
    queue = {},
    rev = 0,
    types = types,
    default = "suggestion",
    clients = {},
    delays = {},
    refusals = {},
    hooks = {},
    max_line = M.MAX_LINE,
  }, Owner)
  self.server = vim.uv.new_pipe(false)
  assert(self.server:bind(self.path))
  self.server:listen(16, function(err)
    assert(not err, err)
    local pipe = vim.uv.new_pipe(false)
    self.server:accept(pipe)
    local client = { pipe = pipe, buffer = "", hello = false, subscribed = false }
    self.clients[#self.clients + 1] = client
    pipe:read_start(function(read_err, data)
      if read_err or not data then
        if not pipe:is_closing() then
          pipe:close()
        end
        return
      end
      client.buffer = client.buffer .. data
      while true do
        local nl = client.buffer:find("\n", 1, true)
        if not nl then
          break
        end
        local line = client.buffer:sub(1, nl - 1)
        client.buffer = client.buffer:sub(nl + 1)
        if #line > self.max_line then
          client.buffer = ""
          vim.schedule(function()
            self:close(client)
          end)
          return
        end
        if line ~= "" then
          vim.schedule(function()
            self:receive(client, line)
          end)
        end
      end
      if #client.buffer > self.max_line then
        client.buffer = ""
        vim.schedule(function()
          self:close(client)
        end)
      end
    end)
  end)
  return self
end

return M
