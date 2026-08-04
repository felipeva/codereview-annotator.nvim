---Treesitter syntax highlighting for the unified diff buffer.
---
---Only one treesitter highlighter can attach to a buffer, so a buffer holding TypeScript,
---Lua and JSON at once cannot use `vim.treesitter.start`. Instead each file's *content* is
---parsed as a string, the `highlights` query is walked, and the resulting captures are
---replayed as extmarks onto the rows where that content is rendered.
---
---Deleted and added lines come from different sides of the diff, so each file is parsed
---up to twice: once for the pre-image (feeding `-` lines) and once for the post-image
---(feeding `+` and context lines).
local config = require("codereview.config")
local git = require("codereview.git")
local render = require("codereview.render")

local M = {}

---@alias CRCapture { line: integer, cs: integer, ce: integer, hl: string }

-- Capture-name -> highlight group. Resolution hits nvim_get_hl on every capture
-- otherwise, which is thousands of calls per file.
local hl_cache = {}

---Highlight group for a capture.
---
---Prefers the language-specific `@keyword.lua` when a colorscheme defines it, falling
---back to the generic `@keyword`. Extmarks do not perform the dotted fallback that
---treesitter's own highlighter relies on, so an unresolved specific group would simply
---render as nothing.
---@param name string
---@param lang string
---@return string
local function resolve_hl(name, lang)
  local key = name .. "." .. lang
  local hit = hl_cache[key]
  if hit ~= nil then
    return hit
  end
  local specific = "@" .. key
  local ok, def = pcall(vim.api.nvim_get_hl, 0, { name = specific, link = true })
  local group = (ok and not vim.tbl_isempty(def)) and specific or ("@" .. name)
  hl_cache[key] = group
  return group
end

-- Per-language memo of "is a parser really installed". One probe per language, ever.
local parser_ok = {}

---@param lang string
---@return boolean
local function parser_available(lang)
  local hit = parser_ok[lang]
  if hit ~= nil then
    return hit
  end
  -- `vim.treesitter.language.add` is lazy in Neovim 0.12: it registers the language and
  -- returns true even when no parser exists on the runtimepath. The only honest test is
  -- to instantiate one, which is why this is memoised rather than asked per file.
  local ok = pcall(vim.treesitter.get_string_parser, "", lang)
  parser_ok[lang] = ok
  return ok
end

---Treesitter language for a path, or nil when there is no parser for it.
---@param path string
---@return string|nil
function M.lang_for(path)
  local ft = vim.filetype.match({ filename = path })
  if not ft then
    return nil
  end
  local ok, lang = pcall(vim.treesitter.language.get_lang, ft)
  lang = (ok and lang) or ft
  return parser_available(lang) and lang or nil
end

