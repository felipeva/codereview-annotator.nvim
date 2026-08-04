---Persisted review progress, and the blob-hash check that makes persisting safe.
---
---A review spans hours; losing reviewed marks and unsent annotations to a `:qa` is a real
---cost. The reason a queue is normally *not* worth persisting is that it describes a
---working-tree state a rebase can invalidate -- but that is an argument for detecting
---staleness, not for discarding the data. Every file records the blob it was reviewed or
---annotated against, and anything that no longer matches is corrected on load:
---
---  * a reviewed mark whose blob moved is silently un-marked -- the file changed, so you
---    have not reviewed what is there now;
---  * an annotation whose blob moved is kept but flagged stale, because the prose is
---    still worth sending and only its line anchor is untrustworthy.
---
---A third comparison lives here and is deliberately not a third case of that one:
---**touchedness** judges an *archived* entry against the working tree as it stood when its
---batch was **dispatched**, and answers where an agent has been rather than whether a note
---is still trustworthy. Same primitive, different blob, different entries, separate
---function -- see `reconcile_archive`.
local queue = require("codereview.queue")

local M = {}

---Bumping this discards every document written before the bump, so a key added to the
---shape is *not* a reason to touch it. `archive` was added by defaulting it on load
---exactly as `scopes` and `queue` already are: an older document simply lacks it, which
---costs an empty table, where a bump would cost every reviewed mark in the file.
local VERSION = 1

---A batch as it was dispatched, kept after the queue that held it was cleared.
---@class CRBatch
---@field at integer            When it went
---@field target string         Short name of where it went; "local" for the adapter's default
---@field snapshot string|nil   Commit object recording the working tree at that moment
---@field entries CRAnnotation[]

---How many dispatched batches a store keeps, oldest dropped on write.
---
---Public because it is a property of the store rather than a number this file happens to
---use. Bounded for the reason the global store sweeps on age: nothing else here will ever
---remove a batch, and a store nothing removes from grows for the life of the state
---directory.
M.ARCHIVE_LIMIT = 20

---How many times an archive has changed this session.
---
---What a projection of the archive onto a diff's anchors can be rebuilt from without a file
---read. That projection is handed to every repaint, and a repaint runs on every resize,
---expansion, reviewed toggle and scope change -- so decoding the document there would put
---the cost of the whole archive back onto the operation bounding extmark emission exists to
---keep cheap, and it would scale with what is stored rather than with what is drawn.
---
---Moved by everything that can change one: a dispatch, which is the only thing that writes
---an archive, and forgetting a store. Declared here rather than beside them because a Lua
---local is only in scope below itself, and one of those sits above the archive's own
---section. Not persisted and meaningless across processes -- what it answers is "has it
---changed since you last looked", which has no answer before you have looked, and a session
---reads the archive once anyway.
local archive_writes = 0

---@return integer
function M.archive_writes()
  return archive_writes
end

---@param root string
---@return string
function M.path(root)
  -- Basename for readability plus a hash of the full path, so two checkouts of the same
  -- repository do not share a progress file.
  local name = ("%s-%s"):format(vim.fn.fnamemodify(root, ":t"), vim.fn.sha256(root):sub(1, 10))
  return vim.fs.joinpath(vim.fn.stdpath("state"), "codereview", name .. ".json")
end

---@param root string
---@return table
function M.load(root)
  local file = M.path(root)
  if vim.fn.filereadable(file) == 0 then
    return { version = VERSION, scopes = {}, queue = {}, archive = {} }
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"), {
      luanil = { object = true, array = true },
    })
  end)
  if not ok or type(decoded) ~= "table" or decoded.version ~= VERSION then
    -- A corrupt or older file is discarded rather than migrated: the cost of losing
    -- review progress is far lower than the cost of restoring marks that mean something
    -- different than they did when written.
    return { version = VERSION, scopes = {}, queue = {}, archive = {} }
  end
  decoded.scopes = decoded.scopes or {}
  decoded.queue = decoded.queue or {}
  -- A document written before the archive existed lacks the key entirely, and defaulting
  -- it here is the whole of what it takes to read one: nothing about the marks stored
  -- beside it means anything different than it did.
  decoded.archive = decoded.archive or {}
  return decoded
