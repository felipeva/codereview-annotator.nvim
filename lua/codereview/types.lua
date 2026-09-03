---Annotation types.
---
---A type is not decoration. `directive` is what earns it a keystroke: it becomes the
---instruction attached to that group in the submitted payload, so "bug" and "nitpick"
---produce different behavior from the receiving agent rather than just different icons.
local M = {}

---@class CRType
---@field name string       Required. Identifier used by `annotate()` and stored on an entry.
---@field key string        Required. Suffix after the `a` annotate prefix.
---@field icon string       Defaults to the configured `icons.annotated`, which is also
---                         what an empty one gets: empty means *no glyph of my own*.
---@field hl string         Defaults to `CodeReview<Name>`, auto-linked so it has color.
---@field label string      Group heading in the payload. Defaults to the pluralized name.
---@field directive string? What the receiving agent should do with this group. Optional:
---                         a type without one gets a bare `## Label (n)` heading.

---Order is meaningful: it is the order groups appear in the payload, most actionable
---first, so the important work is not buried under nitpicks.
---
---The glyphs are plain Unicode and one display column wide at `ambiwidth=single`, which is
---the default and what the suite measures. Three surfaces draw them -- the type picker, a
---queued note on the diff and an **archived** entry -- and on the last of those the glyph
---is all there is: an archived entry gives up its type's color deliberately, so a type
---whose glyph was empty said nothing at all about what kind of finding it was.
---
---What each one was chosen against, because a glyph that says two things is worse than one
---nobody chose: `⚠` was not available, since the queue float already spends it on a
---**stale** entry; a nitpick takes `▫` rather than `◦`, which is the untyped mark `•` at
---another size; and none of them is a mark the `icons` table already draws. Nothing here
---may need a patched font, which is that table's own rule.
---@type CRType[]
M.defaults = {
  {
    name = "bug",
    key = "b",
    icon = "✗",
    hl = "CodeReviewBug",
    label = "Bugs",
    directive = "diagnose and fix these",
  },
  {
    name = "fix",
    key = "f",
    icon = "✎",
    hl = "CodeReviewFix",
    label = "Fixes",
    directive = "apply these changes",
  },
  {
    name = "suggestion",
    key = "s",
    icon = "✦",
    hl = "CodeReviewSuggestion",
    label = "Suggestions",
    directive = "evaluate; apply if sound",
  },
  {
    name = "nitpick",
    key = "n",
    icon = "▫",
    hl = "CodeReviewNitpick",
    label = "Nitpicks",
    directive = "low priority — batch these together",
  },
  {
    name = "issue",
    key = "i",
    icon = "⚑",
    hl = "CodeReviewIssue",
    label = "Issues",
    directive = "do NOT fix — summarize these for tracking",
  },
}

