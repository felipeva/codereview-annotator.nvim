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

---Write the view's progress and the current queue.
---@param view CRView
function M.persist(view)
  local data = { version = VERSION, scopes = {}, queue = queue.all() }
  for key, entry in pairs(view.per_scope) do
    -- `expanded` is deliberately not persisted: it is a transient way of peeking at a
    -- file, and restoring it would contradict the reviewed marks that drive collapse.
    if not vim.tbl_isempty(entry.reviewed) then
      data.scopes[key] = { reviewed = entry.reviewed }
    end
  end
  M.save(view.root, data)
end

---Write just the queue, leaving the rest of the document alone.
---
---For a capture made with no review view open. Such a capture has no `per_scope` to build
---a scopes table from, so writing a whole document the way `persist` does would blank the
---reviewed marks a review saved -- the queue would survive at the cost of the progress
---next to it.
---@param root string
function M.persist_queue(root)
  local data = M.load(root)
  data.queue = queue.all()
  M.save(root, data)
end

---Load the queue from disk when nothing has been captured in this session yet.
---
---Separate from `restore`, which needs a view and a scope to put reviewed marks back.
---The queue needs neither: it is what you submit, not what you are looking at.
---@param root string
---@return integer staled
function M.restore_queue(root)
  if queue.count() > 0 then
    return 0
  end
  local data = M.load(root)
  if data.queue and #data.queue > 0 then
    queue.replace(data.queue)
  end
  -- Judged as it comes back. This is the window staleness exists to cover: the file was
  -- free to change while nothing was watching it, and a restored note that still claims a
  -- line span is exactly the silent wrongness one queue was supposed to remove.
  return M.reconcile_queue(root)
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
