---Annotation types.
---
---A type is not decoration. `directive` is what earns it a keystroke: it becomes the
---instruction attached to that group in the submitted payload, so "bug" and "nitpick"
---produce different behaviour from the receiving agent rather than just different icons.
local M = {}

---@class CRType
---@field name string
---@field key string       Suffix after the `a` annotate prefix
---@field icon string
---@field hl string
---@field label string     Group heading in the payload
---@field directive string What the receiving agent should do with this group

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
