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
---The **preamble** is composed here for the same reason the handoff is. It is written at
---the moment the batch goes, it is rendered with the batch, and it is not an **entry** --
---so no queue holds it and no surface is where it belongs either.
---
---Windows are deliberately not its business. It calls the picker and the composer adapters
---and keeps what comes back; putting the editor back where the question was asked is the
---one concession, and only because both answer on a later tick, by which time no caller is
---still on the stack to do it. What a surface then has to repaint is the surface's own
---affair.
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
---The behavior a host with no delivery already had -- the payload reachable, the batch
---still queued -- then falls out of the one rule that empties the queue rather than
---being written down a second time.
---@param payload string
---@param _to table|nil Nothing to route to; the register is where it goes either way
---@return boolean dispatched, string reason
local function to_clipboard(payload, _to)
  vim.fn.setreg("+", payload)
  return false, "No send adapter configured — copied the batch to the + register instead"
end

---Where a batch's `@ref`s resolve against, and which repository it is going out of.
---
---One answer for both, because they are one question asked from two sides: the repository
---is what the archive is keyed on, and it is also what stands in when nothing has been
---routed. A note captured outside a checkout has none.
---@param to table|nil
---@param opts { root?: string }
---@return string base, string|nil repo
local function destination(to, opts)
  local repo = opts.root or git.root(vim.fn.getcwd())
  local root = repo or vim.fn.getcwd()
  -- Resolve refs against the directory the payload is actually going to: a routed agent
  -- reads `@path` relative to its own cwd, not this Neovim's.
  return (to and to.cwd and to.cwd ~= "") and to.cwd or root, repo
end

---The batch as text, against a base already decided.
---
---The one place a batch becomes a payload. Delivering and copying arrive here from
---different sides -- one has already had to ask where the repository is, because that is
---what it archives against, and the other never asks -- and neither may render for itself:
---a payload copied to a register that differs from the one submitted is a copy that
---misrepresents the send it stands in for.
---@param items CRAnnotation[]
---@param base string
---@param opts { preamble?: string, scope_label?: string, files?: integer, reviewed?: integer }
---@return string
local function render_at(items, base, opts)
  return require("codereview.payload").render(items, base, {
    types = config.get().types,
    -- Absent on every path but a submit that composed one. A copy performs no submit, so it
    -- composes nothing and carries nothing, and an **immediate send** is a batch of one with
    -- no batch to cover (ADR-0004) -- both reach this with no preamble in their opts rather
    -- than with a rule of their own saying so.
    preamble = opts.preamble,
    scope_label = opts.scope_label,
    files = opts.files,
    reviewed = opts.reviewed,
  })
end

---What handing this batch over would produce, without handing it over.
---
---Public because a payload is worth reading without spending it. Everything that decides
---what it says -- the target its refs resolve against, the review it describes -- is
---decided here exactly as `deliver` decides it, so the text a reviewer copies is the text
---an agent would have been given.
---@param items CRAnnotation[]
---@param to table|nil Where it would be going, or nil for the adapter's default
---@param opts { root?: string, preamble?: string, scope_label?: string, files?: integer, reviewed?: integer }|nil
---@return string
function M.render(items, to, opts)
  opts = opts or {}
  return render_at(items, destination(to, opts), opts)
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
---@param opts { root?: string, preamble?: string, scope_label?: string, files?: integer, reviewed?: integer }|nil
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
  local base, repo = destination(to, opts)
  local text = render_at(items, base, opts)

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

  -- The same rule doing its second job: a dispatch is what empties the queue, and it is
  -- what records the batch. Everything that is not one has returned above, so a refusal, a
  -- raise and the register the shipped default copies to leave the archive exactly where
  -- they leave the batch. Here rather than in the two callers because a batch and a batch
  -- of one go out through this function and must not diverge on the way (ADR-0004).
  --
  -- The preamble goes into the record through the renderer's own rule, not past it: what is
  -- kept is what the agent was handed, so a batch that rendered no covering note is archived
  -- with none. An **immediate send** and a copy reach neither branch with one.
  require("codereview.state").archive_batch(
    items,
    M.label_of(to),
    repo,
    require("codereview.payload").preamble(opts.preamble)
  )
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
---@param ctx { root?: string, preamble?: string, scope_label?: string, files?: integer, reviewed?: integer }|nil
---       What the review the batch came from can say about itself, when there was one, plus
---       the **preamble** when one was composed for this batch. The preamble arrives here
---       rather than out of the queue because it is not an **entry**: it is written about
---       the batch, at the moment the batch goes.
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

---Put the editor back once a composer has handed control over.
---
---Two concessions of the same kind the picker already makes: windows are not this module's
---business, but a composer answers on a later tick and no caller is still on the stack by
---then. Closing a window does not end insert mode, so a composer submitted from its
---insert-mode mapping leaves focus in the review buffer still inserting -- and that buffer
---is `nomodifiable`, where every navigation key lands as a failed edit instead of a motion.
---A composer the plugin did not ship is under no obligation to put focus back either.
---
---Scheduled rather than immediate: returning from an insert-mode mapping puts Vim straight
---back into insert, and a composer is free to call back before closing its own window.
---@param win integer The window the submit was asked for from
local function restore_editing(win)
  vim.schedule(function()
    if vim.fn.mode():sub(1, 1) == "i" then
      vim.cmd("stopinsert")
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
  end)
end

