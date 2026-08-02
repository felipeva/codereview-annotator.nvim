---Highlight groups.
---
---Everything is a `default = true` link to a group colorschemes already define, so the
---view inherits the active theme instead of hardcoding a palette, and any of these can be
---overridden in a user's config without the plugin fighting back.
local M = {}

local LINKS = {
  -- Diff line backgrounds. Linked rather than computed: DiffAdd/DiffDelete are the
  -- groups every colorscheme tunes for exactly this purpose.
  CodeReviewAdd = "DiffAdd",
  CodeReviewDel = "DiffDelete",
  CodeReviewLineNr = "LineNr",
  -- `Added`/`Removed`/`Changed` are standard Neovim groups and carry a foreground colour,
  -- which is what a change bar and a `+12 -3` stat need.
  CodeReviewAddBar = "Added",
  CodeReviewDelBar = "Removed",
  CodeReviewStatAdd = "Added",
  CodeReviewStatDel = "Removed",

  CodeReviewFileHeader = "Title",
  CodeReviewFileReviewed = "Comment",
  CodeReviewHunkHeader = "Special",
  CodeReviewSep = "WinSeparator",
  CodeReviewNoteCount = "Comment",
  CodeReviewNote = "Comment",
  CodeReviewStale = "DiagnosticWarn",
  CodeReviewTitle = "Title",
  CodeReviewPanelSel = "CursorLine",
  CodeReviewPanelDir = "Directory",

  -- Annotation types, mapped onto diagnostic severities so the visual weight already
  -- matches the intent: a bug reads as loud as an error, a nitpick as quiet as a hint.
  CodeReviewBug = "DiagnosticError",
  CodeReviewFix = "DiagnosticWarn",
  CodeReviewSuggestion = "DiagnosticInfo",
  CodeReviewNitpick = "DiagnosticHint",
  CodeReviewIssue = "DiagnosticOk",
}

function M.apply()
  for group, target in pairs(LINKS) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
  -- Capture -> group resolution depends on what the theme defines, so it cannot outlive
  -- the theme. Guarded because hl.setup() runs before syntax.lua is ever required.
  if package.loaded["codereview.syntax"] then
    require("codereview.syntax").clear_hl_cache()
  end
end

---Re-link after a colorscheme change, since `nvim_set_hl` definitions are cleared by
---`:colorscheme`.
function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("CodeReviewHighlights", { clear = true }),
    callback = M.apply,
  })
end

return M
