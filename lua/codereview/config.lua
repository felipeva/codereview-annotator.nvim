---Configuration and adapter injection.
---
---The adapters (`send`, `pick_target`, `pick_file`, `compose`, `open_diff`,
---`pick_checkout`) are what keep
---this plugin distributable. With none of them wired it still renders, annotates and
---queues -- the payload just reaches the `+` register instead of an agent, the batch stays
---queued because nothing consumed it, and `gd` is bound to nothing. A host config injects
---its own Claude/herdr plumbing rather than the plugin hardcoding any.
local M = {}

M.defaults = {
  --- Diff ---
  context = 3, ---@type integer Lines of context passed to `git diff -U`
  untracked = true, ---@type boolean Include untracked files in branch/worktree scopes

  --- Syntax ---
  syntax = true, ---@type boolean Harvest treesitter highlights for expanded files
  max_syntax_bytes = 256 * 1024, ---@type integer Skip syntax above this size

  --- UI ---
  ---How the review view arranges a diff. `unified` stacks deleted and added lines in one
  ---column; `split` draws the before-image and the after-image as two panes side by side.
  ---Unified is the default, so upgrading the plugin does not change how a review looks.
  layout = "unified", ---@type "unified"|"split"
  ---Emphasize the characters that differ inside a deletion and its replacement, so the eye
  ---lands on the change instead of on the line. On by default: it is a refinement of a
  ---rendering everyone already has rather than a mode to opt into, and it is what every
  ---comparable review tool does. It lengthens opening a large review by roughly a third and
  ---a repaint by nothing at all, because the work is done once per git read.
  spans = true, ---@type boolean
  ---Fold a line too wide for its window onto further rows -- **wrap** -- rather than making
  ---the reviewer scroll sideways to read it. The rows are the window's and never the diff's:
  ---nothing is added to the buffer, so every **anchor**, every row an annotation hangs on and
  ---every count stay what they were.
  ---
  ---Said of the **unified** layout only. A **split** layout stays unwrapped, because two
  ---**panes** that fold by different amounts stop being row-aligned on screen, and row
  ---alignment is what split exists for. The **file tree** never folds either.
  ---
  ---Off by default, and the precedent it follows is the layout's rather than the spans': a
  ---reviewer with a terminal wide enough for their code has no problem to solve, and
  ---upgrading the plugin should not re-draw their review.
  wrap = false, ---@type boolean
  ---Draw one file -- the file being read -- and none of the others: **solo**. A reviewer
  ---working through thirty changed files otherwise loses track of which one they are in,
  ---because the diff is one continuous expanse and nothing in it says where a file ends.
  ---They move through the review file by file, with the file keys they already have: `]f`
  ---and `[f`, `]F` and `[F`, `<C-p>`, and the **file tree**'s own open action.
  ---
  ---A rendering choice and never a **scope**. The review goes on covering everything its
  ---scope covers, so the file tree lists every file with its reviewed marks and its note
  ---counts, the review summary counts every file in the scope rather than the one on
  ---screen, and the **queue**, the **archive** and the **payload** are what they were. No
  ---**entry** records that solo was on, so which file was being read never reaches the
  ---receiving agent. This is ADR-0009.
  ---
  ---Orthogonal to `layout`, which is why it is not a third value of one: a **split** diff
  ---can be soloed and is then the same one file in both **panes**, still row-aligned.
  ---
  ---Off by default, on wrap's precedent rather than the spans': a reviewer who does
  ---nothing sees the review they already had, and upgrading the plugin does not re-draw
  ---it.
  solo = false, ---@type boolean
  ---Draw **archived** entries on the diff, dimmed, beneath the code they were about. A
  ---reviewer who keeps working while an agent does is otherwise looking at a review view
  ---with no memory of what it already sent, and reports the same finding twice. Every
  ---scope, not only `since-batch`: what has already been said is worth knowing wherever
  ---you are.
  ---
  ---Each of them says whether its file has been **touched** since its batch went, and the
  ---winbar tallies how many have not.
  ---
  ---On by default, and coarse on purpose -- off is the whole archive off: nothing drawn,
  ---nothing tallied, no git spent judging, and the diff renders exactly as it did before
  ---the archive existed. `gA` overrides this while a session lasts, in both directions, and
  ---never writes here -- see `M.archived` below.
  archived = true, ---@type boolean
  ---Draw every **pane** that does not have focus **muted**: its colors pulled toward the
  ---background, so the pane with focus is the bright one and a reviewer never has to press
  ---a key to find out where they are. Every pane goes on lighting the row its cursor is on;
  ---which color a muted one lights it in is `counterpart` below.
  ---
  ---**The file tree is never muted, and its row stays lit.** The tree is the map of the
  ---review, and a muted map is harder to read for nothing in return: a tree looks nothing
  ---like a diff, so no color is needed to tell the two apart. Focus landing in the tree
  ---still mutes the panes, so the rule above stays true of them.
  ---
  ---On by default, and coarse the way `archived` is: off is nothing muted, nothing
  ---computed and no highlight namespace attached to any window, for a reviewer whose own
  ---dimming plugin or own taste should win. There is no keymap beside it; one can be added
  ---if the switch proves too blunt.
  ---
  ---`strength` is how far toward the background a color is pulled, from 0 (not at all) to
  ---1 (all the way). One number rather than a palette, because the colors it works on are
  ---the active colorscheme's -- an unrecognized theme is muted in its own colors or, for a
  ---group the plugin cannot know about, left bright rather than replaced.
  muted = { enabled = true, strength = 0.5 }, ---@type { enabled: boolean, strength: number }
  ---Draw every file except the one the cursor is in **faded**: the colors of its rows
  ---pulled toward the background, so the file being read has a visible boundary and the
  ---file just left stops competing with it. The unit is the file and never the hunk, so a
  ---cursor moving from one hunk to the next inside one file changes nothing on screen.
  ---
  ---A faded file keeps its header row bright, and its hunk headers fade with its body: the
  ---header is the one row that names the file, and this exists to help a reviewer find a
  ---place rather than to hide the map.
  ---
  ---On by default, and coarse the way `muted` is: off is nothing emitted, no color
  ---computed, and the diff drawn exactly as it was before this existed. There is no keymap
  ---beside it.
  ---
  ---`strength` is its own, and deliberately gentler than `muted.strength`: the fade covers
  ---every file but one, where the window rule covers the panes a reviewer is not in, and a
  ---blend that reads as quiet over a pane reads as washed out over a whole review. Both
  ---numbers pull the active colorscheme's own colors, so an unrecognized theme fades in
  ---its own colors or, for a group the plugin cannot know about, stays bright.
  faded = { enabled = true, strength = 0.35 }, ---@type { enabled: boolean, strength: number }
  ---Light the row the cursor is on in a **muted** pane as well -- the **counterpart row** --
  ---in a group of its own rather than in the one the pane with focus uses. A reviewer
  ---reading the after pane can then see which line of the before-image sits opposite the
  ---line they are on, and where the opposite row is a **filler** the lit blank row is what
  ---says nothing existed there before. That case is the whole reason this exists: the panes
  ---are cursorbound, so on a paired line the reviewer could have counted rows, and on a pure
  ---addition there is no row to count to.
  ---
  ---Which row is lit stays Neovim's business, because the panes are cursorbound. Only which
  ---color it is lit in is this. Nothing is emitted onto the diff and no extmark is added.
  ---
  ---On by default, and coarse the way `muted` is: off is a lit row in the pane with focus
  ---only -- nothing computed, and no group of its own defined -- which is what a review
  ---looked like before this existed.
  ---
  ---`strength` is deliberately gentler than `muted.strength`. The counterpart row has to
  ---stay visible inside a window everything else in it is being pulled toward the
  ---background, and it must still read as secondary to the row the pane with focus lights.
  counterpart = { enabled = true, strength = 0.25 }, ---@type { enabled: boolean, strength: number }
  panel = {
    enabled = true,
    width = 34,
    position = "left", ---@type "left"|"right"
  },
  ---Every glyph the plugin draws, in one place. All plain Unicode: nothing here needs a
  ---Nerd Font, and nothing added here may.
  ---
  ---The **sticky header** spends three of them on the three counts it carries -- reviewed,
  ---notes and untouched -- so that three numbers side by side cannot be read as one another.
  ---The first two are the icons a file already carries, because the same glyph says the same
  ---thing in both places.
  icons = {
    reviewed = "✓",
    annotated = "●",
    unreviewed = "○",
    collapsed = "▸",
    expanded = "▾",
    change_bar = "▌",
    untouched = "↺",
    ---What a continuation row of a folded line carries where the change bar would be.
    ---Neither the bar nor the line number repeats there, and their absence is worth
    ---explaining rather than merely noticing.
    continuation = "↳",
  },

  --- Annotations ---
  ---Replaces the default set outright. Only `name` and `key` are required per type;
  ---`label`, `icon` and `hl` are derived from the name, and `directive` is optional.
  types = nil, ---@type CRType[]|nil Defaults to types.defaults

  --- Adapters (all optional) ---
  ---Deliver a rendered payload. `target` is whatever `pick_target` produced, or nil.
  ---
  ---Report whether the payload was *handed off*, not whether it arrived (ADR-0005):
  ---return nothing or `true` for dispatched, `false` and a reason for not. Raising is a
  ---non-dispatch too, with the error message as the reason. Only a dispatch empties the
  ---queue, so an adapter that says no leaves the batch to be retried -- and leaves an
  ---immediate send's note as a draft, which is the only place a batch of one can wait.
  ---
  ---Replaces the clipboard copy the plugin ships, which is the default implementation of
  ---this same contract rather than a fallback beside it: it is handed the same arguments
  ---and reports a non-dispatch, because a register is not a consumer.
  ---@type (fun(payload: string, target: table|nil): boolean?, string?)|nil
  send = nil,
  ---Choose a delivery target, calling back with it (or nil for the default).
  ---@type fun(cb: fun(target: table|nil))|nil
  pick_target = nil,
  ---Choose a file to reference from inside the composer, calling back with it. The plugin
  ---ships no picker -- every config already has one -- so without this `@` stays a literal
  ---`@`. `first`/`last` are optional: a picker that cannot select lines omits them, and the
  ---reference is then to the file rather than to a range in it.
  ---@type fun(cb: fun(chosen: { path: string, first: integer?, last: integer? }|nil))|nil
  pick_file = nil,
  ---Collect note text. Replaces the composer the plugin ships, which is the default
  ---implementation of this same contract rather than a fallback beside it -- both are
  ---handed exactly the same arguments.
  ---
  ---`ctx` carries `scope`, `label`, `rel_path`, `file_path` and `origin_win` -- the window
  ---the annotation was started from. The plugin restores focus there once `on_accept`
  ---runs; a composer that can be dismissed without calling it owns that path itself.
  ---
  ---On an immediate send it also carries `routing`: `{ label(), pick(on_done) }` for the
  ---target *this note* will reach. Name it in the chrome, and change it with `pick`. It is
  ---absent for a note joining the queue, which is routed by the batch it joins.
  ---@type fun(ctx: table, on_accept: fun(target: table|nil, text: string), label: string)|nil
  compose = nil,
  ---Read one file in whatever diff tool the host already has -- `DiffviewOpen`, a
  ---`:Gdiffsplit`, its own `diffthis` pair. The plugin ships none of that and keeps no
  ---opinion about it; it hands over the file and the two refs its scope is between.
  ---
  ---`path` is absolute, and the post-image path -- for a rename the pre-image lives
  ---elsewhere in `before`. `after` is nil for the scopes whose post-image is the working
  ---tree, which the adapter must handle: nil means "the file on disk", not an error.
  ---`line` is nil when the file was named from the file tree, which knows a file and no
  ---position in it.
  ---
  ---Bound to `gd` only while this is wired -- a key that silently did nothing would be
  ---worse than no key. Nothing the host opens has an anchor map, so it is a read-only
  ---detour: you cannot annotate in there.
  ---@type fun(spec: { path: string, before: string, after: string|nil, line: integer|nil })|nil
  open_diff = nil,
  ---Choose which **checkout** to move the review to, calling back with its path. Replaces
  ---the picker the plugin ships, which is the default implementation of this same contract
  ---rather than a fallback beside it (ADR-0007, on ADR-0003's shape) -- both are handed the
  ---same list and both answer the same way.
  ---
  ---`checkouts` is every checkout of the current repository the plugin could open: the main
  ---clone and each linked worktree, each carrying `path` (absolute and resolved), `branch`
  ---(nil when detached) and `current`. Bare repositories and checkouts whose directory is
  ---gone are already out of it.
  ---
  ---**Answer with a path, not with a row.** The list is a convenience and not a
  ---restriction: an adapter is free to offer a checkout that was never in it, which is what
  ---reviewing a checkout of a *different* repository needs until cross-repository listing
  ---exists. Call back with nil for "none of them", which is not an error and is not
  ---reported.
  ---@type fun(checkouts: CRCheckout[], cb: fun(chosen: string|nil))|nil
  pick_checkout = nil,
}

---@type table
M.options = vim.deepcopy(M.defaults)

---Validate the configured type list and fill in what it left out.
---
---Done once, here, rather than defensively at each of the dozen places a type is read. A
---list that is wrong should fail at `setup()` naming the entry that caused it, not later
---as a nil `label` in the composer or as a keymap that silently shadows another.
---@param options table
---@return CRType[]
local function resolve_types(options)
  local types = require("codereview.types")
  return types.normalize(options.types or types.defaults, { icon = options.icons.annotated })
end

---Reject a layout the render has no rendering for.
---
---Loudly, at `setup()`, in the same voice as a bad type list: a mistyped `layout` that
---silently fell back to unified would leave a reviewer wondering why their configuration
---did nothing, and the answer would be nowhere on screen.
---@param layout any
local function validate_layout(layout)
  if not vim.tbl_contains(require("codereview.render").LAYOUTS, layout) then
    error(
      ("codereview.setup: unknown `layout` %s — expected one of %s"):format(
        vim.inspect(layout),
        table.concat(
          vim.tbl_map(function(name)
            return ("%q"):format(name)
          end, require("codereview.render").LAYOUTS),
          ", "
        )
      ),
      0
    )
  end
end

---Reject a switch that is not a boolean.
---
---In the same voice as a bad layout, and for the same reason: `spans = "off"` is truthy, so
---a mistyped switch would silently leave the feature on with nothing on screen saying why.
---Named rather than one function per switch, because the reason is the same one every time
---and two copies of it would be two chances to word it differently.
---@param name string
---@param value any
local function validate_boolean(name, value)
  if type(value) ~= "boolean" then
    error(("codereview.setup: `%s` must be a boolean — got %s"):format(name, vim.inspect(value)), 0)
  end
end

---Reject a switch with a strength beside it written as a bare boolean.
---
---`spans` and `archived` are bare booleans while `muted`, `faded` and `counterpart` are
---tables, so `muted = false` is the natural mistake to make. Without this it is an index
---error raised from inside a window helper the next time a review opens, rather than a
---sentence at `setup()` naming the line to change. Named for the switch it is checking,
---because two copies of this sentence would be two chances to word it differently.
---@param name string
---@param value any
local function validate_blend(name, value)
  if type(value) ~= "table" then
    error(
      ("codereview.setup: `%s` must be a table — got %s; write `%s = { enabled = false }`"):format(
        name,
        vim.inspect(value),
        name
      ),
      0
    )
  end
end

---Reject a strength that is not a fraction of the way to the background.
---
---In the same voice as the switches above. A number outside 0..1 is not a stronger effect
---but an arithmetic accident: past 1 the blend overshoots the background and comes back out
---the other side, which is a color nobody asked for rather than a louder version of one.
---@param name string
---@param value any
local function validate_strength(name, value)
  if type(value) ~= "number" or value < 0 or value > 1 then
    error(("codereview.setup: `%s` must be a number between 0 and 1 — got %s"):format(name, vim.inspect(value)), 0)
  end
end

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  validate_layout(M.options.layout)
  validate_boolean("spans", M.options.spans)
  validate_boolean("wrap", M.options.wrap)
  validate_boolean("solo", M.options.solo)
  validate_boolean("archived", M.options.archived)
  validate_blend("muted", M.options.muted)
  validate_boolean("muted.enabled", M.options.muted.enabled)
  validate_strength("muted.strength", M.options.muted.strength)
  validate_blend("faded", M.options.faded)
  validate_boolean("faded.enabled", M.options.faded.enabled)
  validate_strength("faded.strength", M.options.faded.strength)
  validate_blend("counterpart", M.options.counterpart)
  validate_boolean("counterpart.enabled", M.options.counterpart.enabled)
  validate_strength("counterpart.strength", M.options.counterpart.strength)
  M.options.types = resolve_types(M.options)
  return M.options
end

---@return table
function M.get()
  if not M.options.types then
    M.options.types = resolve_types(M.options)
  end
  return M.options
end

--- The archived switch at runtime ----------------------------------------------

---What `gA` has said about **archived** entries, for the rest of this editing session.
---
---Beside the configured value rather than written over it. A key that edited `M.options`
---would leave a host's own `setup()` call describing something that is no longer true, and
---a reviewer reading their configuration back would be told the wrong thing by the file
---they wrote themselves.
---
---Module-level rather than on the review view, because the choice has to outlive one: a
---reviewer who pressed the key once is not quietly put back by opening the next review.
---Deliberately not persisted either, for the reason the chosen **layout** is not -- a
---display preference must never become durable state a reviewer has forgotten they set.
---A module local lasts exactly as long as it should: until Neovim exits, after which
---configuration decides again.
---@type boolean|nil nil until the key has been pressed, when configuration decides
local archived_override = nil

---Whether **archived** entries are drawn, tallied and judged at all.
---
---Read wherever the flag itself is read. Unset means the configured value, which is what
---makes `setup()` the answer at the start of every session.
---@return boolean
function M.archived()
  if archived_override == nil then
    return M.get().archived
  end
  return archived_override
end

---Turn archived entries on or off for the rest of this editing session.
---
---Both directions from wherever the switch stands now, so a reviewer whose configuration
---has them off can turn them on.
---@return boolean on Whether they are now drawn
function M.toggle_archived()
  archived_override = not M.archived()
  return archived_override
end

--- The wrap switch at runtime --------------------------------------------------

---What `gw` has said about **wrap**, for the rest of this editing session.
---
---The archived flag's arrangement above, copied rather than generalised: two module locals
---and four short functions read as what they are, where one indirection over a table of
---overrides would have to be understood before either switch could be.
---
---Deliberately not persisted, and for a sharper reason than the layout's. Wrap answers a
---question about how wide *this terminal is right now*. A **scope** is kept per **checkout**
---because it says what the review is; wrap says no such thing, and a choice made about one
---terminal size restored into a different one tomorrow is a worse answer than no memory at
---all.
---@type boolean|nil nil until the key has been pressed, when configuration decides
local wrap_override = nil

---Whether a line too wide for its window is folded onto further rows.
---
---Read on every paint, which is what makes the switch re-decide rather than remember:
---moving to the **split** layout unwraps because split does not fold, and moving back folds
---again because nothing about the choice changed.
---@return boolean
function M.wrap()
  if wrap_override == nil then
    return M.get().wrap
  end
  return wrap_override
end

---Fold long lines, or stop folding them, for the rest of this editing session.
---
---Both directions from wherever the switch stands now, so a reviewer whose configuration
---has wrap on can turn it off.
---@return boolean on Whether lines are now folded
function M.toggle_wrap()
  wrap_override = not M.wrap()
  return wrap_override
end

--- The solo switch at runtime --------------------------------------------------

---What `go` has said about **solo**, for the rest of this editing session.
---
---The third copy of the arrangement above, and copied again rather than generalised: three
---module locals and six short functions each read as what they are, where one indirection
---over a table of overrides would have to be understood before any of the three could be.
---
---Not persisted, for the reason the two above are not and one of its own. A **scope** is
---kept per **checkout** because it says what the review *is*; solo says how one sitting is
---being read, and an afternoon's way of reading restored into a different afternoon is a
---worse answer than no memory at all (ADR-0009).
---@type boolean|nil nil until the key has been pressed, when configuration decides
local solo_override = nil

---Whether the **review view** draws one file and none of the others.
---
---Read on every paint, which is what makes the switch re-decide rather than remember: a
---**layout** toggle, a re-read from git and a **scope** change each ask again and each get
---the answer the reviewer last gave.
---@return boolean
function M.solo()
  if solo_override == nil then
    return M.get().solo
  end
  return solo_override
end

---Draw one file, or every file, for the rest of this editing session.
---
---Both directions from wherever the switch stands now, so a reviewer whose configuration
---has solo on can turn it off.
---@return boolean on Whether one file is now drawn
function M.toggle_solo()
  solo_override = not M.solo()
  return solo_override
end

return M
