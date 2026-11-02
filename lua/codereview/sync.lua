---The **sync**: the queue shared with a **queue owner** through a queue socket.
---
---The only module that speaks the protocol (version 1). It owns the connection, a `vim.uv`
---pipe; the framing, one JSON object per line; the `req` counter and the replies matched by
---it; the events; and the retry. The queue stays a leaf that requires nothing: this module
---tells it what the queue is.
---
---**Not an adapter** (ADR-0012). A snapshot can only become **entries** with the plugin's
---own knowledge of an entry, so the transport cannot be the host's. The host still says
---where, with the socket path, and who, with the `target` adapter.
---
---**When no queue owner listens, nothing here does anything.** A failed connect is silent,
---and the plugin keeps its own queue exactly as it does without `sync`. The next queue
---operation tries again, at most once every 2 s.
---
---Two paths, kept apart so that later work adds to each without changing the other:
---
---  * the request path, `request`: a line out, and a callback kept under its `req`;
---  * the event path, `on_event`: one handler per event name, in `EVENTS`.
local config = require("codereview.config")
local queue = require("codereview.queue")
local state = require("codereview.state")

local M = {}

---The name this plugin gives in `hello`, and the mark in the `origin` of each note it made.
local CLIENT = "codereview.nvim"

local PROTOCOL = 1

---The shortest time between two connect attempts, in milliseconds.
local RETRY_MS = 2000

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

---@param msg string
local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "Code review" })
end

---One connection, from the connect attempt to the close.
---
---A table per connection rather than module state, so that a callback of a closed
---connection can see that it is not the current one and do nothing.
---@class CRSyncConn
---@field pipe uv.uv_pipe_t
---@field pending table<string, fun(reply: table)|false> Replies still to come, by `req`
---@field buffer string The part of a line that has not ended yet
---@field rev integer The `rev` of the last snapshot applied; a lower one is ignored
---@field keeping boolean The `keep` of the connect is written, so a new entry is kept at once
---@field confirmed boolean The queue owner has replied to the `keep` of the connect
---@field inflight table<string, true> Uuids kept and not yet confirmed by a reply
---@field ready boolean The connect is complete, and the start was announced
---@field closed boolean

---@type CRSyncConn|nil
local current = nil

---When the last connect attempt started, from `vim.uv.hrtime`, in milliseconds.
---@type number|nil
local last_try = nil

local next_req = 0

---The integer id of each uuid seen in this session, by the uuid in lower case.
---
---So a uuid keeps its id across snapshots, also after it left the queue for a time.
---@type table<string, integer>
local ids = {}

---The review view, handed in by `start`, as `init` hands it to the overlay. Requiring it
---here would put this module in a cycle through `delivery`.
---@type table|nil
local view = nil

--- Mapping ---------------------------------------------------------------------

---@param uuid string
---@return string
local function lower(uuid)
  return uuid:lower()
end

