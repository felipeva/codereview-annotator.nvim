---Where a batch is going, and how that choice is made.
---
---Routing is a property of the batch, not of whichever window asked. Holding it here is
---what lets the winbar, the queue float and the composer all name the same choice without
---any of them loading a review view to read it -- and what lets it be chosen at all with
---nothing open.
---
---Windows are deliberately not its business. It calls the picker adapter and keeps what
---comes back; putting focus back where the question was asked is the one concession, and
---only because the picker answers on a later tick, by which time no caller is still on the
---stack to do it. What a surface then has to repaint is the surface's own affair.
local config = require("codereview.config")

local M = {}

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

---Where the next batch goes, or nil for the adapter's default.
---
---Module-level for the reason the queue is: it describes what you are submitting to, not
---what you are looking at. Held on the view, choosing a target with nothing open ran the
---picker and discarded the answer, and the batch went to the default having just asked.
---
---Deliberately not persisted. The queue is worth keeping across a restart; a target
---identifies a live destination -- a herdr pane id, say -- and restoring a dead one would
---route a batch into nothing, which is worse than asking again.
---@type table|nil
local target = nil

---The batch's target, as the send adapter is handed it.
---@return table|nil
function M.target()
  return target
end

---Short name for a target, or what to call the adapter's own default.
---
---One wording for every piece of chrome that names a destination -- the winbar, the queue
---float, and a composer footer whichever choice it is naming.
---@param to table|nil
---@return string
function M.label_of(to)
  return (to and to.short) or "local"
end

---Short name of where the batch is going.
---@return string
function M.target_label()
  return M.label_of(target)
end

---The batch's routing, in the shape a composer is handed.
---
---What a note joining the queue is routed by, and so the composer's default. An immediate
---send supplies its own instead, because that note has a target of its own.
---@return { label: fun(): string, pick: fun(on_done: fun()|nil) }
function M.routing()
  return { label = M.target_label, pick = M.pick_target }
end

---Ask the host where something should go, holding focus where the question was asked.
---
---Says nothing about *what* is being routed: the batch's target is one caller, a single
---note being sent on its own is another, and neither should have to reimplement the focus
---dance around an asynchronous picker to have its own answer.
---@param cb fun(picked: table|nil) nil is a decline, which every caller reads its own way
---@return boolean asked false when no picker adapter is wired, so nothing was asked
function M.choose_target(cb)
  local cfg = config.get()
  if not cfg.pick_target then
    return false
  end

  -- Return focus to whichever window asked, not to whatever the picker last left current.
  -- Picking a target from the queue float used to dump the cursor into the diff buffer,
  -- where `<C-s>` hits the main buffer's mapping -- which submits but leaves the float open
  -- behind it.
  local return_win = vim.api.nvim_get_current_win()

  cfg.pick_target(function(picked)
    if vim.api.nvim_win_is_valid(return_win) then
      vim.api.nvim_set_current_win(return_win)
    end
    cb(picked)
  end)
  return true
end

---Choose where the batch goes, through the injected picker.
---@param on_done fun()|nil Runs after a target is chosen, once the picker has closed
function M.pick_target(on_done)
  local asked = M.choose_target(function(picked)
    -- Recorded before any surface is touched. This used to return early with no view, which
    -- meant the picker ran, the user answered, and the answer was dropped.
    target = picked
    -- The picker is asynchronous, so anything that has to reflect the new target has to be
    -- driven from here; running it after `pick_target` returns repaints too early.
    if on_done then
      on_done()
    end
  end)
  if not asked then
    info("No pick_target adapter configured — submitting locally")
  end
end

return M