---Words of a name, split on anything that is not alphanumeric: `needs-info` -> Needs, Info.
---@param name string
---@return string[]
local function words(name)
  local out = {}
  for word in name:gmatch("%w+") do
    out[#out + 1] = word:sub(1, 1):upper() .. word:sub(2)
  end
  return out
end

---@param name string
---@return string
local function default_label(name)
  local label = table.concat(words(name), " ")
  -- Naive pluralization, minus the worst case. A name that is already plural, or one
  -- English declines irregularly, wants an explicit `label`.
  return label:lower():sub(-1) == "s" and label or (label .. "s")
end

---@param fmt string
local function fail(fmt, ...)
  -- Level 0: the useful location is the user's config, which is not on this stack anyway,
  -- so a `types.lua:NN:` prefix would only point at the wrong file.
  error("codereview.setup: " .. fmt:format(...), 0)
end

---Validate a configured type list and fill in everything that has a sensible default.
---
---Only `name` and `key` are required. The rest is derived, so adding a type costs two
---fields rather than six -- and a list that would fail later, at annotate time or as a
---keymap that silently shadows another, fails here instead with the index that caused it.
---@param list CRType[]
---@param opts? { icon?: string }
---@return CRType[]
function M.normalize(list, opts)
  opts = opts or {}

  if type(list) ~= "table" or vim.tbl_isempty(list) then
    fail("`types` must be a non-empty list of annotation types")
  end
  if not vim.islist(list) then
    fail("`types` must be a list of tables, not a map")
  end

  local out, by_name, by_key = {}, {}, {}
  for i, raw in ipairs(list) do
    if type(raw) ~= "table" then
      fail("types[%d] is a %s, not a table", i, type(raw))
    end
    local t = vim.deepcopy(raw)

    for _, field in ipairs({ "name", "key" }) do
      if type(t[field]) ~= "string" or t[field] == "" then
        fail("types[%d] has no `%s`", i, field)
      end
    end
    for _, field in ipairs({ "icon", "hl", "label", "directive" }) do
      if t[field] ~= nil and type(t[field]) ~= "string" then
        fail("types[%d].%s is a %s, not a string", i, field, type(t[field]))
      end
    end

    if by_name[t.name] then
      fail("types[%d] and types[%d] are both named %q", by_name[t.name], i, t.name)
    end
    by_name[t.name] = i

    -- `aa` opens the type picker, so a type keyed "a" would shadow it.
    if t.key == "a" then
      fail("types[%d] uses key %q, which collides with the `aa` type picker", i, t.key)
    end
    if by_key[t.key] then
      fail("types[%d] and types[%d] both use key %q", by_key[t.key], i, t.key)
    end
    by_key[t.key] = i

    t.label = t.label or default_label(t.name)
    -- An empty icon is *absent*, not a glyph. `t.icon or ...` never fires on one, because
    -- an empty string is truthy in Lua -- so a type configured with `icon = ""` drew a hole
    -- wherever a glyph belongs, and the documented fallback was reachable only by leaving
    -- the field out. Rejecting it instead was the other candidate and it loses: a host who
    -- cleared a glyph asked for no glyph of their own, which is what the annotated mark
    -- already means, and an error would refuse a configuration that reads perfectly well.
    if t.icon == "" then
      t.icon = nil
    end
    t.icon = t.icon or opts.icon or "●"
    t.hl = t.hl or ("CodeReview" .. table.concat(words(t.name)))
    out[i] = t
  end

  return out
end

---The group an annotation with no annotation type falls into.
---
---Not a configured type and never one: it has no `name`, so nothing can be annotated *as*
---untyped and no entry ever stores it. It exists so that both renderers have a heading and
---a mark to print for a remark that carries no instruction. No `directive` for the same
---reason -- a group with nothing to instruct should not pretend otherwise.
---
---The mark matches the one `render.lua` already prints for an annotation whose type it
---cannot resolve, so an untyped note looks the same on the diff as it does in the queue.
---@type CRType
M.UNTYPED = { label = "Untyped", icon = "•" }

---@class CRGroup
---@field type CRType Configured type, or `M.UNTYPED`
---@field items CRAnnotation[]

---Bucket annotations by annotation type, in the configured type order.
---
---One helper rather than one loop per consumer: the queue float and the payload renderer
---both group, and while they each owned a copy the two could -- and did -- drift into
---disagreeing about what the queue contains.
---
---Pure, and deliberately takes the list rather than reading the queue: the payload
---renderer is a pure function of its arguments, which is what lets a payload be asserted
---without a live queue or a review view. Grouping through the queue would end that.
---@param items CRAnnotation[]
---@param list CRType[]
---@return CRGroup[]
function M.group(items, list)
  local out, configured = {}, {}
  for _, t in ipairs(list) do
    configured[t.name] = true
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

  -- Last, after every typed group: an untyped annotation is worth reading, but a group
  -- with no directive has nothing to ask for, so it does not belong above the ones that do.
  --
  -- Everything the loop above could not place, rather than only the entries carrying no
  -- type at all: a queue persisted before a host dropped a type from its list restores
  -- entries naming one that is gone, and those were being discarded just as silently.
  local untyped = {}
  for _, item in ipairs(items) do
    if not configured[item.type] then
      untyped[#untyped + 1] = item
    end
  end
  if #untyped > 0 then
    out[#out + 1] = { type = M.UNTYPED, items = untyped }
  end

  return out
end

---@param list CRType[]
---@param name string
---@return CRType|nil
function M.get(list, name)
  for _, t in ipairs(list) do
    if t.name == name then
      return t
    end
  end
  return nil
end

return M
