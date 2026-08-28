---The annotation queue: one per **checkout**, and one for what belongs to no checkout.
---
---Annotate many places, submit once. Per checkout because a queue belongs to the checkout
---it is about -- annotate in one, then in another, and neither store may receive the
---other's **entries**. Not per view, which is a different question with a different answer:
---the queue is what you submit, not what you are looking at, so changing **scope** or
---reopening the review scatters nothing.
---
---Entries with no repository behind them belong to no checkout by definition, so they are
---kept in a list of their own and ride along in whichever checkout the reviewer is in.
---Confining them to "outside a checkout" would make them nearly unsendable, and a
---**dispatch** from any checkout therefore clears them for all.
---
---**One id counter, for every checkout at once.** An id has to be unique across the two
---stores and across every checkout in the process: `remove` resolves by id, dropping an
---annotation resolves by anchor key and then by id, and the archive rejoins the two halves
---of one **batch** by sorting on it. A counter per checkout would issue 1 in a fresh
---checkout while a loose entry restored as 1 rode along beside it. It is seeded per
---checkout instead, from that checkout's **archive**, as each is read back -- see `seed`.
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

---The key a checkout's queue is held under. Outside every checkout there is still a queue
---to add to -- a **bare note** can be written anywhere -- and nil is not a table key.
local NO_CHECKOUT = ""

---Each checkout's queue, keyed by the checkout.
---@type table<string, CRAnnotation[]>
local per_checkout = {}

---The entries that belong to no checkout, which every checkout shows.
---@type CRAnnotation[]
local loose = {}

---The checkout the queue is showing; nil outside every checkout.
---
---Moved by whatever has just resolved a checkout for its own reasons -- the restore, the
---read-back latch, a review opening -- rather than resolved here. Nothing in this module
---shells out, which is why the number a statusline asks for goes through `count_for`,
---taking a checkout from a caller that has already resolved it cheaply, rather than through
---`count` and this pointer: the pointer is right whenever something has just moved it, and
---a redraw is not one of those things.
---@type string|nil
local current = nil

local next_id = 1

---@param checkout string|nil
---@return CRAnnotation[]
local function list_for(checkout)
  local key = checkout or NO_CHECKOUT
  local list = per_checkout[key]
  if not list then
    list = {}
    per_checkout[key] = list
  end
  return list
end

---Show the queue of a checkout.
---
---Everything without a checkout of its own -- `all`, `count`, `add`, `remove` -- is about
---this one until it moves.
---@param checkout string|nil nil outside every checkout
function M.use(checkout)
  current = checkout
end

---@param item CRAnnotation
---@return CRAnnotation
function M.add(item)
  item.id = next_id
  next_id = next_id + 1
  -- Filed by what the entry is, not by where the reviewer is: an entry with no
  -- repository-relative path has no checkout to belong to, wherever it was written.
  local list = item.path and list_for(current) or loose
  list[#list + 1] = item
  return item
end

---The queue as it stands: this checkout's entries and the ones that belong to none.
---
---In id order, which is the order they were queued in. The two lists are one queue to
---everything above this module, and concatenating them would put every loose entry after
---every owned one however the reviewer wrote them -- the same rule, and the same reason,
---as the archive rejoining the halves of a split batch by id.
---@return CRAnnotation[]
function M.all()
  local out = {}
  vim.list_extend(out, list_for(current))
  vim.list_extend(out, loose)
  table.sort(out, function(a, b)
    return (a.id or 0) < (b.id or 0)
  end)
  return out
end

---The queue as a number: a checkout's entries and the ones that belong to none.
---
---The number a reviewer is shown, for any checkout. Counted rather than built and measured,
---because this is on the redraw path -- see `codereview.count`, which resolves the checkout
---and calls it.
---
---Both lists, never the owned half alone. They are one queue to everything above this
---module, and a reviewer holding a **bare note** with nothing else queued would otherwise
---read 0 with unsent work in hand.
---@param checkout string|nil nil outside every checkout
---@return integer
function M.count_for(checkout)
  return #list_for(checkout) + #loose
end

---The queue being shown, as a number.
---@return integer
function M.count()
  return M.count_for(current)
end

---How many entries a checkout holds, whichever one the queue is showing.
---
---What "this checkout has entries already, do not restore over them" is asked with. The
---whole queue's count cannot answer it: a reviewer with a bare note in hand would block
---every checkout they visited from ever reading its own store.
---
---Not the number to show anybody, for the mirror of that reason -- `count_for` is. The owned
---half alone reads 0 for the same reviewer, with the same note still unsent.
---@param checkout string|nil
---@return integer
function M.count_in(checkout)
  return #list_for(checkout)
end

---@return integer
function M.loose_count()
  return #loose
end

---@param id integer
---@return CRAnnotation|nil removed
function M.remove(id)
  for _, list in ipairs({ list_for(current), loose }) do
    for i, item in ipairs(list) do
      if item.id == id then
        return table.remove(list, i)
      end
    end
  end
  return nil
end

---Empty the queue that was just submitted: this checkout's, and the loose entries with it.
---
---Never another checkout's. A **dispatch** empties the queue that went out, and the whole
---of what leaving a checkout has to be is lossless.
function M.clear()
  per_checkout[current or NO_CHECKOUT] = {}
  loose = {}
end

---Replace one checkout's queue, e.g. when restoring persisted state.
---@param checkout string|nil
---@param list CRAnnotation[]
function M.replace(checkout, list)
  list = list or {}
  per_checkout[checkout or NO_CHECKOUT] = list
  for _, item in ipairs(list) do
    next_id = math.max(next_id, (item.id or 0) + 1)
  end
end

---Replace the entries that belong to no checkout.
---@param list CRAnnotation[]
function M.replace_loose(list)
  loose = list or {}
  for _, item in ipairs(loose) do
    next_id = math.max(next_id, (item.id or 0) + 1)
  end
end

---Reserve ids up to and including `highest`, for entries that are no longer in the queue.
---
---An archived entry has left the queue but not the screen: it is drawn against the diff
---beside the live ones, and dropping an annotation resolves by anchor key and then by id.
---The counter does not survive a process, so a session that dispatched 1..n and then
---restarted would hand its next annotation an id already on the diff -- which `remove`
---would then match first.
---
---Called once per checkout, as each is read back, with the highest id in *that* checkout's
---archive. The counter only ever rises, so a checkout visited later lifts it past its own
---archive without ever lowering it past another checkout's.
---@param highest integer|nil
function M.seed(highest)
  next_id = math.max(next_id, (highest or 0) + 1)
end

---Annotations grouped by anchor key, for the renderer.
---@return table<string, CRAnnotation[]>
function M.by_key()
  local out = {}
  for _, item in ipairs(M.all()) do
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

---How a reviewer is told that an annotation has nowhere to be saved.
---
---An entry is filed under the checkout it is *about*, so one written about a file in
---another checkout can be filed nowhere: not there, because a queue that is not being shown
---must not be written over, and not here, because it is not about here. It stays in the
---queue and it goes out with the batch; what it does not do is survive a restart, and an
---unsent annotation must never disappear without a word.
---
---Beside the staleness wording for the same reason that one is here: it is a sentence about
---an entry in the queue, and one sentence has to have one home.
---@param n integer
---@return string
function M.unfiled_phrase(n)
  return ("%d annotation%s about another checkout — kept here, and not saved until you are in it"):format(
    n,
    n == 1 and " is" or "s are"
  )
end

---@return integer
function M.stale_count()
  local n = 0
  for _, item in ipairs(M.all()) do
    if item.stale then
      n = n + 1
    end
  end
  return n
end

return M