end

---@param root string
---@param data table
---@return boolean ok
function M.save(root, data)
  local file = M.path(root)
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    return false
  end
  return pcall(vim.fn.writefile, { encoded }, file)
end

--- The store for annotations with no repository ---------------------------------

---How long an annotation with no repository behind it survives.
---
---Nothing else will ever remove one. The per-repository store is reconciled against a
---diff, which is the moment an entry can be judged obsolete; this store never is, so
---without a sweep it grows for the life of the editor's state directory. Matches the
---window the host config's draft store uses, for the same reason.
local GLOBAL_TTL_SECONDS = 7 * 24 * 60 * 60

---@return string
function M.global_path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "codereview", "no-repository.json")
end

---Split the queue by whether an entry belongs to a repository.
---
---Having a repository-relative path *is* the test: a capture outside a checkout and a bare
---thought both lack one, and both are exactly the entries with nowhere repository-shaped
---to live. No extra field to set, and nothing to keep in sync with reality.
---@param items CRAnnotation[]
---@return CRAnnotation[] owned, CRAnnotation[] loose
local function partition(items)
  local owned, loose = {}, {}
  for _, item in ipairs(items) do
    table.insert(item.path and owned or loose, item)
  end
  return owned, loose
end

---Whatever is still inside the window, by each record's own stamp.
---
---One rule for the queued annotations and the archived batches alike: both are stamped
---when written, and neither has anything else that could ever decide it is finished with.
---@param records table[]|nil
---@param now integer
---@return table[]
local function unswept(records, now)
  local fresh = {}
  for _, record in ipairs(records or {}) do
    if type(record) == "table" and (now - (record.at or 0)) < GLOBAL_TTL_SECONDS then
      fresh[#fresh + 1] = record
    end
  end
  return fresh
end

---The whole store, swept.
---
---Read as one document rather than one key at a time, because a write has to put the
---other key back: `save_global` used to encode the queue and nothing else, which with an
---archive beside it would delete a dispatched batch every time an annotation was queued.
---@return { queue: CRAnnotation[], archive: CRBatch[] }
local function read_global()
  local file = M.global_path()
  if vim.fn.filereadable(file) == 0 then
    return { queue = {}, archive = {} }
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"), {
      luanil = { object = true, array = true },
    })
  end)
  if not ok or type(decoded) ~= "table" or decoded.version ~= VERSION then
    return { queue = {}, archive = {} }
  end

  -- The sweep, on load rather than on a timer: this is the only moment the store is
  -- read, so it is the only moment anything is in a position to drop from it.
  local now = os.time()
  return { queue = unswept(decoded.queue, now), archive = unswept(decoded.archive, now) }
end

---@param doc { queue: CRAnnotation[], archive: CRBatch[] }
---@return boolean ok
local function write_global(doc)
  local file = M.global_path()
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local ok, encoded = pcall(vim.json.encode, { version = VERSION, queue = doc.queue, archive = doc.archive })
  if not ok then
    return false
  end
  return pcall(vim.fn.writefile, { encoded }, file)
end

---@return CRAnnotation[]
function M.load_global()
  return read_global().queue
end

---The batches dispatched with nothing repository-shaped in them, newest first.
---@return CRBatch[]
function M.global_archive()
  return read_global().archive
end

---@param items CRAnnotation[]
---@return boolean ok
function M.save_global(items)
  local now = os.time()
  for _, item in ipairs(items) do
    -- Stamped once and then left alone. Refreshing it on every write would restart the
    -- clock each time anything else was queued, and nothing would ever age out.
    item.at = item.at or now
  end

  local doc = read_global()
  doc.queue = items
  return write_global(doc)
end

---Forget every annotation with no repository behind it, queued or already dispatched.
function M.clear_global()
  local file = M.global_path()
  if vim.fn.filereadable(file) == 1 then
    vim.fn.delete(file)
  end
  archive_writes = archive_writes + 1
