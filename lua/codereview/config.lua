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

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if not M.options.types then
    M.options.types = require("codereview.types").defaults
  end
  return M.options
end

---@return table
function M.get()
  if not M.options.types then
    M.options.types = require("codereview.types").defaults
  end
  return M.options
end

return M
