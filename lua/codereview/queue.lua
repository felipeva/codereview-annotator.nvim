---The annotation queue.
---
---Annotate many places, submit once. Module-level rather than per-view because the queue
---is what you submit, not what you are looking at: changing scope or reopening the view
---must not scatter a review you have not sent yet.
local M = {}

---@class CRAnnotation
---@field id integer            Stable across repaints; what `x` removes by
---@field type string           Annotation type name, e.g. "bug"
---@field kind "line"|"range"|"hunk"|"file"
---@field path string           Repository-relative
---@field abs_path string
---@field blob string|nil       File content hash when captured; the staleness key
---@field worktree boolean|nil  `blob` is the working tree's hash rather than a ref's, so
---                             staleness judges it against the file on disk at any scope
---@field key string            Anchor key from render.line_key / render.file_key
---@field first integer|nil
---@field last integer|nil
---@field inline boolean        Render the code inline instead of as an `@ref`
---@field lines string[]|nil    Diff text, when inline
---@field tag string|nil        "deleted"|"change"|"added"|hunk type
---@field note string
---@field stale boolean|nil

---@type CRAnnotation[]
local items = {}
local next_id = 1

---@param item CRAnnotation
---@return CRAnnotation
function M.add(item)
  item.id = next_id
  next_id = next_id + 1
  items[#items + 1] = item
  return item
end

---@return CRAnnotation[]
function M.all()
  return items
end

---@return integer
function M.count()
  return #items
end

---@param id integer
---@return CRAnnotation|nil removed
function M.remove(id)
  for i, item in ipairs(items) do
    if item.id == id then
      return table.remove(items, i)
    end
  end
  return nil
end

function M.clear()
  items = {}
end

---Replace the whole queue, e.g. when restoring persisted state.
---@param list CRAnnotation[]
function M.replace(list)
  items = list or {}
  for _, item in ipairs(items) do
    next_id = math.max(next_id, (item.id or 0) + 1)
  end
end

---Reserve ids up to and including `highest`, for entries that are no longer in the queue.
---
---An archived entry has left the queue but not the screen: it is drawn against the diff
---beside the live ones, and dropping an annotation resolves by anchor key and then by id.
---The counter is module-level and does not survive a process, so a session that dispatched
---1..n and then restarted would hand its next annotation an id already on the diff --
---which `remove` would then match first.
---@param highest integer|nil
function M.seed(highest)
  next_id = math.max(next_id, (highest or 0) + 1)
end

---Annotations grouped by anchor key, for the renderer.
---@return table<string, CRAnnotation[]>
function M.by_key()
  local out = {}
  for _, item in ipairs(items) do
    local bucket = out[item.key]
    if not bucket then
      bucket = {}
      out[item.key] = bucket
    end
    bucket[#bucket + 1] = item
  end
  return out
end

---@param key string
---@return CRAnnotation[]
function M.at(key)
  return M.by_key()[key] or {}
end

---How a reviewer is told that annotations came back untrustworthy.
---
---One wording for every surface that reports staleness -- a reconcile against the diff on
---screen, a restore with nothing open, a capture that restored on its way past, and a
---submit that did. Which of them happened to notice is not something a reviewer should be
---able to hear, and four copies of a sentence is how that stops being true.
---@param n integer
---@return string
function M.stale_phrase(n)
  return ("%d annotation%s now stale"):format(n, n == 1 and "" or "s")
end

---@return integer
function M.stale_count()
  local n = 0
  for _, item in ipairs(items) do
    if item.stale then
      n = n + 1
    end
  end
  return n
end

return M