end

--- The archive ------------------------------------------------------------------

---Add a batch to an archive, dropping the oldest once it is full.
---
---Newest first, because every reader of an archive wants the newest: the scope that diffs
---against a snapshot only ever reads that one, and the rest is there to be read back.
---@param archive CRBatch[]
---@param batch CRBatch
local function push(archive, batch)
  table.insert(archive, 1, batch)
  -- A loop rather than one removal, so a store written when the bound was larger comes
  -- back down instead of staying over it forever.
  while #archive > M.ARCHIVE_LIMIT do
    table.remove(archive)
  end
end

---Record a batch that has just been dispatched.
---
---Called on a dispatch and on nothing else (ADR-0005). An adapter that refused, one that
---raised, and the register the shipped default copies to all leave the archive exactly as
---they leave the queue -- a payload sitting in a register is not something an agent
---received. An **immediate send** is a batch of one (ADR-0004) and arrives here as one,
---with no special case.
---
---Split across the two stores on the rule that already routes the queue: an entry with a
---repository-relative path belongs to that repository, and a bare note or a file outside a
---checkout belongs to the store that needs no root. A batch holding both is recorded in
---both, because that is where its entries live.
---@param items CRAnnotation[] The batch as it went
---@param target string Short name of where it went, as every piece of chrome names it. The
---       label rather than the target itself: a host's target may carry anything at all,
---       functions included, and one that will not JSON-encode would take the whole
---       document's write down with it.
---@param root string|nil nil outside a repository, where only the global store applies
function M.archive_batch(items, target, root)
  local owned, loose = partition(items)
  -- One stamp for the batch, taken once: the two stores are recording the same dispatch.
  local at = os.time()
  -- Once for the dispatch rather than once per store, and before the writes rather than
  -- after them: what this says is "an archive is not what you last read", and a partial
  -- write is already not what you last read.
  archive_writes = archive_writes + 1

  if #loose > 0 then
    local doc = read_global()
    -- No snapshot: these entries have no repository whose working tree could be recorded,
    -- and a snapshot of whichever checkout happened to be current would describe nothing
    -- they are about.
    push(doc.archive, { at = at, target = target, entries = loose })
    write_global(doc)
  end

  if not root or #owned == 0 then
    return
  end
  local data = M.load(root)
  push(data.archive, {
    at = at,
    target = target,
    -- Minted here rather than handed in. The snapshot is the working tree at the moment of
    -- dispatch, and it is only that if it is taken at that moment.
    snapshot = require("codereview.git").snapshot(root),
    entries = owned,
  })
  M.save(root, data)
end

---The batches already dispatched from a repository, newest first.
---
---Entries with nothing repository-shaped about them are in `global_archive` instead, for
---the same reason they queue there: there is no root to key a document against.
---@param root string|nil
---@return CRBatch[]
function M.archive(root)
  return root and M.load(root).archive or {}
end

---The batch a repository dispatched last, or nil when it has never dispatched one.
---
---One query rather than a `[1]` at each caller, and here rather than on either caller
---because both of them are already above this module. Two things ask it, and they ask it
---about the same dispatch: the `since-batch` scope, which diffs the working tree against
---that batch's **snapshot**, and the surface that lists that batch's **entries**. A
---reviewer reads one beside the other, so a disagreement about which batch is newest would
---put the response to one dispatch on screen with the annotations of another beside it,
---and nothing would say so. Two copies of `[1]` are what that drift looks like before it
---happens -- the same reason the payload renderer and the queue float group through one
---helper rather than two that agreed at the time.
---
---The repository's record only, which is what makes it the right answer for a caller that
---needs a snapshot: a snapshot can only ever belong to the half with a repository behind
---it. A batch that also held a **bare note** is recorded in the store that needs no root as
---well, and `archive.last` is what rejoins the two for a surface that has to list every
---entry.
---@param root string|nil
---@return CRBatch|nil
function M.last_batch(root)
  return M.archive(root)[1]
end

