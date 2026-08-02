---The annotation queue.
---
---Annotate many places, submit once. Module-level rather than per-view because the queue
---is what you submit, not what you are looking at: switching scope or reopening the view
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

---Annotations bucketed by type, in the configured type order.
---
---Order comes from the type list rather than insertion order so the payload always leads
---with the most actionable group, whatever sequence you happened to write them in.
---@param types CRType[]
---@return { type: CRType, items: CRAnnotation[] }[]
function M.grouped(types)
  local out = {}
  for _, t in ipairs(types) do
    local bucket = {}
    for _, item in ipairs(items) do
      if item.type == t.name then
        bucket[#bucket + 1] = item
      end
    end
    if #bucket > 0 then
      out[#out + 1] = { type = t, items = bucket }
    end
  end
  return out
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
