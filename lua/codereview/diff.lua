---Unified-diff parser.
---
---Pure functions over text: no git, no buffers, no windows. `M.parse` turns `git diff`
---output into the structures every other module reads, which is what lets the whole
---pipeline be exercised headlessly.
local M = {}

---@class CRLine
---@field side "add"|"del"|"ctx"
---@field old integer|nil  Line number on the pre-image side
---@field new integer|nil  Line number on the post-image side
---@field text string      Content WITHOUT the leading +/-/space
---@field no_newline boolean|nil  Carried the "\ No newline at end of file" marker

---@class CRHunk
---@field header string     Verbatim "@@ -19,6 +19,8 @@ ..." line
---@field heading string    Section heading git appends after the second @@ (often a
---                        function signature); "" when absent
---@field old_start integer
---@field new_start integer
---@field lines CRLine[]

---@class CRFile
---@field path string             Post-image path (pre-image path for a deletion)
---@field old_path string|nil     Set only on a rename
---@field status "M"|"A"|"D"|"R"|"U"  U = untracked
---@field added integer
---@field removed integer
---@field binary boolean
---@field note string|nil         Why there are no hunks, when there are none
---@field blob string|nil         Filled in by the caller; the invalidation key
---@field hunks CRHunk[]

--- Path decoding ---------------------------------------------------------------

local ESCAPES = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v" }

---Undo git's C-style quoting of paths containing control characters or non-ASCII bytes.
---
---Only applied when the path is actually quoted -- git leaves ordinary paths bare, and
---unquoting one unconditionally would corrupt a filename that legitimately contains a
---backslash.
---@param path string
---@return string
local function unquote(path)
  if path:sub(1, 1) ~= '"' or path:sub(-1) ~= '"' then
    return path
  end
  local body = path:sub(2, -2)
  local out = body:gsub("\\(%d%d%d)", function(oct)
    return string.char(tonumber(oct, 8))
  end)
  out = out:gsub("\\(.)", function(ch)
    return ESCAPES[ch] or ch
  end)
  return out
end

---Strip the `a/` or `b/` prefix git puts on diff paths.
---
---`/dev/null` is returned as nil: it is git's way of saying "this side does not exist",
---which is how an addition and a deletion are distinguished.
---@param raw string
---@return string|nil
local function decode_path(raw)
  raw = unquote(vim.trim(raw))
  if raw == "/dev/null" then
    return nil
  end
  return (raw:gsub("^[ab]/", ""))
end

--- Parsing ---------------------------------------------------------------------

---@param text string "@@ -19,6 +19,8 @@ heading"
---@return CRHunk|nil, integer|nil old_count, integer|nil new_count
local function parse_hunk_header(text)
  local old_start, old_count, new_start, new_count, heading = text:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$")
  if not old_start then
    return nil
  end
  -- An omitted count means 1: `@@ -5 +5,3 @@` is a one-line pre-image, not a zero-line one.
  local oc = old_count == "" and 1 or tonumber(old_count)
  local nc = new_count == "" and 1 or tonumber(new_count)
  return {
    header = text,
    heading = heading or "",
    old_start = tonumber(old_start),
    new_start = tonumber(new_start),
    lines = {},
  },
    oc,
    nc
end

---@param file CRFile
local function finalize(file)
  for _, hunk in ipairs(file.hunks) do
    for _, ln in ipairs(hunk.lines) do
      if ln.side == "add" then
        file.added = file.added + 1
      elseif ln.side == "del" then
        file.removed = file.removed + 1
      end
    end
  end
  if #file.hunks == 0 and not file.note then
    if file.binary then
      file.note = "binary — not annotatable"
    elseif file.status == "R" then
      file.note = "renamed, no content change"
    else
      file.note = "no textual change (mode or metadata only)"
    end
  end
end

---@param path string
---@return CRFile
local function new_file(path)
  return {
    path = path,
    old_path = nil,
    status = "M",
    added = 0,
    removed = 0,
    binary = false,
    hunks = {},
  }
end