---The highest id any archived entry carries, across every archive given.
---
---Which is what the queue's counter has to resume past. See `queue.seed`.
---@param archives CRBatch[][]
---@return integer
local function highest_archived_id(archives)
  local highest = 0
  for _, archive in ipairs(archives) do
    for _, batch in ipairs(archive) do
      for _, entry in ipairs(batch.entries or {}) do
        highest = math.max(highest, entry.id or 0)
      end
    end
  end
  return highest
end

--- Writing and reading ----------------------------------------------------------

---Write the view's progress and the current queue.
---
---Merged over the stored document rather than rebuilt from the view. A view only knows the
---scopes it has itself opened -- `open` seeds `per_scope` with one key and `set_scope`
---adds one per scope cycled to -- so building the whole table from it wrote every other
---scope out of existence. Review a branch on Monday, open only `staged` on Tuesday, and
---Monday's reviewed marks were gone the first time anything touched the file.
---@param view CRView
function M.persist(view)
  local owned, loose = partition(queue.all())
  M.save_global(loose)

  local data = M.load(view.root)
  data.queue = owned
  data.scopes = data.scopes or {}
  for key, entry in pairs(view.per_scope) do
    -- `expanded` is deliberately not persisted: it is a transient way of peeking at a
    -- file, and restoring it would contradict the reviewed marks that drive collapse.
    --
    -- An emptied scope is written as absence rather than skipped. Skipping was harmless
    -- when the table was rebuilt every time; against a merge it would hand back the marks
    -- that were just un-marked. Only keys this view actually knows about are touched --
    -- one it has never opened is not evidence of anything.
    data.scopes[key] = not vim.tbl_isempty(entry.reviewed) and { reviewed = entry.reviewed } or nil
  end

  M.save(view.root, data)
end

---Write just the queue, leaving the rest of the document alone.
---
---For a capture made with no review view open. Such a capture has no `per_scope` to build
---a scopes table from, so writing a whole document the way `persist` does would blank the
---reviewed marks a review saved -- the queue would survive at the cost of the progress
---next to it.
---@param root string|nil nil when the working directory is not inside a repository, in
---       which case there is only the global store to write
function M.persist_queue(root)
  local owned, loose = partition(queue.all())
  M.save_global(loose)
  if not root then
    return
  end
  local data = M.load(root)
  data.queue = owned
  M.save(root, data)
end

---Load the queue from disk when nothing has been captured in this session yet.
---
---Separate from `restore`, which needs a view and a scope to put reviewed marks back.
---The queue needs neither: it is what you submit, not what you are looking at.
---@param root string|nil nil outside a repository, where only the global store applies
---@return integer staled
function M.restore_queue(root)
  if queue.count() > 0 then
    return 0
  end
  -- Both stores, as one queue. Which store an entry came from is a persistence detail; the
  -- queue is the queue.
  local loose = read_global()
  local data = root and M.load(root) or nil
  local items = data and data.queue or {}
  vim.list_extend(items, loose.queue)
  if #items > 0 then
    queue.replace(items)
  end
  -- Taken once both stores have been read, because an id is unique across the pair and the
  -- entries carrying one are split between them. Restoring the queue alone is not enough:
  -- a session that dispatched everything it queued restores nothing at all and still has
  -- ids on the diff to keep clear of.
  queue.seed(highest_archived_id({ data and data.archive or {}, loose.archive }))
  if not root then
    return 0
  end
  -- Judged as it comes back. This is the window staleness exists to cover: the file was
  -- free to change while nothing was watching it, and a restored note that still claims a
  -- line span is exactly the silent wrongness one queue was supposed to remove.
  return M.reconcile_queue(root)
end

---The repository the queue belongs to when no view is open.
---
---Public because more than the restore has to ask it: writing the queue with nothing open
---and emptying it after a submit both write to the store this names, and a second copy of
---the question is a second chance to answer it differently.
---@return string|nil
function M.ambient_root()
  return require("codereview.git").root(vim.fn.getcwd())
end

-- Restored lazily, and once. `count()` is the sort of thing a statusline calls on every
-- redraw, so reading the state file each time is not an option; and eagerly at startup is
-- worse, because the working directory that decides which repository's queue to load may
-- not be the one the user ends up in.
local queue_restored = false