---Compose a **preamble**, then submit the batch under it.
---
---The fast path costs nothing: this is the ordinary submit with a composer in front of it,
---and the rule behind it is the same one -- a dispatch is what empties the queue, and
---nothing else does (ADR-0005). The flow is here for the reason the submit is: none of it
---is about a window, and both work with nothing open.
---
---An abandoned composer is not a submit. A composer that is dismissed never calls back, so
---nothing is rendered, nothing is handed to the adapter, nothing is archived and the queue
---is exactly where it was -- and what was typed is kept as a **draft** by whichever composer
---collected it, under the key that composer read on the way in.
---
---The preamble never joins the queue. It is composed here, at the moment the batch goes,
---handed to the renderer as one more thing the payload is rendered with, and forgotten. The
---queue keeps **entries** and nothing else, so nothing about its shape or its persistence
---changes.
---@param ctx { root?: string, scope_label?: string, files?: integer, reviewed?: integer }|nil
---       What the review the batch came from can say about itself, exactly as `submit`
---       takes it. The preamble is added to it here.
---@param after fun(dispatched: boolean)|nil Runs once a submit has been made, which an
---       abandoned composer never is. What a surface repaints afterwards is its own affair,
---       and it can no longer do it when this returns: the composer answers on a later tick.
function M.submit_with_preamble(ctx, after)
  local queue = require("codereview.queue")
  ctx = ctx or {}

  -- Asked before the composer opens rather than after it closes, exactly as an immediate
  -- send asks for its target first: there is no covering note worth writing for a batch that
  -- does not exist, and discovering that afterwards would cost what was written.
  ensure_queue()
  local count = queue.count()
  if count == 0 then
    info("Queue is empty — annotate something first")
    return
  end

  -- The repository the batch is going out of, resolved exactly as the batch's own
  -- destination resolves it, so the preamble's draft is filed against the same repository
  -- the archive is keyed on.
  local _, repo = destination(target, ctx)
  local compose_ctx = {
    -- The adapter contract's own field, answered honestly: a preamble carries no separate
    -- context either, and there is no file for `rel_path` or `file_path` to name.
    scope = "none",
    label = ("Preamble · %d annotation%s"):format(count, count == 1 and "" or "s"),
    preamble = true,
    root = repo,
    -- The batch's routing, because a preamble goes exactly where the batch goes. It is the
    -- same footer and the same key an annotation joining the queue gets.
    routing = M.routing(),
    -- Read before anything opens, and handed on: a composer the reviewer dismisses never
    -- calls back, so on that path nothing but the composer can put focus back.
    origin_win = vim.api.nvim_get_current_win(),
  }

  local compose = config.get().compose or require("codereview.composer").open
  -- "submit" is the verb the composer names its submit key with. What that key does here is
  -- exactly what `<C-s>` on the diff does, which is why it is not called anything else.
  compose(compose_ctx, function(_, text)
    restore_editing(compose_ctx.origin_win)

    -- Whatever the composer collected, including nothing at all: the submit key means
    -- submit, and an empty preamble renders nothing, leaving the payload what it was.
    ctx.preamble = text or ""
    local dispatched = M.submit(ctx)

    -- Where a batch that did not go keeps its entries in the queue to be retried, a preamble
    -- has no queue to wait in -- and by now the composer has closed its window, wiped its
    -- buffer and cleared its draft, because a submitted note is not an abandoned one. Same
    -- shape as an undispatched immediate send, and the same reason (ADR-0005): the reviewer
    -- typed it once. The next `<C-a>` reads it back from the key it was written under.
    if not dispatched then
      local drafts = require("codereview.drafts")
      drafts.set(drafts.key(compose_ctx), ctx.preamble)
    end

    if after then
      after(dispatched)
    end
  end, "submit")
end

---Put the payload in the `+` register, deliberately, without submitting the batch.
---
---What the shipped `send` default does as a consequence of nothing being wired, done on
---purpose and whatever is: reading what an agent will be told should not cost a submit,
---and a host with a real adapter otherwise has no way to see it at all.
---
---The queue is untouched, and so is the archive. Not by a rule of its own -- by the one
---this module already holds: a dispatch is a payload handed to the send adapter, a
---register is not a consumer, and nothing here goes near the adapter (ADR-0005). Which is
---also why this is not `deliver` with the send swapped out: that function's whole tail is
---the consequence of a handoff that did not happen.
---@param ctx { root?: string, scope_label?: string, files?: integer, reviewed?: integer }|nil
---       What the review the batch came from can say about itself, exactly as `submit`
---       takes it -- the payload names it in its first line, and a copy that named a
---       different review would not be the text it stands in for.
---@return boolean copied
function M.copy(ctx)
  local queue = require("codereview.queue")

  ensure_queue()
  local count = queue.count()
  if count == 0 then
    -- Submitting's guard, worded the same: an empty queue is an empty queue whichever key
    -- was pressed, and there is no register-shaped consolation to offer for one.
    info("Queue is empty — annotate something first")
    return false
  end

  vim.fn.setreg("+", M.render(queue.all(), target, ctx))
  -- Counted rather than merely acknowledged, because the queue looks the same afterwards:
  -- the number is the only evidence the reviewer gets that it was this batch that went to
  -- the register, and it reads beside "Submitted %d" rather than against it.
  info(("Copied %d annotation%s to the + register"):format(count, count == 1 and "" or "s"))
  return true
end

return M
