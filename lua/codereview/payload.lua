---Rendering the queue as the message an agent receives.
---
---References are resolved at submit time, not at capture time, because the same queue can
---be sent to an agent whose working directory differs from this Neovim's -- an `@ref` only
---resolves relative to whoever reads it.
local M = {}

---Canonical form of a directory refs will be resolved against.
---
---Every `abs_path` in the queue is already canonical: the review path joins `V.root`,
---which is `git rev-parse --show-toplevel` and answers with symlinks resolved, and capture
---realpaths the buffer name for the same reason. A delivery target's `cwd` is whatever the
---adapter reported and went through neither. On macOS a directory reached through /var is
---a symlink into /private/var, so comparing the two unresolved makes every file look like
---it lives outside the target's own tree -- and every `@ref` in the batch degrades to an
---absolute path with the code pasted after it. Silently, and in the direction that looks
---fine: nothing errors, the reader just stops getting refs they can open.
---
---Resolved here rather than inside `relative_to`, which stays a pure string predicate: one
---syscall per submit instead of one per entry, and the comparison stays testable.
---@param base string
---@return string
function M.resolve_base(base)
  if not base or base == "" then
    return base
  end
  -- Falls back to the input. A routed agent can report a working directory that does not
  -- exist on this machine at all, and a path that cannot be resolved is still worth
  -- prefix-matching -- dropping it would break remote targets to fix local symlinks.
  return vim.uv.fs_realpath(base) or base
end

---Path relative to `base`, or nil when it is not underneath it.
---@param path string
---@param base string
---@return string|nil
function M.relative_to(path, base)
  if not path or not base or base == "" then
    return nil
  end
  base = base:gsub("/$", "")
  if path == base then
    return "."
  end
  local prefix = base .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return nil
end

---An `@ref`: the one syntax this plugin speaks for "look at this code".
---
---Here rather than at either call site because there are two of them now -- the payload
---renders an annotation's own location, and the composer splices a reference to somewhere
---else -- and a note that says `@path#L12-12` where the payload says `@path#L12` is a
---composer authoring a dialect of its reader's language.
---@param rel string Path, relative to whoever will resolve it
---@param first integer|nil Omit both for a reference to the whole file
---@param last integer|nil
---@return string
function M.ref(rel, first, last)
  if not first then
    return ("@%s"):format(rel)
  end
  last = last or first
  local suffix = first == last and ("#L%d"):format(first) or ("#L%d-%d"):format(first, last)
  return ("@%s%s"):format(rel, suffix)
end

---@param entry CRAnnotation
---@return string
local function range_text(entry)
  if not entry.first then
    return ""
  end
  if entry.first == entry.last then
    return tostring(entry.first)
  end
  return ("%d-%d"):format(entry.first, entry.last)
end

---Heading and optional code block for one entry.
---
---The heading carries the location, and when the entry is reachable by an `@ref` the
---heading *is* that ref: emitting `path:20` and `@path#L20` on consecutive lines states
---the same fact twice, which is noise repeated in every entry of a long batch.
---@param entry CRAnnotation
---@param base string
---@return string heading, string[]|nil block
local function describe(entry, base)
  -- A thought with no file behind it. There is no location to resolve, so there is nothing
  -- for the `@ref`-versus-inline rules below to decide -- and every one of them would be
  -- reading a path that is not there.
  if entry.kind == "note" then
    return "(no file)", nil
  end

  local rel = M.relative_to(entry.abs_path, base)
  local where = rel or entry.abs_path or entry.path

  -- Out of the target's tree, or anchored to lines we can no longer trust: either way an
  -- `@ref` would point somewhere wrong, so the code travels with the note instead.
  local must_inline = entry.inline or entry.stale or not rel

  if entry.kind == "file" then
    if rel and not entry.stale then
      return M.ref(rel), nil
    end
    return ("%s (%s)"):format(where, entry.tag or "whole file"), nil
  end

  if not must_inline then
    return M.ref(rel, entry.first, entry.last), nil
  end

  local tags = {}
  if entry.tag then
    tags[#tags + 1] = entry.tag
  end
  if entry.stale then
    tags[#tags + 1] = "line numbers may be stale"
  end
  local suffix = #tags > 0 and (" (%s)"):format(table.concat(tags, ", ")) or ""
  return ("%s:%s%s"):format(where, range_text(entry), suffix), entry.lines
end

---Render the whole queue as one message.
---@param items CRAnnotation[]
---@param base string Directory `@refs` should resolve against
---@param opts { types: CRType[], scope_label?: string, files?: integer, reviewed?: integer }
---@return string
function M.render(items, base, opts)
  local out = {}

  -- Once, before the entries: the comparison below is against paths that are already
  -- canonical, and `base` is the only side that never went through git or a realpath.
  base = M.resolve_base(base)

  -- Grouped here rather than through queue.lua so this stays a pure function of its
  -- arguments: the same list always renders the same message, which is what makes the
  -- payload testable without a view or a live queue.
  local groups = {}
  for _, t in ipairs(opts.types) do
    local bucket = {}
    for _, entry in ipairs(items) do
      if entry.type == t.name then
        bucket[#bucket + 1] = entry
      end
    end
    if #bucket > 0 then
      groups[#groups + 1] = { type = t, items = bucket }
    end
  end

  local total = #items
  local header = ("Code review — %d annotation%s"):format(total, total == 1 and "" or "s")
  if opts.scope_label then
    header = header .. (" on %s"):format(opts.scope_label)
  end
  if opts.files then
    local reviewed = opts.reviewed or 0
    header = header .. (" (%d file%s, %d reviewed)"):format(opts.files, opts.files == 1 and "" or "s", reviewed)
  end
  out[#out + 1] = header

  -- Numbering runs across the whole batch, not per group, so "entry 7" is unambiguous
  -- when replying about one.
  local index = 0
  for _, group in ipairs(groups) do
    out[#out + 1] = ""
    -- The directive is what earns a type its keystroke, but it is optional: a type
    -- without one still groups, it just does not tell the agent what to do.
    local heading = ("## %s (%d)"):format(group.type.label, #group.items)
    if group.type.directive and group.type.directive ~= "" then
      heading = heading .. (" — %s"):format(group.type.directive)
    end
    out[#out + 1] = heading

    for _, entry in ipairs(group.items) do
      index = index + 1
      local heading, block = describe(entry, base)
      out[#out + 1] = ""
      out[#out + 1] = ("### %d. %s"):format(index, heading)
      if block and #block > 0 then
        out[#out + 1] = "```diff"
        vim.list_extend(out, block)
        out[#out + 1] = "```"
      end
      out[#out + 1] = ""
      out[#out + 1] = entry.note
    end
  end

  return table.concat(out, "\n")
end

return M