---Load the persisted queue if this session has not seen it yet.
---
---Public because adding to the queue has to be able to demand it, not just reading it:
---`persist_queue` writes memory over the document, so anything that queues an annotation
---before the session has read the queue back would silently drop what the last session
---left. Capture makes that reachable as the very first thing a session does.
---
---Counted rather than announced, as reconciliation is: how many restored annotations are
---untrustworthy is a fact about the store, and the sentence a reviewer reads belongs to
---whichever surface asked.
---@return integer staled 0 once the queue has already been read back this session
function M.ensure_queue()
  if queue_restored then
    return 0
  end
  queue_restored = true
  -- No root is not a reason to skip: annotations with no repository behind them live in a
  -- store that does not need one, and they would otherwise never come back.
  return M.restore_queue(M.ambient_root())
end

---Restore saved progress into a freshly opened view.
---@param view CRView
---@param scope_key string
function M.restore(view, scope_key)
  local data = M.load(view.root)

  local saved = data.scopes and data.scopes[scope_key]
  if saved and saved.reviewed then
    for path, blob in pairs(saved.reviewed) do
      view.reviewed[path] = blob
      view.expanded[path] = false
    end
  end

  if data.queue and #data.queue > 0 and queue.count() == 0 then
    queue.replace(data.queue)
  end
end