---Parse `content` and collect the captures that land on lines we actually render.
---
---Filtering by `wanted` here rather than at replay time keeps the cached result
---proportional to the size of the diff instead of the size of the file.
---@param content string
---@param lang string
---@param wanted table<integer, any> Set of 1-indexed source lines that are rendered
---@return CRCapture[]|false
local function harvest(content, lang, wanted)
  local lo, hi = math.huge, 0
  for n in pairs(wanted) do
    lo, hi = math.min(lo, n), math.max(hi, n)
  end
  if hi == 0 then
    return false
  end

  local ok, parser = pcall(vim.treesitter.get_string_parser, content, lang)
  if not ok or not parser then
    return false
  end

  local parsed, trees = pcall(function()
    return parser:parse()
  end)
  if not parsed or not trees or not trees[1] then
    return false
  end

  local query = vim.treesitter.query.get(lang, "highlights")
  if not query then
    return false
  end

  local src = vim.split(content, "\n", { plain = true })
  local out = {}

  local walked = pcall(function()
    for id, node in query:iter_captures(trees[1]:root(), content, lo - 1, hi) do
      local group = resolve_hl(query.captures[id], lang)
      local sr, sc, er, ec = node:range()
      -- A capture can span lines (block comments, template strings), so it is split into
      -- one per-line range; only the rendered lines survive the `wanted` check.
      for r = sr, er do
        local line = r + 1
        if wanted[line] then
          local cs = (r == sr) and sc or 0
          local ce = (r == er) and ec or #(src[line] or "")
          if ce > cs then
            out[#out + 1] = { line = line, cs = cs, ce = ce, hl = group }
          end
        end
      end
    end
  end)

  return walked and out or false
end

---@param view CRView
---@param ns integer
---@param buf integer Buffer the rows in `map` are rows of
---@param file CRFile
---@param side "before"|"after"
---@param map table<integer, { row: integer, col: integer }>
---@param ref string|nil
---@param lang string
local function apply_side(view, ns, buf, file, side, map, ref, lang)
  if vim.tbl_isempty(map) then
    return
  end

  local cfg = config.get()
  local key = file.path .. "|" .. side
  local caps = view.syntax_cache[key]

  if caps == nil then
    local content = git.file_content(file.path, ref, view.root)
    -- `false` is the memo for "do not try this file again": a missing side (added or
    -- deleted file), an oversized file, or a parse that failed.
    if not content or #content > cfg.max_syntax_bytes or git.looks_binary(content) then
      view.syntax_cache[key] = false
      return
    end
    local wanted = {}
    for line in pairs(map) do
      wanted[line] = true
    end
    caps = harvest(content, lang, wanted)
    view.syntax_cache[key] = caps
  end

  if not caps then
    return
  end

  for _, c in ipairs(caps) do
    local slot = map[c.line]
    if slot then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, slot.row - 1, slot.col + c.cs, {
        end_col = slot.col + c.ce,
        hl_group = c.hl,
        priority = render.PRIORITY.syntax,
      })
    end
  end
end

---Rows of slack above and below the window. Generous enough that ordinary scrolling never
---waits on a parse, small enough that opening a 60-file review parses two files instead of
---sixty.
---
---Exported because the diff's own extmarks are bounded by this same figure, and a second
---one would drift: the two bounds decide together what a row on screen ends up carrying,
---so a harvest reaching further than the emission is highlighting on a row with no diff
---background under it.
M.VIEWPORT_MARGIN = 120

