---Highlight groups.
---
---Everything is a `default = true` link to a group colorschemes already define, so the
---view inherits the active theme instead of hardcoding a palette, and any of these can be
---overridden in a user's config without the plugin fighting back.
---
---**A group a review window draws in has to be named in one of the tables below.** They are
---not just where the links live: `M.groups()` derives the set the **muted** window is built
---from by reading them, so a group that exists anywhere else is one a muted window leaves at
---full brightness. Adding a group means adding it here -- to `LINKS` if it links to
---something a colorscheme defines, to `SPAN_GROUPS` if it is computed, to `EDITOR_GROUPS` if
---it is the editor's own and this plugin merely draws through it -- and then it is muted
---without a second list learning about it. There is deliberately no register to remember to
---update, because the one thing that would go wrong is invisible until someone looks at an
---unfocused pane.
---
---**The blended colours are groups of this module, not colours in a window.** A group that
---a **muted** window draws, that a **faded** file's row carries, or that a muted pane lights
---its **counterpart row** in, gets a twin here, named for the group it blends. The window
---that mutes links to that twin instead of holding a colour of its own, and the fade emits it
---in place of the group the row would carry, so one piece of arithmetic answers all three.
---See `M.blended` below.
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

  -- Whether an archived entry's file has moved since its batch went. Deliberately *not*
  -- `CodeReviewStale`'s group: the two answer different questions about different entries,
  -- and one colour for both is the merge the rule itself refuses. The unremarkable answer
  -- takes the dimmest group there is -- a file the agent changed is what reading an agent's
  -- work expects -- and the one worth noticing takes the quietest diagnostic rather than a
  -- warning, because a file nothing happened to is not yet a problem.
  CodeReviewTouched = "NonText",
  CodeReviewUntouched = "DiagnosticHint",
  CodeReviewTitle = "Title",
  CodeReviewPanelSel = "CursorLine",
  CodeReviewPanelDir = "Directory",

  -- The **sticky header**'s own chrome. Everything else on that bar draws in a group it
  -- shares with the surface saying the same thing on the diff -- the stat in
  -- `CodeReviewStatAdd` and `CodeReviewStatDel`, the note count in `CodeReviewNoteCount`,
  -- the untouched tally in `CodeReviewUntouched` -- because one colour has to mean one
  -- thing wherever a reviewer meets it.
  --
  -- The path is deliberately not here. It draws in the bar's own group, which is the
  -- brightest thing a winbar has, and the two groups below are what leave it that: the
  -- separators are quieter than the facts between them, and the icon and the chevron are
  -- chrome in front of the one fact the reviewer scrolled there to keep.
  CodeReviewBarIcon = "Comment",
  CodeReviewBarSep = "NonText",
  CodeReviewBarTarget = "Special",
  -- The base revision the before **pane** names. Its own group rather than the target's:
  -- the two are accented alike today, and they answer entirely different questions.
  CodeReviewBarRev = "Special",

  -- The chrome of the floats that list entries as rows -- the queue float, and the archive
  -- float that reads the last dispatched batch back. Named for the queue because that is
  -- where they started, and shared rather than duplicated because the two surfaces list the
  -- same shape of thing and a reviewer overriding one means both. The bar running down an
  -- entry is that annotation type's group rather than one of these, so what is left is the
  -- number the entry is listed under and the state that rides on the right of its first row.
  CodeReviewQueueIndex = "LineNr",
  CodeReviewQueueState = "Comment",

  -- The row the commit list calls out: where the review the reviewer is already in starts.
  -- Its own group rather than the index's, because it answers *you are here* and not *this
  -- is which one* -- and it is the one thing in that float a reviewer is looking for before
  -- they change anything.
  CodeReviewTrimMark = "Special",

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

-- What a review window draws in that is not this plugin's to define: the text with no
-- capture over it, the row under the cursor, the gutter and the winbar. Named here rather
-- than where they are muted, so that every group this plugin has an opinion about is in one
-- file. The capture groups the treesitter replay resolves are not in any list: they depend
-- on what a reviewer has scrolled past, and `syntax.lua` already caches them per capture.
local EDITOR_GROUPS = { "Normal", "CursorLine", "LineNr", "WinBar", "WinBarNC" }

local function apply_spans()
  local source = vim.api.nvim_get_hl(0, { name = SPAN_SOURCE, link = false })
  for _, group in ipairs(SPAN_GROUPS) do
    vim.api.nvim_set_hl(0, group, { bg = source.bg, ctermbg = source.ctermbg, default = true })
  end
end

