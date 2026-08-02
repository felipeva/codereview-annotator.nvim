---Annotation types.
---
---A type is not decoration. `directive` is what earns it a keystroke: it becomes the
---instruction attached to that group in the submitted payload, so "bug" and "nitpick"
---produce different behaviour from the receiving agent rather than just different icons.
local M = {}

---@class CRType
---@field name string       Required. Identifier used by `annotate()` and stored on an entry.
---@field key string        Required. Suffix after the `a` annotate prefix.
---@field icon string       Defaults to the configured `icons.annotated`.
---@field hl string         Defaults to `CodeReview<Name>`, auto-linked so it has colour.
---@field label string      Group heading in the payload. Defaults to the pluralised name.
---@field directive string? What the receiving agent should do with this group. Optional:
---                         a type without one gets a bare `## Label (n)` heading.

---Order is meaningful: it is the order groups appear in the payload, most actionable
---first, so the important work is not buried under nitpicks.
---@type CRType[]
M.defaults = {
  {
    name = "bug",
    key = "b",
    icon = "",
    hl = "CodeReviewBug",
    label = "Bugs",
    directive = "diagnose and fix these",
  },
  {
    name = "fix",
    key = "f",
    icon = "",
    hl = "CodeReviewFix",
    label = "Fixes",
    directive = "apply these changes",
  },
  {
    name = "suggestion",
    key = "s",
    icon = "",
    hl = "CodeReviewSuggestion",
    label = "Suggestions",
    directive = "evaluate; apply if sound",
  },
  {
    name = "nitpick",
    key = "n",
    icon = "",
    hl = "CodeReviewNitpick",
    label = "Nitpicks",
    directive = "low priority — batch these together",
  },
  {
    name = "issue",
    key = "i",
    icon = "",
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
  -- Naive pluralisation, minus the worst case. A name that is already plural, or one
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
function M.normalise(list, opts)
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
    t.icon = t.icon or opts.icon or "●"
    t.hl = t.hl or ("CodeReview" .. table.concat(words(t.name)))
    out[i] = t
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