---Rows currently worth painting: the window's own, plus the margin above and below.
---
---Exported for the same reason the margin is, and preferred to it: the view bounds its own
---emission against this, so the two answers agree by construction rather than by two call
---sites doing the same arithmetic.
---@param view CRView
---@return integer lo, integer hi
function M.viewport(view)
  if not vim.api.nvim_win_is_valid(view.win) then
    return 1, #view.render.lines
  end
  -- Returned as a table: nvim_win_call propagates only the first return value, so a
  -- two-value return silently loses the end of the range.
  local ok, span = pcall(vim.api.nvim_win_call, view.win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  if not ok or type(span) ~= "table" or not span[1] or not span[2] then
    return 1, #view.render.lines
  end
  return math.max(1, span[1] - M.VIEWPORT_MARGIN), math.min(#view.render.lines, span[2] + M.VIEWPORT_MARGIN)
end

---@alias CRFileRows { before: table<integer, { row: integer, col: integer }>, after: table<integer, { row: integer, col: integer }>, first: integer, last: integer }

---Invert the anchor map: for each file, which source line is drawn on which row and at what
---byte column its code text begins, plus the first and last row the file occupies.
---
---A pure function of the render and, in the split layout, of the before render, which is
---why the answer is held on the view rather than derived per call: only a repaint can
---change it. Derived per call it is a walk of the whole review, and `apply` is wired to
---both `WinScrolled` and `CursorMoved` -- on a 90,000-row review that walk alone is most of
---what a reviewer pays per keystroke.
---@param view CRView
---@return table<integer, CRFileRows>
local function invert(view)
  local out = {}

  ---@param anchors table<integer, CRAnchor>|nil
  ---@param pane "unified"|"after"|"before"
  local function collect(anchors, pane)
    for row, a in pairs(anchors or {}) do
      if a.kind == "line" then
        local entry = out[a.file]
        if not entry then
          entry = { before = {}, after = {}, first = row, last = row }
          out[a.file] = entry
        end
        entry.first = math.min(entry.first, row)
        entry.last = math.max(entry.last, row)
        local ln = view.files[a.file].hunks[a.hunk].lines[a.line]
        if pane == "before" then
          -- In the split layout the pane decides the image, not the line. A context line is
          -- drawn in both, and the copy in the before pane is the pre-image's, at the
          -- pre-image's line number.
          entry.before[ln.old] = { row = row, col = a.col }
        elseif ln.new then
          -- Unified has one buffer, so context lines are attributed to the post-image,
          -- which keeps a single parse authoritative for everything except pure deletions.
          entry.after[ln.new] = { row = row, col = a.col }
        else
          entry.before[ln.old] = { row = row, col = a.col }
        end
      end
    end
  end

  local split = view.before_render ~= nil
  collect(view.render.anchors, split and "after" or "unified")
  if split then
    collect(view.before_render.anchors, "before")
  end
  return out
end

---Paint treesitter highlights over the rendered diff.
---
---Bounded by the viewport, not by the diff: a file is parsed the first time any of its
---rows come near the window, and never otherwise. Without this a 60-file review pays for
---120 parses before it can draw anything, which is a second of latency on open for
---highlighting nobody can see yet.
---
---Safe to call repeatedly. The row map is inverted once per paint, each file's captures are
---memoised, and `syntax_painted` stops already-painted files from having their extmarks
---emitted twice per render -- so a call with nothing new near the window is a lookup.
---@param view CRView
---@param ns integer
function M.apply(view, ns)
  if not config.get().syntax or not view.render then
    return
  end
  view.syntax_cache = view.syntax_cache or {}
  view.syntax_painted = view.syntax_painted or {}
  -- Rebuilt here rather than in the paint, so that dropping it is all a repaint has to do
  -- and the first pass after one pays for it.
  view.syntax_rows = view.syntax_rows or invert(view)

  local lo, hi = M.viewport(view)
  local split = view.before_render ~= nil

  for fi, maps in pairs(view.syntax_rows) do
    local file = view.files[fi]
    -- A file is parsed whole once any part of it is near the window: parsing only the
    -- visible slice would cache a partial capture set that the next scroll invalidates.
    -- The panes hold the same rows, so one pane's bounds answer for both.
    local near = maps.first <= hi and maps.last >= lo
    if near and not file.binary and not view.syntax_painted[file.path] then
      local lang = M.lang_for(file.path)
      if lang then
        -- An untracked file has no committed pre-image; its "after" is the working tree.
        local after_ref = file.status == "U" and nil or view.scope.after
        apply_side(view, ns, view.buf, file, "after", maps.after, after_ref, lang)
        -- Each image paints onto the pane that shows it. With one pane, that is the same
        -- buffer twice, which is what the unified layout has always done.
        local before_buf = split and view.before_buf or view.buf
        apply_side(view, ns, before_buf, file, "before", maps.before, view.scope.before, lang)
      end
      view.syntax_painted[file.path] = true
    end
  end
end

---Drop everything memoised about the diff on screen. Called when it is re-read and when
---the scope changes: the captures are keyed by path and side only, so they mean nothing
---once the refs behind those sides move, and the row map describes rows drawn from files
---that are being replaced.
---@param view CRView
function M.invalidate(view)
  view.syntax_cache = {}
  view.syntax_painted = {}
  view.syntax_rows = nil
end

---Drop what a repaint invalidated, keeping the parsed captures.
---
---Called on every repaint: the extmarks are gone (the namespace was cleared) and the row
---map was inverted from renders that no longer exist, but the captures are still valid, so
---the files back in view repaint from cache. A map that outlives its render points at rows
---that no longer hold what it claims, which is highlighting on unrelated code rather than
---highlighting that is merely missing.
---@param view CRView
function M.repainted(view)
  view.syntax_painted = {}
  view.syntax_rows = nil
end

---Forget capture-name -> highlight-group resolutions.
---
---Which group a capture resolves to depends on what the colorscheme defines, so the
---answers are only valid for the colorscheme that was active when they were cached.
function M.clear_hl_cache()
  hl_cache = {}
end

return M
