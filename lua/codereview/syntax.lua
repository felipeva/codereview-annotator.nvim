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

-- How many entries have ever been written into that cache. Counted rather than measured,
-- so that anything mirroring the set can tell in one comparison whether it has moved --
-- this is read on the scroll path, where walking the cache per keystroke would be work
-- done for the answer "nothing new".
local resolutions = 0

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
  resolutions = resolutions + 1
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
---
---**Hand this an absolute path from inside a review.** `vim.filetype.match` absolutises a
---relative name for itself, through `vim.fs.abspath`, which is an `assert(vim.uv.cwd())` --
---so a relative name is a working-directory read wearing a filetype's clothes. It raises,
---rather than answering wrongly, once the review's **checkout** is deleted and the tab it
---is drawn in has no working directory at all. That is ADR-0008's rule reached through a
---library call instead of through plugin code, and it is why the ADR says *every*
---working-directory read inside a review is a bug, including a convenient one.
---
---Still typed as any path, and still asked with a relative one from outside a review, where
---there is no root to join from and a working directory is the honest answer.
---@param path string Absolute, when the caller has a review's root to join from
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

---Where a side's captures are memoised on the view.
---@param file CRFile
---@param side "before"|"after"
---@return string
local function cache_key(file, side)
  return file.path .. "|" .. side
end

---The spec a side would be fetched by, or nil when it would not be fetched at all.
---
---Asked before anything is painted, so that every side coming into view this pass can be
---fetched in one process. It must answer exactly what `apply_side` decides for itself a
---moment later: a side missing from the batch costs the process the batch was for, and a
---side in it that nothing reads is a blob fetched for nothing.
---@param view CRView
---@param file CRFile
---@param side "before"|"after"
---@param map table<integer, { row: integer, col: integer }>
---@param ref string|nil
---@return string|nil
local function fetch_spec(view, file, side, map, ref)
  -- A nil ref is the working tree, which is read from disk and costs no process at all.
  if ref == nil or vim.tbl_isempty(map) then
    return nil
  end
  if view.syntax_cache[cache_key(file, side)] ~= nil then
    return nil
  end
  return git.spec(ref, file.path)
end

---@param view CRView
---@param ns integer
---@param buf integer Buffer the rows in `map` are rows of
---@param file CRFile
---@param side "before"|"after"
---@param map table<integer, { row: integer, col: integer }>
---@param ref string|nil
---@param lang string
---@param group_of (fun(group: string): string)|nil What the caller wants a token drawn in
---@param fetched table<string, string|false> What the pass already fetched in one process
local function apply_side(view, ns, buf, file, side, map, ref, lang, group_of, fetched)
  if vim.tbl_isempty(map) then
    return
  end

  local cfg = config.get()
  local key = cache_key(file, side)
  local caps = view.syntax_cache[key]

  if caps == nil then
    -- Three answers, not two. A string is the content. `false` is git saying there is no
    -- blob on this side -- an added or deleted file -- and asking again buys the same
    -- nothing for a whole process. nil is a side the batch did not cover: a working-tree
    -- side, a textconv path, or a batch that failed, all of which the single-file fetch is
    -- still here for.
    local hit = ref and fetched[git.spec(ref, file.path)]
    local content
    if hit == nil then
      content = git.file_content(file.path, ref, view.root)
    elseif hit then
      content = hit
    end
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
        hl_group = group_of and group_of(c.hl) or c.hl,
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
---
---`group_for` is asked, per file, what that file's tokens should be drawn in. It is how a
---**faded** file's code keeps its syntax structure while receding with the rest of the file,
---and the rule behind it lives with the caller: this module knows which file it is painting
---and nothing about where the cursor is.
---@param view CRView
---@param ns integer
---@param group_for (fun(fi: integer): (fun(group: string): string)|nil)|nil
function M.apply(view, ns, group_for)
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

  -- Which files come into view this pass, decided before any of them is painted. The two
  -- halves used to be one loop, and the split is what lets every side one scroll brings
  -- into view be fetched together: one file at a time, each one's content was a `git show`
  -- of its own, so a jump onto a screenful of small files paid a process for every one.
  local due, wanted = {}, {}
  for fi, maps in pairs(view.syntax_rows) do
    local file = view.files[fi]
    -- A file is parsed whole once any part of it is near the window: parsing only the
    -- visible slice would cache a partial capture set that the next scroll invalidates.
    -- The panes hold the same rows, so one pane's bounds answer for both.
    local near = maps.first <= hi and maps.last >= lo
    if near and not file.binary and not view.syntax_painted[file.path] then
      -- Joined from the review's root, never left relative: the language question is
      -- answered by a call that absolutises what it is given, so a relative path here reads
      -- the working directory and raises once the checkout is gone. `open_file` joins from
      -- the same authority, which is the pattern ADR-0008 names.
      local lang = M.lang_for(vim.fs.joinpath(view.root, file.path))
      if lang then
        -- An untracked file has no committed pre-image; its "after" is the working tree.
        local work = {
          fi = fi,
          file = file,
          lang = lang,
          maps = maps,
          after = file.status == "U" and nil or view.scope.after,
          before = view.scope.before,
        }
        due[#due + 1] = work
        for _, side in ipairs({ "after", "before" }) do
          if fetch_spec(view, file, side, maps[side], work[side]) then
            wanted[#wanted + 1] = { path = file.path, ref = work[side] }
          end
        end
      end
      -- Set here rather than after the paint, and for a file with no parser too: the
      -- question this answers is "has this file had its chance", which a file treesitter
      -- cannot read has had.
      view.syntax_painted[file.path] = true
    end
  end
  if #due == 0 then
    return
  end

  -- Empty when there was nothing a batch could take, which costs nothing: each side then
  -- falls through to the single-file fetch exactly as it always did.
  local fetched = #wanted > 0 and git.file_contents(wanted, view.root) or {}

  for _, work in ipairs(due) do
    local group_of = group_for and group_for(work.fi) or nil
    apply_side(view, ns, view.buf, work.file, "after", work.maps.after, work.after, work.lang, group_of, fetched)
    -- Each image paints onto the pane that shows it. With one pane, that is the same
    -- buffer twice, which is what the unified layout has always done.
    local before_buf = split and view.before_buf or view.buf
    apply_side(view, ns, before_buf, work.file, "before", work.maps.before, work.before, work.lang, group_of, fetched)
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

---Every highlight group the replay has resolved so far, as the memo holds them.
---
---The memo itself rather than a copy, and read-only by contract: this is asked on the
---scroll path, where an allocation per keystroke would be paid on a review nobody is
---highlighting anything new in. Keyed by `capture.language`, which is the memo's own key;
---what a caller wants is the values.
---
---A file is parsed only as its rows come near the window, so this set *grows* while a
---review is open. Anything mirroring it -- the muting namespace is the one -- has to be
---extended as it does rather than built from it once.
---@return table<string, string>
function M.resolved_groups()
  return hl_cache
end

---How many resolutions have been made, ever. Only ever compared with itself.
---@return integer
function M.resolutions()
  return resolutions
end

---Forget capture-name -> highlight-group resolutions.
---
---Which group a capture resolves to depends on what the colorscheme defines, so the
---answers are only valid for the colorscheme that was active when they were cached.
function M.clear_hl_cache()
  hl_cache = {}
  -- Moved, not reset: the count is only ever compared with itself, and a mirror that saw
  -- the old total must not read the empty cache as "nothing has changed".
  resolutions = resolutions + 1
end

return M