---Parse `git diff` output into a list of files.
---@param text string|nil
---@return CRFile[]
function M.parse(text)
  ---@type CRFile[]
  local files = {}
  if not text or text == "" then
    return files
  end

  local lines = vim.split(text, "\n", { plain = true })
  -- `git diff` output ends with a newline, so the split leaves one empty tail element.
  if lines[#lines] == "" then
    table.remove(lines)
  end

  ---@type CRFile|nil
  local file
  ---@type CRHunk|nil
  local hunk
  -- Remaining pre-/post-image lines the current hunk still owes us. Hunk bodies are
  -- consumed by these counters rather than by scanning for the next `@@` or `diff --git`,
  -- because a diff of a patch file contains those markers as ordinary content.
  local old_rem, new_rem = 0, 0
  local old_no, new_no = 0, 0

  local i = 1
  while i <= #lines do
    local ln = lines[i]

    -- The `\` clause matters for the LAST line of a hunk: both counters are already zero
    -- by the time its "\ No newline at end of file" marker arrives, so a counter-only
    -- condition drops it and the file silently gains a trailing newline it does not have.
    if hunk and (old_rem > 0 or new_rem > 0 or ln:sub(1, 1) == "\\") then
      local marker, body = ln:sub(1, 1), ln:sub(2)
      if marker == "\\" then
        -- "\ No newline at end of file" annotates the line above; it consumes no counter.
        local prev = hunk.lines[#hunk.lines]
        if prev then
          prev.no_newline = true
        end
      elseif marker == "+" then
        new_no = new_no + 1
        new_rem = new_rem - 1
        hunk.lines[#hunk.lines + 1] = { side = "add", old = nil, new = new_no, text = body }
      elseif marker == "-" then
        old_no = old_no + 1
        old_rem = old_rem - 1
        hunk.lines[#hunk.lines + 1] = { side = "del", old = old_no, new = nil, text = body }
      else
        -- A context line is " text"; a context line that is empty may arrive as "" if
        -- anything downstream stripped the trailing space.
        old_no, new_no = old_no + 1, new_no + 1
        old_rem, new_rem = old_rem - 1, new_rem - 1
        hunk.lines[#hunk.lines + 1] = { side = "ctx", old = old_no, new = new_no, text = marker == "" and "" or body }
      end
      i = i + 1
      goto continue
    end

    hunk = nil

    if ln:sub(1, 11) == "diff --git " then
      if file then
        finalize(file)
        files[#files + 1] = file
      end
      -- Paths are taken from the ---/+++ lines below; this header is only a reliable
      -- source when the path has no spaces, and it is always followed by better data.
      file = new_file("")
    elseif not file then
      -- Leading noise before the first header (e.g. a combined-diff preamble).
      i = i + 1
      goto continue
    elseif ln:sub(1, 18) == "deleted file mode " then
      file.status = "D"
    elseif ln:sub(1, 14) == "new file mode " then
      file.status = "A"
    elseif ln:sub(1, 12) == "rename from " then
      file.status = "R"
      file.old_path = unquote(vim.trim(ln:sub(13)))
    elseif ln:sub(1, 10) == "rename to " then
      file.path = unquote(vim.trim(ln:sub(11)))
    elseif ln:sub(1, 14) == "Binary files a" or ln:sub(1, 16) == "GIT binary patch" then
      file.binary = true
    elseif ln:sub(1, 4) == "--- " then
      local p = decode_path(ln:sub(5))
      if p and file.path == "" then
        file.path = p
      end
    elseif ln:sub(1, 4) == "+++ " then
      local p = decode_path(ln:sub(5))
      if p then
        file.path = p
      end
    elseif ln:sub(1, 3) == "@@ " then
      local parsed, oc, nc = parse_hunk_header(ln)
      if parsed then
        hunk = parsed
        old_rem, new_rem = oc, nc
        -- Counters are 1-indexed against the hunk's declared start, and the first body
        -- line is that start -- hence the -1 seed.
        old_no, new_no = parsed.old_start - 1, parsed.new_start - 1
        file.hunks[#file.hunks + 1] = hunk
      end
    end

    i = i + 1
    ::continue::
  end

  if file then
    finalize(file)
    files[#files + 1] = file
  end

  -- A rename with no content change never reaches a `+++` line, so fall back to the
  -- pre-image path rather than leaving an entry with no name at all.
  for _, f in ipairs(files) do
    if f.path == "" then
      f.path = f.old_path or "?"
    end
  end

  return files
end

--- Synthesis -------------------------------------------------------------------

---Build an all-added CRFile for an untracked path.
---
---Synthesised rather than obtained from `git diff --no-index`, which exits 1 when the
---files differ (the normal case here) and labels the pre-image `a/dev/null`. Constructing
---the entry directly avoids both quirks and lets us set `status = "U"` honestly.
---@param path string Relative to the repository root
---@param content string|nil Worktree content; nil when unreadable
---@return CRFile
function M.synthesize_added(path, content)
  local file = new_file(path)
  file.status = "U"

  if content == nil then
    file.note = "unreadable"
    return file
  end
  if content:sub(1, 8000):find("\0", 1, true) then
    file.binary = true
    file.note = "binary — not annotatable"
    return file
  end
  if content == "" then
    file.note = "empty file"
    return file
  end

  local body = vim.split(content, "\n", { plain = true })
  local trailing_newline = body[#body] == ""
  if trailing_newline then
    table.remove(body)
  end

  local hunk = {
    header = ("@@ -0,0 +1,%d @@"):format(#body),
    heading = "",
    old_start = 0,
    new_start = 1,
    lines = {},
  }
  for n, text in ipairs(body) do
    hunk.lines[n] = { side = "add", old = nil, new = n, text = text }
  end
  if not trailing_newline and hunk.lines[#hunk.lines] then
    hunk.lines[#hunk.lines].no_newline = true
  end

  file.hunks = { hunk }
  file.added = #body
  return file
end

--- Queries ---------------------------------------------------------------------

---Totals across a file list, for the view title.
---@param files CRFile[]
---@return integer added, integer removed
function M.totals(files)
  local added, removed = 0, 0
  for _, f in ipairs(files) do
    added, removed = added + f.added, removed + f.removed
  end
  return added, removed
end

return M