---Judge working-tree annotations against the files on disk.
---
---These are the captures that have no scope behind them, so the diff-based rule never
---reaches them: it only judges what the current scope includes, which is correct for a
---review annotation and means a buffer annotation about an unrelated file would never be
---checked at all. Judged here at any scope, and with no view open.
---@param root string
---@return integer staled
function M.reconcile_queue(root)
  local git = require("codereview.git")

  local paths = {}
  for _, item in ipairs(queue.all()) do
    if item.worktree and item.path then
      paths[#paths + 1] = item.path
    end
  end
  if #paths == 0 then
    return 0
  end

  local hashes = git.hash_worktree(paths, root)
  local staled = 0
  for _, item in ipairs(queue.all()) do
    if item.worktree and item.path then
      -- A file that has been deleted hashes to nothing, which is at least as stale as one
      -- that merely changed: the lines the note names are gone either way.
      local moved = hashes[item.path] ~= (item.blob or "")
      item.stale = moved or nil
      if moved then
        staled = staled + 1
      end
    end
  end
  return staled
end

---Reconcile restored state against the diff that is actually on screen.
---
---Only files present in the current scope are judged: a file the scope does not include
---is not evidence that anything changed, and guessing from its absence would clear marks
---that are still correct.
---@param view CRView
---@return integer unmarked, integer staled
function M.reconcile(view)
  local by_path = {}
  for _, file in ipairs(view.files) do
    by_path[file.path] = file
  end

  local unmarked = 0
  for path, blob in pairs(vim.deepcopy(view.reviewed)) do
    local file = by_path[path]
    if file and (file.blob or "") ~= blob then
      view.reviewed[path] = nil
      view.expanded[path] = nil
      unmarked = unmarked + 1
    end
  end

  local staled = 0
  for _, item in ipairs(queue.all()) do
    -- A working-tree capture is judged below instead, against the file on disk. Judging it
    -- here as well would compare it against whichever blob this scope happens to show --
    -- the index, in a staged review -- and flag an annotation about a file nobody has
    -- touched since it was captured. Two rules that disagree, applied to one entry.
    local file = not item.worktree and by_path[item.path]
    if file then
      local moved = (file.blob or "") ~= (item.blob or "")
      item.stale = moved or nil
      if moved then
        staled = staled + 1
      end
    end
  end

  return unmarked, staled + M.reconcile_queue(view.root)
end

---Judge the newest archived batch's files against the code its batch went out with.
---
---**Touchedness is not staleness, and the two must never become one flag.** Sharing the
---blob comparison is the whole of what they share. Staleness judges a *queued* entry
---against the blob it was **captured** with and means *my note may be wrong*; this judges
---an *archived* entry against the working tree as it stood when its batch was
---**dispatched** and means *the agent has been here*. One flag would say both and neither:
---an entry captured on Monday, edited by the reviewer on Tuesday and dispatched on
---Wednesday is stale and untouched at once, and each read off the other is wrong in the
---direction that looks fine.
---
---**Judged against the snapshot, not against the entry's own blob.** That blob is the
---capture blob, so a file the reviewer themselves edited between annotating it and
---submitting would count as the agent's work -- and it would make this comparison
---arithmetically identical to the staleness one, which is how two rules become one by
---accident rather than by decision. The snapshot is what the archive already records the
---dispatch as, so there is no second copy of that fact to drift from it, and it is what
---`since-batch` diffs against: the tally and the diff a reviewer reads it beside therefore
---describe one dispatch by construction.
---
---**Per file, not per anchor.** Mapping an entry's line range through the diff since the
---snapshot is considerably more machinery and the case it improves stays fuzzy either way.
---The signal worth having is *the agent never opened this file*, and that one is exact
---under a per-file rule.
---
---Two batched calls, neither of which grows with the number of files -- `hash-object` for
---the working tree and `cat-file --batch-check` for the snapshot, exactly as the two sides
---of a diff are already hashed. One process per file was measurably more expensive than
---every treesitter operation combined.
---
---Three things are left unjudged rather than guessed at:
---  * a file the current scope does not cover, because absence from a scope is not evidence
---    that anything changed -- the rule `reconcile` already holds;
---  * a path the snapshot does not carry, which is a file untracked at dispatch: `git stash
---    create` records none of those, so the snapshot has nothing to say about it;
---  * a **bare note**, which is about no file at all. It lives in the store that needs no
---    root and never reaches this one.
---@param root string
---@param files CRFile[] The scope on screen, which is what decides who is judged
---@return table<integer, boolean> touched Keyed by entry id; an absent id was not judged
---@return integer|nil untouched How many judged entries' files have not moved, or nil when
---        nothing could be judged at all
function M.reconcile_archive(root, files)
  local batch = M.last_batch(root)
  if not batch or not batch.snapshot then
    return {}, nil
  end

  local in_scope = {}
  for _, file in ipairs(files) do
    in_scope[file.path] = true
  end

  -- Distinct paths: one batch routinely holds several entries about one file, and hashing
  -- a path once per entry is exactly the per-file cost the batching exists to avoid.
  local paths, seen = {}, {}
  for _, entry in ipairs(batch.entries or {}) do
    if entry.path and in_scope[entry.path] and not seen[entry.path] then
      seen[entry.path] = true
      paths[#paths + 1] = entry.path
    end
  end
  if #paths == 0 then
    return {}, nil
  end

  local git = require("codereview.git")
  local now = git.hash_worktree(paths, root)
  local specs = {}
  for i, path in ipairs(paths) do
    specs[i] = ("%s:%s"):format(batch.snapshot, path)
  end
  local sent = git.hash_refs(specs, root)

  local moved = {}
  for i, path in ipairs(paths) do
    local was = sent[specs[i]]
    if was then
      -- A file deleted since the dispatch hashes to nothing, and nothing is as moved as a
      -- rewrite: what the note was about is not there either way.
      moved[path] = now[path] ~= was
    end
  end

  local touched, untouched = {}, nil
  for _, entry in ipairs(batch.entries or {}) do
    if entry.id and entry.path and moved[entry.path] ~= nil then
      touched[entry.id] = moved[entry.path]
      untouched = (untouched or 0) + (moved[entry.path] and 0 or 1)
    end
  end
  return touched, untouched
end

---Forget everything saved for a repository.
---@param root string
function M.clear(root)
  local file = M.path(root)
  if vim.fn.filereadable(file) == 1 then
    vim.fn.delete(file)
  end
  -- The archive went with it, so anything holding a projection of it is holding entries
  -- that no longer exist -- and would go on drawing them until the next dispatch.
  archive_writes = archive_writes + 1
end

return M
