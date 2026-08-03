---Where a batch is going, how that choice is made, and what is handed over when it goes.
---
---Routing is a property of the batch, not of whichever window asked. Holding it here is
---what lets the winbar, the queue float and the composer all name the same choice without
---any of them loading a review view to read it -- and what lets it be chosen at all with
---nothing open.
---
---The handoff is here for the same reason. A batch and a batch of one go out the same way
---(ADR-0004), and the batch of one has no review view behind it at all; with the renderer
---sitting on the view, sending a single note meant loading the whole review surface to
---reach it.
---
---And the submit, which is what holds the rule the other two serve: restore the queue,
---deliver it, and empty it only if the send reports it went (ADR-0005).
---
---Windows are deliberately not its business. It calls the picker adapter and keeps what
---comes back; putting focus back where the question was asked is the one concession, and
---only because the picker answers on a later tick, by which time no caller is still on the
---stack to do it. What a surface then has to repaint is the surface's own affair.
local config = require("codereview.config")
local git = require("codereview.git")

local M = {}

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

---Say that a payload did not go, at the level that says whose problem it is.
---
---The rule that empties the queue has no branch in it and must not grow one. How loudly a
---non-dispatch is said is a different question, and it does: an adapter that refused or
---broke is a failure a reviewer has to act on, because something was written and nothing
---received it. No adapter wired at all is a configuration state with the payload sitting
---in the register, and saying that in red would cry wolf about the plugin's own default.
---@param message string
function M.report_undelivered(message)
  local level = config.get().send and vim.log.levels.ERROR or vim.log.levels.WARN
  vim.notify(message, level, { title = "Code review" })
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

---The default implementation of the `send` contract, and not a fallback beside it.
---
---ADR-0003 settled this shape for the composer; this is the same idea applied to
---delivery. It is handed exactly what a host adapter is handed and answers through
---exactly the same return, so there is always a send and nothing anywhere has to ask
---whether one is wired.
---
---It reports a non-dispatch because that is the truth: a register is not a consumer.
---The behaviour a host with no delivery already had -- the payload reachable, the batch
---still queued -- then falls out of the one rule that empties the queue rather than
---being written down a second time.
---@param payload string
---@param _to table|nil Nothing to route to; the register is where it goes either way
---@return boolean dispatched, string reason
local function to_clipboard(payload, _to)
  vim.fn.setreg("+", payload)
  return false, "No send adapter configured — copied the batch to the + register instead"
end

---Render annotations as one payload and hand it to the send adapter.
---
---Shared with the immediate send, which is a batch of one (ADR-0004): one renderer and
---one delivery, rather than a second output shape that could drift from this one.
---
---Everything it renders with is handed to it, the repository root included. It used to
---read that off the current review view, which is how a function that has no business
---knowing about views ended up depending on one being open.
---@param items CRAnnotation[]
---@param to table|nil Where it is going, or nil for whatever the adapter defaults to
---@param opts { root?: string, scope_label?: string, files?: integer, reviewed?: integer }|nil
---       `root` is the review's, when there is one. Without it the working directory's
---       repository stands in, which is the only answer available to a caller -- buffer
---       capture sending a single note -- that never had a review behind it.
---@return boolean dispatched false when the send said it did not go, or raised trying
---@return string|nil reason Always set on a non-dispatch. Returned rather than announced
---       here, because what a caller has to add to it differs: a batch is still queued and
---       says so by still being counted, while a batch of one has to say where its note
---       went instead.
function M.deliver(items, to, opts)
  local cfg = config.get()
  opts = opts or {}
  local root = opts.root or (git.root(vim.fn.getcwd()) or vim.fn.getcwd())
  -- Resolve refs against the directory the payload is actually going to: a routed agent
  -- reads `@path` relative to its own cwd, not this Neovim's.
  local base = (to and to.cwd and to.cwd ~= "") and to.cwd or root

  local text = require("codereview.payload").render(items, base, {
    types = cfg.types,
    scope_label = opts.scope_label,
    files = opts.files,
    reviewed = opts.reviewed,
  })

  -- A raise is a non-dispatch, not a crash. A missing binary raises rather than returning
  -- anything -- that is how the process API answers -- and letting it unwind would take
  -- the queue's one rule with it: the batch used to survive only because the error jumped
  -- past the line that clears it, and the reviewer read a traceback where a sentence
  -- belongs.
  local ok, first, second = pcall(cfg.send or to_clipboard, text, to)
  local dispatched, reason = first, second
  if not ok then
    dispatched, reason = false, ("Send adapter failed: %s"):format(first)
  end

  -- Only an explicit `false` is a refusal: every adapter wired today returns nothing at
  -- all, and nothing has to keep meaning it went. What "went" means is deliberately
  -- narrow -- handed off, not arrived (ADR-0005).
  if dispatched == false then
    -- Given a sentence of its own when the adapter did not bother with one, so that every
    -- caller can put the reason in a message without checking whether there is one.
    return false, reason or "The send adapter reported it did not deliver"
  end
  return true
end

---Read the persisted queue back if this session has not, and say what came back stale.
---
---The latch belongs to persistence, which owns the stores it reads and answers with a
---count. What is owed here is the sentence: submitting can be the first thing a session
---does, and a batch has to be the one on disk before it can be the one that goes.
local function ensure_queue()
  local staled = require("codereview.state").ensure_queue()
  if staled > 0 then
    info(require("codereview.queue").stale_phrase(staled))
  end
end

---Submit the queue as one batch, emptying it only if the send says it went.
---
---The rule this module exists to hold: a dispatch is what empties the queue, and nothing
---else does. Not a raise, not an adapter that declined, not the register the shipped
---default copies to -- each of those leaves the batch exactly where it was, to be retried
---without a note being typed twice and with a count that still describes what is there.
---
---Here rather than on the review view because a batch is not a window. It can be
---submitted with nothing open, and what remains the view's share of this is closing the
---float that was listing the batch and repainting the diff behind it.
---@param ctx { root?: string, scope_label?: string, files?: integer, reviewed?: integer }|nil
---       What the review the batch came from can say about itself, when there was one.
---@return boolean dispatched
function M.submit(ctx)
  local queue = require("codereview.queue")
  ctx = ctx or {}

  ensure_queue()
  local count = queue.count()
  if count == 0 then
    info("Queue is empty — annotate something first")
    return false
  end

  local dispatched, reason = M.deliver(queue.all(), target, ctx)
  if not dispatched then
    -- Nothing more to add: the batch is still queued, and a queue that still counts what
    -- it holds is how a reviewer sees that for themselves.
    M.report_undelivered(reason)
    return false
  end
  queue.clear()

  -- Written whether or not a review is open: a batch submitted with none still has to
  -- put the emptied queue on disk, or the entries it just sent come back on the next
  -- start. The queue alone rather than the whole document, because submitting changes
  -- nothing about the reviewed marks stored beside it.
  local state = require("codereview.state")
  state.persist_queue(ctx.root or state.ambient_root())

  info(
    ("Submitted %d annotation%s to %s"):format(
      count,
      count == 1 and "" or "s",
      target and (target.short or "agent") or "local"
    )
  )
  return true
end

return M
