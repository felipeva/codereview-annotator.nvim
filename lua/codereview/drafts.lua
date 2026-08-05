---Notes abandoned half-written, kept until you come back for them.
---
---Its own store rather than a corner of the review document, because a draft is not review
---progress: that document is rewritten every time the queue changes, and a draft has
---nothing to do with the queue. It is also the one thing here that has to survive a file
---leaving the repository entirely, so it is keyed by absolute path and lives in one place
---regardless of which checkout the note was written in.
local M = {}

local VERSION = 1

---Matches the sweep on the no-repository queue, and for the same reason: this is a store
---nothing else prunes, so it has to age out on its own or it grows forever.
local TTL_SECONDS = 7 * 24 * 60 * 60

---@return string
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "codereview", "drafts.json")
end

---Every draft, minus the ones that have aged out.
---
---Swept on load rather than on a timer: this is the only moment the store is read, so it is
---the only moment anything is in a position to drop from it.
---@return table<string, { text: string, at: integer }>
local function load()
  local file = M.path()
  if vim.fn.filereadable(file) == 0 then
    return {}
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"), {
      luanil = { object = true, array = true },
    })
  end)
  -- A corrupt or older store is no drafts at all. Erroring here would happen on the way
  -- *into* the composer, which would cost you the note you were about to write to save one
  -- you had already abandoned.
  if not ok or type(decoded) ~= "table" or decoded.version ~= VERSION then
    return {}
  end

  local now, fresh = os.time(), {}
  for key, entry in pairs(decoded.drafts or {}) do
    if type(entry) == "table" and type(entry.text) == "string" and (now - (entry.at or 0)) < TTL_SECONDS then
      fresh[key] = entry
    end
  end
  return fresh
end

---@param drafts table
local function save(drafts)
  local file = M.path()
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local ok, encoded = pcall(vim.json.encode, { version = VERSION, drafts = drafts })
  if not ok then
    return
  end
  pcall(vim.fn.writefile, { encoded }, file)
end

---The key a note about `ctx` is filed under.
---
---The absolute path, so a review annotation and a capture of the same file meet the same
---draft -- they are the same thought about the same code, and both paths already carry a
---canonical absolute path. A bare note has no file at all, and every bare note shares the
---one slot there is.
---
---A **preamble** has no file either, and keying it by one would file prose about a batch
---under whichever file the reviewer happened to be looking at. It is keyed by the repository
---the batch is going out of, and by one fixed key outside a checkout -- the same split the
---**queue**'s two stores already make, and the same reason: what has no repository behind it
---has to share one slot. That leaves one preamble draft per repository, which is what a
---reviewer coming back to a batch they were writing for expects.
---
---Prefixed, so neither preamble key can collide with an absolute path or with the bare
---note's slot. Nothing else in this store carries a prefix, because nothing else needs one.
---@param ctx table
---@return string
function M.key(ctx)
  if ctx.preamble then
    return ("preamble:%s"):format(ctx.root or "(no repository)")
  end
  return ctx.file_path or "(no file)"
end

---@param key string
---@return string|nil
function M.get(key)
  local entry = load()[key]
  return entry and entry.text or nil
end

---@param key string
---@param text string|nil nil forgets the draft
function M.set(key, text)
  local drafts = load()
  if text and vim.trim(text) ~= "" then
    -- Stamped fresh on every write, unlike the queue's sweep: a draft you came back to and
    -- put down again is a draft you are still thinking about.
    drafts[key] = { text = text, at = os.time() }
  else
    drafts[key] = nil
  end
  save(drafts)
end

---Forget every draft.
function M.clear()
  local file = M.path()
  if vim.fn.filereadable(file) == 1 then
    vim.fn.delete(file)
  end
end

return M