---What the note says was selected: the file and the **range**, or nothing for a **bare
---note**.
---@param entry CRAnnotation
---@return table
local function selection(entry)
  if not entry.abs_path then
    return { none = vim.empty_dict() }
  end
  -- The code without the diff column, so that another tool shows the lines as they read.
  local text = {}
  for _, line in ipairs(entry.lines or {}) do
    text[#text + 1] = line:sub(2)
  end
  return {
    text = {
      _0 = table.concat(text, "\n"),
      file = { path = entry.abs_path, first = entry.first, last = entry.last },
    },
  }
end

---An entry as the queue owner keeps it.
---
---`origin` carries the fields of the entry that the note does not, and the mark that this
---plugin made it. The note carries the rest, so an edit made in another tool reaches the
---entry. With both, `to_entry` rebuilds the entry exactly.
---@param entry CRAnnotation
---@return table
local function to_note(entry)
  return {
    id = entry.uuid,
    -- The protocol has no untyped note. The empty string is the one type id that no host
    -- type can have, and `to_entry` reads it back as nil.
    type = entry.type or "",
    note = entry.note or "",
    selection = selection(entry),
    source = { appName = "nvim" },
    createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ", entry.at),
    review = {
      kind = entry.kind,
      inline = entry.inline == true,
      tag = entry.tag,
      stale = entry.stale == true,
      lines = entry.lines,
    },
    origin = {
      client = CLIENT,
      path = entry.path,
      key = entry.key,
      blob = entry.blob,
      worktree = entry.worktree,
      at = entry.at,
    },
  }
end

---@param note table
---@return boolean
local function own(note)
  return type(note.origin) == "table" and note.origin.client == CLIENT
end

---The entry that a note of this plugin describes, without its integer id.
---@param note table A note with this plugin's origin
---@return CRAnnotation
local function to_entry(note)
  local origin, review = note.origin, note.review or {}
  local text = type(note.selection) == "table" and note.selection.text
  local file = type(text) == "table" and text.file or nil
  return {
    uuid = lower(note.id),
    type = note.type ~= "" and note.type or nil,
    note = note.note or "",
    kind = review.kind or "note",
    path = origin.path,
    abs_path = file and file.path,
    blob = origin.blob,
    worktree = origin.worktree,
    key = origin.key,
    first = file and file.first,
    last = file and file.last,
    inline = review.inline == true,
    lines = review.lines,
    tag = review.tag,
    stale = review.stale or nil,
    at = origin.at,
  }
end

---The host's types, in the host's order.
---@return table[]
local function host_types()
  local out = {}
  for _, t in ipairs(config.get().types) do
    out[#out + 1] = { name = t.name, label = t.label, directive = t.directive }
  end
  return out
end

--- The connection --------------------------------------------------------------

---Close a connection. The plugin's own entries stay in the queue: nothing here removes
---them.
---@param conn CRSyncConn
local function stop(conn)
  if conn.closed then
    return
  end
  conn.closed = true
  if not conn.pipe:is_closing() then
    conn.pipe:close()
  end
  if current == conn then
    current = nil
  end
  if conn.ready then
    info("Queue sync stopped: the queue is kept in Neovim")
  end
end

---The request path: write one request, and keep its callback under its `req`.
---@param conn CRSyncConn
---@param op string
---@param fields table|nil The fields of the request beside `req` and `op`
---@param on_reply fun(reply: table)|nil
local function request(conn, op, fields, on_reply)
  if conn.closed then
    return
  end
  next_req = next_req + 1
  local msg = vim.tbl_extend("force", fields or {}, { req = tostring(next_req), op = op })
  conn.pending[msg.req] = on_reply or false
  local ok = pcall(conn.pipe.write, conn.pipe, vim.json.encode(msg) .. "\n", function(err)
    if err then
      vim.schedule(function()
        stop(conn)
      end)
    end
  end)
  if not ok then
    stop(conn)
  end
end

---Repaint every surface that draws the queue, and write the queue.
local function repaint()
  if not view then
    return
  end
  view.paint()
  if config.overlay() then
    require("codereview.overlay").paint()
  end
  view.repaint_queue_float()
  view.persist()
end

---Make a snapshot of the queue owner the plugin's queue.
---
---A uuid not seen before gets the next integer id, in snapshot order: `queue.replace_every`
---numbers the entries that have no id in the order it is given them.
---
---An entry that is kept but not yet confirmed stays, also when the snapshot does not have
---it yet. Without this, a snapshot from another client that the queue owner wrote before
---it read the `keep` would remove the entry here and write that to disk.
---@param conn CRSyncConn
---@param rev integer|nil
---@param notes table[]|nil
local function apply(conn, rev, notes)
  if type(rev) == "number" then
    if rev < conn.rev then
      return
    end
    conn.rev = rev
  end

  local here = {}
  for _, entry in ipairs(queue.entries()) do
    local uuid = lower(entry.uuid)
    here[uuid] = entry
    ids[uuid] = entry.id
  end

  local items, seen = {}, {}
  for _, note in ipairs(notes or {}) do
    -- #284 handles the notes of other tools. Until then they are not in this queue.
    if type(note) == "table" and type(note.id) == "string" and own(note) then
      local entry = to_entry(note)
      entry.id = ids[entry.uuid]
      items[#items + 1] = entry
      seen[entry.uuid] = true
    end
  end

  local unconfirmed = {}
  for uuid, entry in pairs(here) do
    if not seen[uuid] and (not conn.confirmed or conn.inflight[uuid]) then
      unconfirmed[#unconfirmed + 1] = entry
    end
  end
  table.sort(unconfirmed, function(a, b)
    return a.id < b.id
  end)
  vim.list_extend(items, unconfirmed)

  queue.replace_every(items, state.checkout_of)
  for _, entry in ipairs(items) do
    ids[entry.uuid] = entry.id
  end
  repaint()
end

---The event path: one handler per event name.
---
---#285 adds `sent` here.
local EVENTS = {
  ---@param conn CRSyncConn
  ---@param msg table
  queue = function(conn, msg)
    apply(conn, msg.rev, msg.queue)
  end,
}

---@param conn CRSyncConn
---@param msg table
local function on_event(conn, msg)
  local handle = EVENTS[msg.event]
  if handle then
    handle(conn, msg)
  end
end

---@param conn CRSyncConn
---@param msg table
local function on_reply(conn, msg)
  local cb = conn.pending[msg.req]
  conn.pending[msg.req] = nil
  if cb then
    cb(msg)
  end
end

---One line from the queue owner. In the main loop, not in the read callback, because a
---handler repaints windows and writes files.
---@param conn CRSyncConn
---@param line string
local function receive(conn, line)
  if conn.closed then
    return
  end
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= "table" then
    return
  end
  if msg.event then
    on_event(conn, msg)
  elseif msg.req ~= nil then
    on_reply(conn, msg)
  end
end

---Read all the time: the queue owner closes a connection that does not read for 5 s.
---@param conn CRSyncConn
local function read(conn)
  conn.pipe:read_start(function(err, data)
    if err or not data then
      vim.schedule(function()
        stop(conn)
      end)
      return
    end
    conn.buffer = conn.buffer .. data
    while true do
      local nl = conn.buffer:find("\n", 1, true)
      if not nl then
        break
      end
      local line = conn.buffer:sub(1, nl - 1)
      conn.buffer = conn.buffer:sub(nl + 1)
      if line ~= "" then
        vim.schedule(function()
          receive(conn, line)
        end)
      end
    end
  end)
end

---The connect is complete: apply what the queue owner holds, and say so once.
---@param conn CRSyncConn
---@param hello table The reply to `hello`, which carries the queue as it was then
local function ready(conn, hello)
  conn.confirmed = true
  conn.ready = true
  -- The snapshot of the `hello` reply, unless an event with a higher `rev` came after it.
  apply(conn, hello.rev, hello.queue)
  info(("Queue sync started: %s"):format(config.get().sync.socket))
end

---The fixed order on connect.
---
---The restore first, because `keep` gives the queue owner every entry in the local queue,
---and a queue that this session has not read back is missing the entries the last
---session left. Then `hello`, `subscribe` and `keep`.
---
---Until the queue owner replies to that `keep`, a snapshot does not have the entries that
---only this plugin has, so `apply` keeps every local entry. The snapshot in the `hello`
---reply is applied last, and only when no event came after it.
---@param conn CRSyncConn
local function handshake(conn)
  read(conn)
  local staled = state.ensure_queue()
  if staled > 0 then
    info(queue.stale_phrase(staled))
  end
  request(conn, "hello", { protocol = PROTOCOL, client = CLIENT, types = host_types() }, function(hello)
    if not hello.ok then
      stop(conn)
      return
    end
    request(conn, "subscribe", nil, function(subscribed)
      if not subscribed.ok then
        stop(conn)
        return
      end
      -- Read at this moment, not before `hello`: an entry captured while the connect ran
      -- is in this `keep`, because `keeping` was false when it was captured.
      local notes = vim.tbl_map(to_note, queue.entries())
      conn.keeping = true
      if #notes == 0 then
        ready(conn, hello)
        return
      end
      request(conn, "keep", { notes = notes }, function(kept)
        if not kept.ok then
          warn(("Queue sync refused the queue: %s"):format(tostring(kept.error)))
          stop(conn)
          return
        end
        ready(conn, hello)
      end)
    end)
  end)
end

---Try to connect. A failure is silent: the plugin keeps its own queue.
local function connect()
  last_try = vim.uv.hrtime() / 1e6
  local pipe = vim.uv.new_pipe(false)
  ---@type CRSyncConn
  local conn = {
    pipe = pipe,
    pending = {},
    buffer = "",
    rev = -1,
    keeping = false,
    confirmed = false,
    inflight = {},
    ready = false,
    closed = false,
  }
  current = conn
  local ok = pcall(pipe.connect, pipe, config.get().sync.socket, function(err)
    vim.schedule(function()
      if conn.closed or current ~= conn then
        return
      end
      if err then
        stop(conn)
        return
      end
      handshake(conn)
    end)
  end)
  if not ok then
    stop(conn)
  end
end

--- The surface -----------------------------------------------------------------

---Start the sync, at setup. Closes a connection that an earlier setup made.
---@param review_view table The review view module
function M.start(review_view)
  view = review_view
  if current then
    stop(current)
  end
  last_try = nil
  connect()
end

---Try to connect again, if the sync is on, no connection is open, and the last attempt
---was 2 s ago or more. Called by each queue operation.
function M.wake()
  if not view or not config.get().sync or current then
    return
  end
  if last_try and vim.uv.hrtime() / 1e6 - last_try < RETRY_MS then
    return
  end
  connect()
end

---Give a new entry to the queue owner.
---
---Before the `keep` of the connect is written, nothing is sent: that `keep` reads the queue
---when it is written, so it has the entry. With no connection, this is a queue operation
---like any other, and it tries to connect.
---@param entry CRAnnotation An entry that is in the queue
function M.keep(entry)
  local conn = current
  if not conn then
    M.wake()
    return
  end
  if not conn.keeping then
    return
  end
  local uuid = lower(entry.uuid)
  conn.inflight[uuid] = true
  request(conn, "keep", { notes = { to_note(entry) } }, function()
    conn.inflight[uuid] = nil
  end)
end

return M
