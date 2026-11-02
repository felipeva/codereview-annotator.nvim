---A fake **queue owner**: a `vim.uv` pipe server on a real Unix socket in a temporary
---directory, which speaks version 1 of the queue socket protocol.
---
---It runs in the process of the spec, on the same event loop as the plugin. So a spec waits
---with `vim.wait`, which runs the loop for both sides. Every message is handled in the main
---loop, in the order it arrived.
---
---What it does, as the queue owner's guide says:
---  * `hello` replies with `protocol`, `rev`, `queue`, `types` and `added`. A request before
---    `hello` gets `error: "hello first"`.
---  * `subscribe` makes the client get a `queue` event after each change.
---  * `keep` adds each note whose id it does not have, with the id in upper case, as the
---    real queue owner writes it. The `queue` event comes before the reply.
---  * `update`, `remove` and `send` change the queue as the guide says. `send` replies, then
---    sends a `sent` event with `text = ""`.
---  * `list` replies with the queue.
---
---What a spec controls:
---  * `owner.requests`: every request it received, decoded, in order. `owner:ops()` gives the
---    `op` of each.
---  * `owner:push_queue(notes, rev)`: replace the queue and send a `queue` event.
---  * `owner:push(event)`: send any event, for example `sent`.
---  * `owner:delay(op, ms)`: reply to `op` that much later. `owner:refuse(op, error)`: reply
---    `ok: false` with that error. Give nil to stop either.
---  * `owner:drop_clients()`: close every connection, as a queue owner that quits does.
---  * `owner:stop()`: close the connections and the server. The socket file goes with it.
local M = {}

---@class FakeQueueOwner
---@field path string
---@field requests table[]
---@field queue table[]
---@field rev integer
---@field clients table[]
local Owner = {}
Owner.__index = Owner

---@param s string
---@return string
local function upper(s)
  return s:upper()
end

---@param client table
---@param msg table
function Owner:write(client, msg)
  if not client.pipe:is_closing() then
    client.pipe:write(vim.json.encode(msg) .. "\n")
  end
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
  self:push({ event = "queue", rev = self.rev, queue = self.queue, types = {} })
end

---Replace the queue and send a `queue` event.
---@param notes table[]
---@param rev integer|nil Defaults to the next rev. A lower one tests that it is ignored.
function Owner:push_queue(notes, rev)
  self.queue = notes
  self.rev = rev or (self.rev + 1)
  self:push({ event = "queue", rev = self.rev, queue = self.queue, types = {} })
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
    if upper(note.id) == upper(id) then
      return i
    end
  end
end

---What the queue owner does for one request, without the reply's `req`.
---@param client table
---@param msg table
---@return table reply, fun()|nil after Run after the reply is written
function Owner:answer(client, msg)
  if msg.op == "hello" then
    if msg.protocol ~= 1 then
      return { ok = false, error = "protocol" }
    end
    client.hello = true
    return { ok = true, protocol = 1, rev = self.rev, queue = self.queue, types = {}, added = {} }
  end
  if not client.hello then
    return { ok = false, error = "hello first" }
  end
  if msg.op == "subscribe" then
    client.subscribed = true
    return { ok = true }
  end
  if msg.op == "list" then
    return { ok = true, rev = self.rev, queue = self.queue, types = {} }
  end
  if msg.op == "keep" then
    local added = {}
    for _, note in ipairs(msg.notes or {}) do
      if not self:find(note.id) then
        note = vim.deepcopy(note)
        note.id = upper(note.id)
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
    local i = self:find(msg.id or "")
    if not i then
      return { ok = false, error = "unknown id" }
    end
    for _, field in ipairs({ "note", "type", "review", "origin" }) do
      if msg[field] ~= nil then
        self.queue[i][field] = msg[field]
      end
    end
    self:changed()
    return { ok = true }
  end
  if msg.op == "remove" or msg.op == "send" then
    local removed = {}
    for _, id in ipairs(msg.ids or {}) do
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
        preamble = msg.preamble,
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
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= "table" then
    self:write(client, { ok = false, error = "not a JSON object" })
    return
  end
  self.requests[#self.requests + 1] = msg
  local refused = self.refusals[msg.op]
  local reply, after
  if refused then
    reply = { ok = false, error = refused }
  else
    reply, after = self:answer(client, msg)
  end
  reply.req = msg.req
  local function send()
    self:write(client, reply)
    if after then
      after()
    end
  end
  local ms = self.delays[msg.op]
  if ms then
    vim.defer_fn(send, ms)
  else
    send()
  end
end

---Close every connection, as a queue owner that quits does. The server still listens.
function Owner:drop_clients()
  for _, client in ipairs(self.clients) do
    if not client.pipe:is_closing() then
      client.pipe:close()
    end
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
  local self = setmetatable({
    path = path or (vim.fn.tempname() .. ".sock"),
    requests = {},
    queue = {},
    rev = 0,
    clients = {},
    delays = {},
    refusals = {},
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
        vim.schedule(function()
          self:receive(client, line)
        end)
      end
    end)
  end)
  return self
end

return M
