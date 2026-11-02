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

---How long a request waits for its reply, in milliseconds. After that it counts as
---refused. The queue owner answers `hello`, `subscribe`, `list` and `keep` at once, and it
---closes a client that does not read for 5 s, so a reply later than that is not coming.
local REPLY_MS = 5000

---The most bytes of notes in one `keep`. The queue owner closes a connection whose line is
---longer than 8 MiB. A typical entry is a few KiB, so 1 MiB holds hundreds of them in one
---request, and the line stays far below the limit whatever the envelope adds.
local BATCH_BYTES = 1024 * 1024

---The most bytes of one note. Larger, it would close the connection at each retry, so it is
---not sent at all and counts as refused. Half the queue owner's limit, so the note can also
---go in an `update` with room to spare.
local NOTE_BYTES = 4 * 1024 * 1024

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
---@field confirmed boolean The queue owner has replied to every `keep` of the connect
---@field inflight table<string, true> Uuids kept and not yet confirmed by a reply
---@field updating table<string, integer> Uuids with an `update` that has no reply yet, and how many
---@field removing table<string, true> Uuids with a `remove` that has no reply yet
---@field notes table[]|nil The notes of the last snapshot applied
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

---The uuids, in lower case, of the entries whose `keep` was refused, with the reason.
---
---A refused entry stays in the local queue and on disk: no snapshot drops it, because the
---queue owner does not have it. The next connect sends it again with every other entry,
---and an accepted `keep` takes it off this list.
---@type table<string, string>
local refused = {}

---The reasons for a refusal that the reviewer was told this session, so a retry that is
---refused for the same reason says nothing again.
---@type table<string, true>
local told = {}

---The uuids, in lower case, of the entries with a change that the queue owner does not
---have: an edit or a **stale** mark made with no connection, or one that it refused or did
---not answer.
---
---In a snapshot, the local entry wins over the note of the queue owner, so the change
---stays on screen and on disk. The next connect sends the change with `update`, after its
---`keep`, and the reply takes the entry off this list.
---@type table<string, true>
local unsent = {}

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

