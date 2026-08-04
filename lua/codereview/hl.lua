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

  -- An archived entry drawn on the diff, beneath the code it was about. One step dimmer
  -- than the live counterpart of each chunk it replaces -- the marker where a queued entry
  -- carries its annotation type's severity, the prose where it carries `CodeReviewNote` --
  -- so what has already gone reads as recessive at a glance rather than as a different
  -- kind of remark. `NonText` is what every colorscheme tunes for the dimmest thing on
  -- screen, which is exactly what this is.
  CodeReviewArchived = "Comment",
  CodeReviewArchivedNote = "NonText",
  CodeReviewTitle = "Title",
  CodeReviewPanelSel = "CursorLine",
  CodeReviewPanelDir = "Directory",

  -- The chrome of the floats that list entries as rows -- the queue float, and the archive
  -- float that reads the last dispatched batch back. Named for the queue because that is
  -- where they started, and shared rather than duplicated because the two surfaces list the
  -- same shape of thing and a reviewer overriding one means both. The bar running down an
  -- entry is that annotation type's group rather than one of these, so what is left is the
  -- number the entry is listed under and the state that rides on the right of its first row.
  CodeReviewQueueIndex = "LineNr",
  CodeReviewQueueState = "Comment",

  -- Annotation types, mapped onto diagnostic severities so the visual weight already
  -- matches the intent: a bug reads as loud as an error, a nitpick as quiet as a hint.
  CodeReviewBug = "DiagnosticError",
  CodeReviewFix = "DiagnosticWarn",
  CodeReviewSuggestion = "DiagnosticInfo",
  CodeReviewNitpick = "DiagnosticHint",
  CodeReviewIssue = "DiagnosticOk",
}

-- What a configured type's highlight group falls back to. Neutral on purpose: the plugin
-- cannot know how loud a type nobody has heard of should be.
local TYPE_FALLBACK = "DiagnosticInfo"

-- What emphasises the characters that differ inside a changed line. `DiffText` is the
-- group every colorscheme already tunes for exactly that, so it is where the colour comes
-- from -- but the background is *copied* rather than linked to, which is the one place
-- this module departs from the pattern. A link would carry DiffText's foreground too, and
-- the syntax replay sits at a higher priority: that foreground would lose to it wherever
-- treesitter painted and win wherever it did not, which is emphasis that changes colour
-- depending on whether the language has a parser installed. A background alone composes
-- with the replay instead of fighting it, which is what keeps code readable inside a span.
--
-- A theme that gives DiffText no background at all therefore gets no emphasis, which is
-- the rendering as it was before this existed rather than a broken one.
local SPAN_SOURCE = "DiffText"
local SPAN_GROUPS = { "CodeReviewAddSpan", "CodeReviewDelSpan" }

local function apply_spans()
  local source = vim.api.nvim_get_hl(0, { name = SPAN_SOURCE, link = false })
  for _, group in ipairs(SPAN_GROUPS) do
    vim.api.nvim_set_hl(0, group, { bg = source.bg, ctermbg = source.ctermbg, default = true })
  end
end

function M.apply()
  for group, target in pairs(LINKS) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
  apply_spans()

  -- A configured type names a group this module cannot know about, so without this a
  -- custom type renders with no colour at all. After LINKS and with `default = true`, so
  -- the built-in types keep their severity mapping and a user's own group is left alone.
  for _, t in ipairs(require("codereview.config").get().types) do
    vim.api.nvim_set_hl(0, t.hl, { link = TYPE_FALLBACK, default = true })
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
