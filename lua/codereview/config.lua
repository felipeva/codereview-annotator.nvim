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
  ---Emphasise the characters that differ inside a deletion and its replacement, so the eye
  ---lands on the change instead of on the line. On by default: it is a refinement of a
  ---rendering everyone already has rather than a mode to opt into, and it is what every
  ---comparable review tool does. It lengthens opening a large review by roughly a third and
  ---a repaint by nothing at all, because the work is done once per git read.
  spans = true, ---@type boolean
  panel = {
    enabled = true,
    width = 34,
    position = "left", ---@type "left"|"right"
  },
  icons = {
    reviewed = "✓",
    annotated = "●",
    unreviewed = "○",
    collapsed = "▸",
    expanded = "▾",
    change_bar = "▌",
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
  return types.normalise(options.types or types.defaults, { icon = options.icons.annotated })
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

---Reject a `spans` value that is not a boolean.
---
---In the same voice as a bad layout, and for the same reason: `spans = "off"` is truthy,
---so a mistyped switch would silently leave the feature on with nothing on screen saying
---why.
---@param spans any
local function validate_spans(spans)
  if type(spans) ~= "boolean" then
    error(("codereview.setup: `spans` must be a boolean — got %s"):format(vim.inspect(spans)), 0)
  end
end

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  validate_layout(M.options.layout)
  validate_spans(M.options.spans)
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

return M