---The `review` of a note. Whole each time: an `update` replaces it, and `kind` is required.
---@param entry CRAnnotation
---@return table
local function review_of(entry)
  return {
    kind = entry.kind,
    inline = entry.inline == true,
    tag = entry.tag,
    stale = entry.stale == true,
    lines = entry.lines,
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
    review = review_of(entry),
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

---The bytes that stand for a byte that is not UTF-8: U+FFFD, the replacement character.
local REPLACEMENT = "\239\191\189"

---Make a line valid UTF-8.
---
---Text comes from buffers, and `vim.json.encode` writes its bytes as they are. The queue
---owner cannot parse a line that is not UTF-8, and it then replies with no `req`, so no
---callback would ever run. Each byte that does not start a valid sequence (RFC 3629: no
---overlong form, no surrogate, nothing above U+10FFFF) becomes U+FFFD. JSON's own syntax is
---ASCII, so only the text inside strings can change.
---@param line string
---@return string
local function scrub(line)
  if not line:find("[\128-\255]") then
    return line
  end
  local out, start, i, n = {}, 1, 1, #line
  while i <= n do
    local c = line:byte(i)
    local len = c < 0x80 and 1
      or (c >= 0xC2 and c <= 0xDF) and 2
      or (c >= 0xE0 and c <= 0xEF) and 3
      or (c >= 0xF0 and c <= 0xF4) and 4
      or 0
    local ok = len > 0 and i + len - 1 <= n
    for k = 1, ok and len - 1 or 0 do
      local b = line:byte(i + k)
      if b < 0x80 or b > 0xBF then
        ok = false
        break
      end
    end
    if ok and len > 2 then
      local b = line:byte(i + 1)
      ok = not (
        (c == 0xE0 and b < 0xA0)
        or (c == 0xED and b > 0x9F)
        or (c == 0xF0 and b < 0x90)
        or (c == 0xF4 and b > 0x8F)
      )
    end
    if ok then
      i = i + len
    else
      out[#out + 1] = line:sub(start, i - 1)
      out[#out + 1] = REPLACEMENT
      i = i + 1
      start = i
    end
  end
  out[#out + 1] = line:sub(start)
  return table.concat(out)
end

---The request path: write one request, and keep its callback under its `req`.
---
---A reply that does not come in `REPLY_MS` is answered here with `ok = false`, so no
---callback waits for ever.
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
  local req = msg.req
  conn.pending[req] = on_reply or false
  local ok = pcall(conn.pipe.write, conn.pipe, scrub(vim.json.encode(msg)) .. "\n", function(err)
    if err then
      vim.schedule(function()
        stop(conn)
      end)
    end
  end)
  if not ok then
    stop(conn)
    return
  end
  vim.defer_fn(function()
    local cb = conn.pending[req]
    if conn.closed or cb == nil then
      return
    end
    conn.pending[req] = nil
    if cb then
      cb({ ok = false, error = "no reply", req = req })
    end
  end, REPLY_MS)
end

---Write the queue, then repaint every surface that draws it.
---
---The write first, so that an error in a paint cannot keep the snapshot off the disk.
local function repaint()
  if not view then
    return
  end
  view.persist()
  view.paint()
  if config.overlay() then
    require("codereview.overlay").paint()
  end
  view.repaint_queue_float()
end

---Make a snapshot of the queue owner the plugin's queue.
---
---A uuid not seen before gets the next integer id, in snapshot order: `queue.replace_every`
---numbers the entries that have no id in the order it is given them.
---
---An entry that is kept but not yet confirmed stays, also when the snapshot does not have
---it yet. Without this, a snapshot from another client that the queue owner wrote before
---it read the `keep` would remove the entry here and write that to disk. An entry whose
---`keep` was refused stays for the same reason: the queue owner does not have it.
---
---The same guard for an `update` and a `remove` that have no reply yet: a snapshot that the
---queue owner wrote before it read them does not undo them. While an `update` waits, the
---local entry stays as it is, also when the snapshot does not hold it. While a `remove`
---waits, the entry does not come back. An entry on `unsent` keeps its local change too.
---@param conn CRSyncConn
---@param rev integer|nil nil applies `notes` again, after a request that changed nothing
---@param notes table[]|nil
local function apply(conn, rev, notes)
  if type(rev) == "number" then
    if rev < conn.rev then
      return
    end
    conn.rev = rev
  end
  conn.notes = notes

  local here = {}
  for _, entry in ipairs(queue.entries()) do
    local uuid = lower(entry.uuid)
    here[uuid] = entry
    ids[uuid] = entry.id
  end

  local items, seen = {}, {}
  for _, note in ipairs(notes or {}) do
    -- #284 handles the notes of other tools. Until then they are not in this queue.
    local uuid = type(note) == "table" and type(note.id) == "string" and lower(note.id)
    if uuid and own(note) and not conn.removing[uuid] then
      local entry = here[uuid]
      if not (entry and (conn.updating[uuid] or unsent[uuid])) then
        entry = to_entry(note)
        entry.id = ids[uuid]
      end
      items[#items + 1] = entry
      seen[uuid] = true
    end
  end

  local unconfirmed = {}
  for uuid, entry in pairs(here) do
    local waits = conn.inflight[uuid] or refused[uuid] or conn.updating[uuid]
    if not seen[uuid] and (not conn.confirmed or waits) then
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

---Give entries to the queue owner, in `keep` requests of at most `BATCH_BYTES`, one after
---the other, and call `done` when every reply came.
---
---A refused request is sent again one entry at a time, because the queue owner refuses a
---whole `keep` when one note in it is bad: one bad entry must not keep the others out. An
---entry refused on its own, or a request with no reply, goes on `refused`. The reviewer is
---told once per reason in a session.
---@param conn CRSyncConn
---@param entries CRAnnotation[]
---@param done fun()|nil
local function keep_entries(conn, entries, done)
  local work, batch, size = {}, {}, 0
  local failed = {}
  for _, entry in ipairs(entries) do
    -- Measured as written: a byte that `scrub` replaces takes three.
    local bytes = #scrub(vim.json.encode(to_note(entry)))
    if bytes > NOTE_BYTES then
      failed[#failed + 1] = { entry = entry, error = ("larger than %d bytes"):format(NOTE_BYTES) }
    else
      if #batch > 0 and size + bytes > BATCH_BYTES then
        work[#work + 1] = batch
        batch, size = {}, 0
      end
      batch[#batch + 1] = entry
      size = size + bytes
    end
  end
  if #batch > 0 then
    work[#work + 1] = batch
  end

  local function finish()
    local by_reason = {}
    for _, f in ipairs(failed) do
      refused[lower(f.entry.uuid)] = f.error
      by_reason[f.error] = (by_reason[f.error] or 0) + 1
    end
    for reason, n in pairs(by_reason) do
      if not told[reason] then
        told[reason] = true
        warn(
          ("Queue sync: the queue owner did not take %d annotation%s (%s). %s in Neovim."):format(
            n,
            n == 1 and "" or "s",
            reason,
            n == 1 and "It stays" or "They stay"
          )
        )
      end
    end
    if done then
      done()
    end
  end

  local function step()
    local next_batch = table.remove(work, 1)
    if not next_batch or conn.closed then
      finish()
      return
    end
    for _, entry in ipairs(next_batch) do
      conn.inflight[lower(entry.uuid)] = true
    end
    request(conn, "keep", { notes = vim.tbl_map(to_note, next_batch) }, function(reply)
      for _, entry in ipairs(next_batch) do
        conn.inflight[lower(entry.uuid)] = nil
      end
      if reply.ok then
        for _, entry in ipairs(next_batch) do
          refused[lower(entry.uuid)] = nil
        end
      elseif #next_batch > 1 and reply.error ~= "no reply" then
        for i = #next_batch, 1, -1 do
          table.insert(work, 1, { next_batch[i] })
        end
      else
        for _, entry in ipairs(next_batch) do
          failed[#failed + 1] = { entry = entry, error = tostring(reply.error) }
        end
      end
      step()
    end)
  end
  step()
end

---Apply the last snapshot again, after a request that did not change the queue owner's
---queue: the guards of that request are gone, so the snapshot now wins.
---@param conn CRSyncConn
local function reapply(conn)
  if conn.notes then
    apply(conn, nil, conn.notes)
  end
end

---Warn once per session for each kind of refusal.
---@param key string The op and the reason
---@param msg string
local function warn_once(key, msg)
  if not told[key] then
    told[key] = true
    warn(msg)
  end
end

---@param uuid string In lower case
---@return CRAnnotation|nil
local function local_entry(uuid)
  for _, entry in ipairs(queue.entries()) do
    if lower(entry.uuid) == uuid then
      return entry
    end
  end
end

---Send a change of one entry with `update`.
---
---Before the `keep` of the connect is written, or with no connection, nothing is sent, and
---the entry goes on `unsent`. An entry whose `keep` was refused is not sent either: the
---queue owner does not hold it, and the next connect keeps it with the change.
---
---A reply of "unknown id" means that the queue owner does not hold the entry: another tool
---dropped it, or sent it, before the `update` arrived. With `revive`, a change that the
---reviewer made now, the entry goes back to the queue owner with `keep`, so the note that
---the reviewer typed is not lost. Without it, the last snapshot is applied again, and the
---entry leaves. Any other refusal, and no reply, puts the entry on `unsent`, said once.
---@param conn CRSyncConn|nil
---@param entry CRAnnotation An entry that is in the queue
---@param fields table The fields of the note that changed
---@param revive boolean
local function send_update(conn, entry, fields, revive)
  local uuid = lower(entry.uuid)
  if not conn or not conn.keeping then
    unsent[uuid] = true
    return
  end
  if refused[uuid] then
    return
  end
  unsent[uuid] = nil
  conn.updating[uuid] = (conn.updating[uuid] or 0) + 1
  request(conn, "update", vim.tbl_extend("force", { id = entry.uuid }, fields), function(reply)
    local n = conn.updating[uuid] - 1
    conn.updating[uuid] = n > 0 and n or nil
    if reply.ok then
      return
    end
    if reply.error == "unknown id" then
      local now = local_entry(uuid)
      if revive and now then
        keep_entries(conn, { now })
      else
        reapply(conn)
      end
      return
    end
    unsent[uuid] = true
    warn_once(
      "update: " .. tostring(reply.error),
      ("Queue sync: the queue owner did not take an edit (%s). It stays in Neovim, and the next connect sends it again."):format(
        tostring(reply.error)
      )
    )
  end)
end

---Every change on `unsent`, in full, for the entries that are still in the queue.
---@param conn CRSyncConn
local function send_unsent(conn)
  for _, entry in ipairs(queue.entries()) do
    if unsent[lower(entry.uuid)] then
      send_update(conn, entry, { note = entry.note or "", type = entry.type or "", review = review_of(entry) }, false)
    end
  end
end

---The connect is complete: apply what the queue owner holds, and say so once.
---@param conn CRSyncConn
---@param listed table The reply to `list`, which carries the queue as it was then
local function ready(conn, listed)
  conn.confirmed = true
  conn.ready = true
  -- The snapshot of the `list` reply, unless an event with a higher `rev` came after it.
  apply(conn, listed.rev, listed.queue)
  info(("Queue sync started: %s"):format(config.get().sync.socket))
end

---The fixed order on connect.
---
---The restore first, because `keep` gives the queue owner every entry in the local queue,
---and a queue that this session has not read back is missing the entries the last
---session left. Then `hello`, `subscribe`, `list` and `keep`.
---
---`list` after `subscribe`, not the snapshot in the `hello` reply: a change that another
---client makes between `hello` and `subscribe` goes only to subscribers, so this client
---would never see it. After `subscribe`, every change comes as an event with a higher `rev`.
---
---Until the queue owner has replied to every `keep`, a snapshot does not have the entries
---that only this plugin has, so `apply` keeps every local entry. The snapshot of `list` is
---applied last, and only when no event came after it.
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
      request(conn, "list", nil, function(listed)
        if not listed.ok then
          stop(conn)
          return
        end
        -- Read at this moment, not before `hello`: an entry captured while the connect ran
        -- is in this `keep`, because `keeping` was false when it was captured.
        local entries = queue.entries()
        conn.keeping = true
        keep_entries(conn, entries, function()
          if not conn.closed then
            send_unsent(conn)
            ready(conn, listed)
          end
        end)
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
    updating = {},
    removing = {},
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
  state.restaled = M.restale
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
  keep_entries(conn, { entry })
end

---Give the change of an entry's note or type to the queue owner.
---
---With no connection, this is a queue operation like any other, and it tries to connect.
---@param entry CRAnnotation The entry as it is now in the queue
---@param fields { note?: string, type?: string } The fields that changed. The protocol has no
---       untyped note, so an **untyped annotation** goes as the type `""`.
function M.update(entry, fields)
  if not current then
    M.wake()
  end
  send_update(current, entry, fields, true)
end

---Give the **stale** mark of entries to the queue owner, after a reconcile changed it, so
---that it can say that the line numbers may be stale.
---
---Not a queue operation, so it does not try to connect: the overlay reconciles on each
---paint.
---@param entries CRAnnotation[]
function M.restale(entries)
  for _, entry in ipairs(entries) do
    send_update(current, entry, { review = review_of(entry) }, false)
  end
end

---Take an entry out of the queue of the queue owner.
---
---Before the `keep` of the connect is written, or with no connection, nothing is sent.
---
---A refusal, and no reply, apply the last snapshot again: the entry comes back if the queue
---owner still holds it, so the screen shows what goes in the next submit. Said once.
---@param entry CRAnnotation The entry that left the queue
function M.remove(entry)
  local conn = current
  if not conn then
    M.wake()
    return
  end
  if not conn.keeping then
    return
  end
  local uuid = lower(entry.uuid)
  conn.removing[uuid] = true
  request(conn, "remove", { ids = { entry.uuid } }, function(reply)
    conn.removing[uuid] = nil
    if reply.ok then
      return
    end
    warn_once(
      "remove: " .. tostring(reply.error),
      ("Queue sync: the queue owner did not drop an annotation (%s). It is back in the queue."):format(
        tostring(reply.error)
      )
    )
    reapply(conn)
  end)
end

return M
