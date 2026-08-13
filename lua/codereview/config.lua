---Configuration and adapter injection.
---
---The adapters (`send`, `pick_target`, `pick_file`, `compose`, `open_diff`) are what keep
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

return M
