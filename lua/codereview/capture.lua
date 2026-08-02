---Capturing an annotation about the buffer you are in, with no review view involved.
---
---The review path resolves its target from a rendered diff and its anchor map. There is
---no diff here, so the target is resolved from the buffer itself -- but the entry it
---produces is the same shape, goes into the same queue and is rendered by the same code.
---A queued annotation must not remember which way it was captured.
local config = require("codereview.config")
local git = require("codereview.git")
local payload = require("codereview.payload")
local render = require("codereview.render")
local types = require("codereview.types")

local M = {}

---Anchor key for an annotation with no file behind it.
---
---Every other key is built from a path, and a path is never empty, so this cannot collide
---with one. Notes share it: nothing looks a note up by anchor -- the review view projects
---annotations onto diff lines, and a note has none -- but `queue.by_key` needs a key it
---can index, and nil is not one.
local NOTE_KEY = "note:0"

---@param msg string
local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "Code review" })
end

local SEVERITY = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
}

---Errors and warnings overlapping the captured lines, as text to append to the note.
---
---The point is to stop error messages being retyped into notes by hand. Hints and info
---are deliberately left out: they are rarely why you are annotating, and a wall of them
---buries the diagnostic that is.
---@param buf integer
---@param first integer|nil 1-based; nil means the whole buffer
---@param last integer|nil
---@return string|nil
local function diagnostics_note(buf, first, last)
  local hits = {}
  for _, d in ipairs(vim.diagnostic.get(buf, { severity = { min = vim.diagnostic.severity.WARN } })) do
    -- A diagnostic spanning several lines counts if any part of it is inside the capture.
    local from, to = d.lnum + 1, (d.end_lnum or d.lnum) + 1
    if not first or (from <= last and to >= first) then
      hits[#hits + 1] = d
    end
  end
  if #hits == 0 then
    return nil
  end

  -- By position, then severity: reading order, worst first where they collide.
  table.sort(hits, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return (a.severity or 0) < (b.severity or 0)
  end)

  local out = { "Diagnostics:" }
  for _, d in ipairs(hits) do
    -- Flattened to one line: a multi-line message would break the list apart.
    local message = vim.trim((d.message or ""):gsub("%s+", " "))
    out[#out + 1] = ("- %-5s L%d %s%s"):format(
      SEVERITY[d.severity] or "WARN",
      d.lnum + 1,
      message,
      d.source and (" (%s)"):format(d.source) or ""
    )
  end
  return table.concat(out, "\n")
end

---Rows of the live visual selection, or nothing in normal mode.
---
---`v` (selection anchor) and `.` (cursor) are read while visual mode is still live: the
---`'<`/`'>` marks are only rewritten when visual mode *exits*, so reading them from a
---mapping would return the previous selection instead of this one.
---@return integer|nil first, integer|nil last
local function selected_rows()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil, nil
  end
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  return math.min(a, b), math.max(a, b)
end

---Resolve a buffer into an annotation entry, minus its type and note.
---
---@param buf integer|nil Defaults to the current buffer
---@param range { first: integer, last: integer }|nil Explicit lines; otherwise the live
---       visual selection, and failing that the whole file
---@return CRAnnotation|nil entry, string|nil err
function M.target(buf, range)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf

  local name = vim.api.nvim_buf_get_name(buf)
  -- Nothing on disk to anchor to: a scratch buffer, or a fresh unnamed one. That is a real
  -- capture shape rather than an error -- a thought worth sending with no file behind it --
  -- and it gets its own kind, because every other kind presupposes a file and both the
  -- payload renderer and the queue float switch on kind.
  --
  -- A buffer that *has* a name which is not a file on disk still fails below. The review
  -- view's own buffer is one of those, and turning `aa` in a review into a bare note would
  -- be a worse answer than saying so.
  if name == "" then
    return { kind = "note", key = NOTE_KEY, inline = false }
  end

  -- Realpath rather than the buffer's name: `git rev-parse --show-toplevel` answers in
  -- resolved form, and on macOS a path under /var is a symlink into /private/var. Compare
  -- the two unresolved and the file looks like it lives outside its own repository.
  local abs = vim.uv.fs_realpath(name)
  if not abs then
    return nil, ("%s is not a file on disk"):format(vim.fn.fnamemodify(name, ":t"))
  end

  local root = git.root(vim.fs.dirname(abs))
  local rel = root and payload.relative_to(abs, root)

  local entry = {
    abs_path = abs,
    inline = false,
  }

  -- Outside any checkout there is no root to be relative to, nothing to hash against, and
  -- nowhere repository-shaped to persist. The entry keeps its absolute path and goes on
  -- exactly as any other; the absence of `path` is what later routes it to the store that
  -- is not tied to a repository.
  if rel then
    entry.path = rel
    -- Hashed at capture time, exactly as the review path hashes a diffed file. This is
    -- what buys staleness detection later; an entry without it can go quietly wrong.
    entry.blob = git.blob(rel, nil, root)
    -- Records *what* that blob is: the working tree, not a ref. A review annotation's blob
    -- can be an index or commit blob depending on the scope it was captured in, so this is
    -- what lets staleness judge each kind against the thing it was actually taken from.
    entry.worktree = true
  end

  -- Keys off whichever path it has. A repository-relative one where there is a repository,
  -- so it matches the review view's anchors; the absolute one otherwise.
  local anchor = rel or abs

  local first, last = range and range.first, range and range.last
  if not first then
    first, last = selected_rows()
  end
  if not first then
    entry.kind = "file"
    entry.key = render.file_key(anchor)
    entry.tag = "whole file"
    return entry
  end

  -- A range that runs past the end of the buffer describes lines that do not exist.
  local total = vim.api.nvim_buf_line_count(buf)
  first = math.max(1, math.min(first, total))
  last = math.max(first, math.min(last or first, total))

  entry.first = first
  entry.last = last
  -- One line is a `line`, more is a `range`, matching what the review path produces. The
  -- payload and the float both switch on kind, and a buffer capture must not present as a
  -- different sort of thing than the same selection made during a review.
  entry.kind = first == last and "line" or "range"
  entry.key = render.line_key(anchor, { new = first })
  -- Carried even though this normally travels as an `@ref`: a batch routed to an agent
  -- whose cwd does not contain the file cannot use a ref at all, and the fallback has to
  -- inline the exact lines rather than approximate them. Space-prefixed, so the block is
  -- valid diff context once the renderer fences it.
  entry.lines = vim.tbl_map(function(text)
    return " " .. text
  end, vim.api.nvim_buf_get_lines(buf, first - 1, last, false))
  return entry
end

---Annotate the current buffer: the visual selection if there is one, else the whole file.
---@param type_name string|nil Falls back to the same picker the review view offers
---@param range { first: integer, last: integer }|nil Explicit lines, e.g. a command range
function M.annotate(type_name, range)
  local cfg = config.get()

  local type_def = type_name and types.get(cfg.types, type_name)
  if type_name and not type_def then
    warn(("unknown annotation type: %s"):format(type_name))
    return
  end

  -- Resolved before the picker opens, not inside its callback: `vim.ui.select` is
  -- asynchronous, and the annotation is about the buffer the user was in when they asked
  -- -- not about wherever the cursor happens to be once a menu has come and gone.
  local buf = vim.api.nvim_get_current_buf()
  local entry, err = M.target(buf, range)
  if not entry then
    warn(err)
    return
  end

  -- The selection has already been read, so leave visual mode before anything else opens.
  -- The review path does the same: a composer entered with a selection still live is one
  -- the user cannot type into cleanly, and the picker below would inherit it too.
  if vim.fn.mode():match("[vV\22]") then
    vim.cmd("normal! \27")
  end

  -- Read now rather than in the callback: both the composer and the picker are
  -- asynchronous, and a language server can republish diagnostics while either is open.
  -- What rides along should be what was on screen when the note was started.
  local opts = { note_suffix = diagnostics_note(buf, entry.first, entry.last) }

  local annotate = require("codereview.annotate")
  if type_def then
    annotate.queue_entry(entry, type_def, opts)
    return
  end

  local labels = vim.tbl_map(function(t)
    return ("%s  %s"):format(t.icon, t.name)
  end, cfg.types)
  vim.ui.select(labels, { prompt = "Annotation type:" }, function(_, index)
    if not index then
      return
    end
    annotate.queue_entry(entry, cfg.types[index], opts)
  end)
end

return M