---Every highlight group a review window is known to draw in.
---
---Derived from the tables `apply` writes rather than kept beside them, so a group added
---there is one the muting knows about without a second list learning of it. A configured
---annotation type's group is in here too, for the same reason it is in `apply`: the plugin
---cannot know its name in advance.
---
---What this cannot enumerate is the treesitter replay's capture groups, which resolve as a
---reviewer scrolls -- `syntax.lua` holds those, and whoever wants the whole set asks both.
---@return string[]
function M.groups()
  local out = {}
  for group in pairs(LINKS) do
    out[#out + 1] = group
  end
  vim.list_extend(out, SPAN_GROUPS)
  vim.list_extend(out, EDITOR_GROUPS)
  for _, t in ipairs(require("codereview.config").get().types) do
    out[#out + 1] = t.hl
  end
  return out
end

--- The blended colours ----------------------------------------------------------

---@alias CRBlendFamily "muted"|"faded"|"counterpart"

---The families of blended groups: what each one's members are named, and how far each pulls.
---
---A blended group is named for the group it blends, so its name is derivable from that group
---and its family alone, and no table maps one to the other. The dot keeps the two parts
---apart: a treesitter capture group carries `@` and dots of its own, and
---`CodeReviewMuted.@keyword` can only be the twin of `@keyword`. No group this plugin
---defines starts with any of the prefixes, so a twin shadows none of them.
---
---**Three families, one blend.** A **muted** window, a **faded** file and the **counterpart
---row** a muted pane lights all pull the theme's own colours toward the same background, and
---each has a strength of its own because each covers a very different amount of the screen:
---the window rule answers for the panes a reviewer is not in, the fade for every file but
---one, the counterpart row for a single row inside a window the muting already has. A second
---copy of the arithmetic is how any two of them would drift apart in colour, which is what
---one family with a strength of its own avoids.
---
---**One member is enough to justify a family.** `counterpart` holds only `CursorLine`. The
---alternative is that second copy of the blend, written where the row is lit -- which is
---exactly the shape the two families above were built to refuse.
---
---`option` names the table in the configuration each family takes its strength from, so a
---family knows where its number comes from and nothing else has to.
---@type table<CRBlendFamily, { prefix: string, option: string }>
local FAMILIES = {
  muted = { prefix = "CodeReviewMuted.", option = "muted" },
  faded = { prefix = "CodeReviewFaded.", option = "faded" },
  counterpart = { prefix = "CodeReviewCounterpart.", option = "counterpart" },
}

---The twin of every group that has one, per family, keyed by the group it blends.
---@type table<CRBlendFamily, table<string, string>>
local twins = {}
for family in pairs(FAMILIES) do
  twins[family] = {}
end

---`Normal`'s background, memoised until the colorscheme changes.
---@type integer|nil
local toward = nil

---What a blended colour is pulled toward, whichever family asks.
---
---A theme that gives `Normal` no background at all has the terminal's behind it. The only
---knowable fact about that background is which way the theme leans.
---@return integer
local function backdrop()
  if not toward then
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    toward = normal.bg or (vim.o.background == "light" and 0xffffff or 0x000000)
  end
  return toward
end

---Pull one colour toward another, channel by channel.
---@param colour integer 0xRRGGBB
---@param target integer 0xRRGGBB
---@param strength number 0 keeps the colour. 1 replaces it with `target`.
---@return integer
local function blend(colour, target, strength)
  local out = 0
  for _, place in ipairs({ 65536, 256, 1 }) do
    local from = math.floor(colour / place) % 256
    local to = math.floor(target / place) % 256
    out = out + math.floor(from + (to - from) * strength + 0.5) * place
  end
  return out
end

---Write `family`'s twin of `group`, or report that `group` has no colour to blend.
---
---Only the true-colour attributes are blended. `ctermfg` and `ctermbg` are indices into a
---palette with no channels to pull, so they are copied without a change.
---@param family CRBlendFamily
---@param group string
---@return boolean written True if the twin now holds a blend of `group`.
local function write_twin(family, group)
  local ok, def = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if not ok or type(def) ~= "table" or (def.fg == nil and def.bg == nil) then
    return false
  end
  local strength = require("codereview.config").get()[FAMILIES[family].option].strength
  local twin = vim.tbl_extend("force", {}, def)
  twin.fg = def.fg and blend(def.fg, backdrop(), strength) or nil
  twin.bg = def.bg and blend(def.bg, backdrop(), strength) or nil
  return (pcall(vim.api.nvim_set_hl, 0, FAMILIES[family].prefix .. group, twin))
end

---The group that holds `group` blended at `family`'s strength, computed once.
---
---**A group with no colour of its own gets no twin, and that is the feature.** A caller
---that finds nothing here must draw `group` as it is. That keeps a colorscheme this plugin
---has never seen merely less muted, or merely less faded, instead of wrongly coloured.
---Nothing here reaches for a palette when a lookup is empty, and nothing must.
---
---An empty lookup is not remembered as done. A pass that somehow runs before the theme's
---own groups are linked again costs one more pass, not a review that stays bright until
---the next colorscheme change.
---@param family CRBlendFamily
---@param group string
---@return string|nil name The twin's name, or nil if `group` has nothing to blend.
function M.blended(family, group)
  local known = twins[family]
  if known[group] then
    return known[group]
  end
  if not write_twin(family, group) then
    return nil
  end
  known[group] = FAMILIES[family].prefix .. group
  return known[group]
end

---Write every twin again, against the colorscheme that is active now.
---
---A twin holds colours the theme decides, and `:colorscheme` clears it with every other
---global group. So `apply` writes the twins again wherever it writes the links again. A
---caller that links to a twin needs no part of this: a link holds a name and not a colour,
---and a link inside a highlight namespace survives `:colorscheme`.
---
---Every twin is written again rather than dropped. The diff on screen still carries
---extmarks that name the capture groups the old theme resolved, and those colours must be
---right before anything parses again.
---
---A group that loses its colour to the new theme keeps its twin, as a link back to itself.
---The window then draws that group at full brightness, which is what a group with no twin
---gets. A link that reaches no definition draws nothing at all, so every twin a caller
---already links to must stay a definition -- and a mark already emitted in a twin's name is
---the same case as a namespace linking to one.
local function recolour_twins()
  toward = nil
  for family, known in pairs(twins) do
    for group, twin in pairs(known) do
      if not write_twin(family, group) then
        pcall(vim.api.nvim_set_hl, 0, twin, { link = group })
      end
    end
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
  -- Last, because a twin blends what the links above resolve to. With no review open there
  -- are no twins and this costs one empty loop per family.
  recolour_twins()
end

---Re-link after a colorscheme change, since `nvim_set_hl` definitions are cleared by
---`:colorscheme`. That clears the blended twins too, of both families, so `apply` writes
---them again as well.
function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("CodeReviewHighlights", { clear = true }),
    callback = M.apply,
  })
end

return M
