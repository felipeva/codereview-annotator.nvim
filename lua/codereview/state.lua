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
local queue = require("codereview.queue")

local M = {}

local VERSION = 1

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
    return { version = VERSION, scopes = {}, queue = {} }
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
    return { version = VERSION, scopes = {}, queue = {} }
  end
  decoded.scopes = decoded.scopes or {}
  decoded.queue = decoded.queue or {}
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

---@return CRAnnotation[]
function M.load_global()
  local file = M.global_path()
  if vim.fn.filereadable(file) == 0 then
    return {}
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"), {
      luanil = { object = true, array = true },
    })
  end)
  if not ok or type(decoded) ~= "table" or decoded.version ~= VERSION then
    return {}
  end

  -- The sweep, on load rather than on a timer: this is the only moment the store is
  -- read, so it is the only moment anything is in a position to drop from it.
  local now, fresh = os.time(), {}
  for _, item in ipairs(decoded.queue or {}) do
    if type(item) == "table" and (now - (item.at or 0)) < GLOBAL_TTL_SECONDS then
      fresh[#fresh + 1] = item
    end
  end
  return fresh
end

---@param items CRAnnotation[]
---@return boolean ok
function M.save_global(items)
  local file = M.global_path()
  vim.fn.mkdir(vim.fs.dirname(file), "p")

  local now = os.time()
  for _, item in ipairs(items) do
    -- Stamped once and then left alone. Refreshing it on every write would restart the
    -- clock each time anything else was queued, and nothing would ever age out.
    item.at = item.at or now
  end

  local ok, encoded = pcall(vim.json.encode, { version = VERSION, queue = items })
  if not ok then
    return false
  end
  return pcall(vim.fn.writefile, { encoded }, file)
end

---Forget every annotation with no repository behind it.
function M.clear_global()
  local file = M.global_path()
  if vim.fn.filereadable(file) == 1 then
    vim.fn.delete(file)
  end
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
  local items = root and M.load(root).queue or {}
  vim.list_extend(items, M.load_global())
  if #items > 0 then
    queue.replace(items)
  end
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

---Forget everything saved for a repository.
---@param root string
function M.clear(root)
  local file = M.path(root)
  if vim.fn.filereadable(file) == 1 then
    vim.fn.delete(file)
  end
end

return M
