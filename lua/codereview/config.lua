---Configuration and adapter injection.
---
---The three adapters (`send`, `pick_target`, `compose`) are what keep this plugin
---distributable. With none of them wired it still renders, annotates and queues -- only
---delivery degrades to a fallback. A host config injects its own Claude/herdr plumbing
---rather than the plugin hardcoding any.
local M = {}

M.defaults = {
  --- Diff ---
  context = 3, ---@type integer Lines of context passed to `git diff -U`
  untracked = true, ---@type boolean Include untracked files in branch/worktree scopes

  --- Syntax ---
  syntax = true, ---@type boolean Harvest treesitter highlights for expanded files
  max_syntax_bytes = 256 * 1024, ---@type integer Skip syntax above this size

  --- UI ---
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
  ---@type fun(payload: string, target: table|nil)|nil
  send = nil,
  ---Choose a delivery target, calling back with it (or nil for the default).
  ---@type fun(cb: fun(target: table|nil))|nil
  pick_target = nil,
  ---Collect note text. Falls back to `vim.ui.input` when not wired.
  ---@type fun(ctx: table, on_accept: fun(target: table|nil, text: string), label: string)|nil
  compose = nil,
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

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
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
