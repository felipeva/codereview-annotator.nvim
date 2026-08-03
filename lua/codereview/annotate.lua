---Turning a cursor position into an annotation.
---
---Two rules here are load-bearing, and both exist because an `@path#L20` reference points
---at the file as it is *now*:
---
---  * anything touching a deleted line is inlined as a diff block instead, since the
---    line it names no longer exists and that number now belongs to unrelated code;
---  * a hunk is always inlined, for the same reason -- what changed is the point.
local config = require("codereview.config")
local delivery = require("codereview.delivery")
local queue = require("codereview.queue")
local render = require("codereview.render")
local types = require("codereview.types")

local M = {}

---@param msg string
local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "Code review" })
end

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

---@class CRTarget
---@field file CRFile
---@field file_index integer
---@field kind "line"|"range"|"hunk"|"file"
---@field lines CRLine[]
---@field clamped boolean

---Rows currently selected, or the cursor row in normal mode.
---
---`v` (selection anchor) and `.` (cursor) are read while visual mode is still live: the
---`'<`/`'>` marks are only rewritten when visual mode *exits*, so reading them from a
---mapping would return the previous selection instead of this one.
---@param win integer
---@return integer first, integer last, boolean visual
local function selected_rows(win)
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    return math.min(a, b), math.max(a, b), true
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  return row, row, false
end

---Resolve what the cursor or selection is pointing at.
---@param view CRView
---@return CRTarget|nil
function M.resolve(view)
  local first, last, visual = selected_rows(view.win)
  local anchors = view.render and view.render.anchors
  if not anchors then
    return nil
  end

  -- The anchoring file is the first one the selection actually touches. Rows above the
  -- first real anchor (blank padding) walk upward to find their owner.
  local base
  for row = first, last do
    if anchors[row] then
      base = anchors[row]
      break
    end
  end
  if not base then
    for row = first, 1, -1 do
      if anchors[row] then
        base = anchors[row]
        break
      end
    end
  end
  if not base then
    return nil
  end

  local file = view.files[base.file]
  if not file then
    return nil
  end

  -- Determined up front so every branch reports it. A selection anchored on a file header
  -- still resolves to "this file", but it must not silently swallow the files below it.
  local clamped = false
  for row = first, last do
    local a = anchors[row]
    if a and a.file ~= base.file then
      clamped = true
      break
    end
  end

  --- Whole file: the cursor is on a header, or the file has no annotatable body.
  if base.kind == "file" or base.kind == "sep" or file.binary or #file.hunks == 0 then
    return { file = file, file_index = base.file, kind = "file", lines = {}, clamped = clamped }
  end

  --- Whole hunk: the cursor is on a hunk header, in normal mode.
  if base.kind == "hunk" and not visual then
    local hunk = file.hunks[base.hunk]
    return {
      file = file,
      file_index = base.file,
      kind = "hunk",
      lines = vim.deepcopy(hunk.lines),
      hunk = base.hunk,
      clamped = false,
    }
  end

  --- Lines / range. Rows belonging to another file are dropped: one note cannot honestly
  --- claim to be about two unrelated places.
  local lines = {}
  for row = first, last do
    local a = anchors[row]
    if a and a.kind == "line" and a.file == base.file then
      lines[#lines + 1] = file.hunks[a.hunk].lines[a.line]
    end
  end

  if #lines == 0 then
    -- A selection covering only headers and blank rows still means "this file".
    return { file = file, file_index = base.file, kind = "file", lines = {}, clamped = clamped }
  end

  return {
    file = file,
    file_index = base.file,
    kind = #lines > 1 and "range" or "line",
    lines = lines,
    clamped = clamped,
  }
end

---Diff text for an inlined annotation, with the +/-/space markers restored.
---@param lines CRLine[]
---@return string[]
local function diff_block(lines)
  local out = {}
  for _, ln in ipairs(lines) do
    local sign = ln.side == "add" and "+" or (ln.side == "del" and "-" or " ")
    out[#out + 1] = sign .. ln.text
  end
  return out
end

---Build the queue entry for a target, minus the note text.
---@param view CRView
---@param target CRTarget
---@return CRAnnotation
local function build(view, target)
  local file = target.file
  local entry = {
    kind = target.kind,
    path = file.path,
    abs_path = vim.fs.joinpath(view.root, file.path),
    blob = file.blob,
    inline = false,
  }

  if target.kind == "file" then
    entry.key = render.file_key(file.path)
    entry.tag = file.binary and "binary" or "whole file"
    return entry
  end

  local has_add, has_del = false, false
  for _, ln in ipairs(target.lines) do
    has_add = has_add or ln.side == "add"
    has_del = has_del or ln.side == "del"
  end

  -- Prefer post-image numbers when the target has any; only a pure deletion is described
  -- by pre-image numbers, and mixing the two in one range would be meaningless.
  local nums = {}
  for _, ln in ipairs(target.lines) do
    local n = has_del and not has_add and ln.old or (ln.new or ln.old)
    if n then
      nums[#nums + 1] = n
    end
  end
  table.sort(nums)

  entry.first = nums[1]
  entry.last = nums[#nums]
  entry.key = render.line_key(file.path, target.lines[1])
  entry.inline = has_del or target.kind == "hunk"
  entry.tag = has_del and (has_add and "change" or "deleted") or (target.kind == "hunk" and "change" or nil)
  -- Stored even when `inline` is false. `inline` decides how this normally renders, but a
  -- batch routed to an agent whose cwd does not contain the file cannot use an `@ref` at
  -- all, and the fallback has to inline the exact code rather than approximate it.
  entry.lines = diff_block(target.lines)
  return entry
end

---Human description of a target, for the composer title.
---@param entry CRAnnotation
---@return string
function M.describe(entry)
  -- Nothing to name. Every branch below reads a path, and a bare thought has none, so
  -- without this the composer title and the confirmation both say "nil:nil".
  if entry.kind == "note" then
    return "(no file)"
  end
  -- Outside a checkout there is no repository-relative path, and the absolute one is the
  -- only name the file has.
  local where = entry.path or entry.abs_path
  if entry.kind == "file" then
    return ("%s (%s)"):format(where, entry.tag or "whole file")
  end
  local range = entry.first == entry.last and tostring(entry.first) or ("%d-%d"):format(entry.first, entry.last)
  return entry.tag and ("%s:%s (%s)"):format(where, range, entry.tag) or ("%s:%s"):format(where, range)
end

---Leave insert mode once a composer hands control back.
---
---A floating composer is typically opened with `startinsert` and submitted from an
---insert-mode mapping. Closing its window does not end insert mode, so focus returns to
---the review buffer still in INSERT -- where every navigation key is a failed edit against
---a `nomodifiable` buffer instead of a motion.
---
---Scheduled rather than immediate: returning from an insert-mode mapping can put Vim back
---into insert, which would undo a `stopinsert` issued inline.
local function leave_insert()
  vim.schedule(function()
    if vim.fn.mode():sub(1, 1) == "i" then
      vim.cmd("stopinsert")
    end
  end)
end

---Put focus back in the window an annotation was started from.
---
---Closing a floating composer hands focus to whichever window Neovim recorded last, and
---falls through to the *first* window in the tab when that one has since been closed. A
---composer that opened a picker while it was up -- an `@file` reference, a change of
---target -- is precisely that case, and the first window is the tree. So the diff only ever
---kept focus by luck; this is the plugin asserting it instead.
---
---Scheduled rather than immediate: a composer is free to call back before closing its own
---window, and focusing inline would leave that close to re-run the very fallback this
---exists to defeat.
---
---Never constructive. With the original window gone the review's diff will do -- but only
---when it is in the tab the user is looking at, because dragging them into a different one
---is worse than leaving them where they landed.
---@param win integer
local function restore_focus(win)
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      return
    end
    local V = require("codereview.view").current()
    if V and vim.api.nvim_win_get_tabpage(V.win) == vim.api.nvim_get_current_tabpage() then
      vim.api.nvim_set_current_win(V.win)
    end
  end)
end

---Collect note text, through the injected composer when one is wired.
---@param ctx table
---@param label string
---@param cb fun(text: string)
local function collect(ctx, label, cb)
  local cfg = config.get()
  -- Read before anything opens: this is the window that asked for the composer -- the diff
  -- on the review path, an ordinary buffer's window on the capture one.
  local origin = vim.api.nvim_get_current_win()
  -- Handed on rather than kept private. A composer the user dismisses never calls back, so
  -- there is no path on which the plugin could restore focus itself, and only the composer
  -- can -- which it cannot do without being told where the annotation came from. Stamped
  -- here and not by the caller, so the window the composer is told about and the window
  -- focus returns to cannot drift into being two different windows.
  ctx.origin_win = origin

  ---Runs whether or not a note came back. A composer submitted from an insert-mode mapping
  ---leaks insert mode either way, and a note abandoned halfway should still leave the
  ---cursor where it was started from.
  ---@param text string|nil
  local function done(text)
    leave_insert()
    restore_focus(origin)
    if text and vim.trim(text) ~= "" then
      cb(vim.trim(text))
    end
  end

  -- The plugin's own composer is the *default implementation of the adapter*, not a lesser
  -- path beside it: a host that injects one replaces it, and both are handed exactly the
  -- same thing. There is no third behaviour to keep in step.
  local compose = cfg.compose or require("codereview.composer").open
  compose(ctx, function(_, text)
    done(text)
  end, label)
end

---Annotate whatever the cursor or selection points at.
---@param type_name string
function M.annotate(type_name)
  local view = require("codereview.view")
  local V = view.current()
  if not V then
    return
  end

  local cfg = config.get()
  local type_def = types.get(cfg.types, type_name)
  if not type_def then
    warn(("unknown annotation type: %s"):format(type_name))
    return
  end

  local target = M.resolve(V)
  if not target then
    warn("nothing to annotate here")
    return
  end

  -- Leave visual mode before the composer opens; the selection has already been read.
  if vim.fn.mode():match("[vV\22]") then
    vim.cmd("normal! \27")
  end

  M.annotate_target(V, target, type_def.name)
end

---Offer the configured types, plus an explicit way to decline one.
---
---Declining is an entry in the menu rather than a second meaning for dismissing it. The
---picker's only non-selection outcome is cancel, and cancel abandons the annotation
---outright, so reusing it would make "no type" indistinguishable from "never mind".
---
---Shared by the review path and by buffer capture, which offered the same menu twice.
---@param list CRType[]
---@param cb fun(type_def: CRType|nil) Untyped when nil; not called at all if dismissed
function M.pick_type(list, cb)
  local labels = vim.tbl_map(function(t)
    return ("%s  %s"):format(t.icon, t.name)
  end, list)
  -- Appended, so every configured type keeps the position a reviewer already reaches for.
  labels[#labels + 1] = ("%s  no type"):format(types.UNTYPED.icon)

  vim.ui.select(labels, { prompt = "Annotation type:" }, function(_, index)
    if not index then
      return
    end
    -- One past the type list is the decline entry, where `list[index]` is nil: an untyped
    -- annotation, which is not the dismissal above and must not be answered like one.
    cb(list[index])
  end)
end

---Pick the type from a menu, then annotate.
function M.annotate_pick()
  -- The selection has to be read before vim.ui.select steals the mode, so resolve the
  -- target first and hand the already-resolved type to the normal path.
  local V = require("codereview.view").current()
  if not V then
    return
  end
  local target = M.resolve(V)
  if not target then
    warn("nothing to annotate here")
    return
  end

  M.pick_type(config.get().types, function(type_def)
    M.annotate_target(V, target, type_def and type_def.name)
  end)
end

---The note as it reaches an entry: what was written, plus whatever rides along under it.
---@param text string
---@param opts { note_suffix?: string }|nil
---@return string
local function note_with(text, opts)
  local suffix = opts and opts.note_suffix
  return (suffix and suffix ~= "") and (text .. "\n\n" .. suffix) or text
end

---The composer context both tails hand over.
---@param entry CRAnnotation
---@param type_def CRType|nil nil for an untyped annotation
---@param routing table|nil What the composer's footer names and its routing key changes.
---       Absent for a note joining the queue, which is routed by the batch it joins.
---@return table
local function compose_ctx(entry, type_def, routing)
  -- The untyped group stands in wherever the annotation still has to be named.
  local type_label = (type_def or types.UNTYPED).label
  return {
    scope = "none",
    label = ("%s · %s"):format(type_label:gsub("s$", ""), M.describe(entry)),
    rel_path = entry.path,
    file_path = entry.abs_path,
    routing = routing,
  }
end

---Collect a note for an already-built entry, queue it, and report.
---
---Shared by the review path and by buffer capture, rather than each growing its own tail:
---an annotation has to be indistinguishable once queued regardless of how it was
---captured, and that is only true if one piece of code decides the composer context, the
---persistence call, the wording of the confirmation and where focus lands afterwards.
---@param entry CRAnnotation
---@param type_def CRType|nil nil for an untyped annotation
---@param opts? { note_suffix?: string } Appended below the collected note. Buffer capture
---       uses it to carry diagnostics; the review path has nothing to add.
function M.queue_entry(entry, type_def, opts)
  -- Left unset rather than stamped with a sentinel, so anything asking an entry which type
  -- it carries gets the honest answer -- and so no configurable name can ever collide with
  -- one the plugin reserved.
  entry.type = type_def and type_def.name
  -- Before anything is added, not after: persisting writes the in-memory queue over the
  -- document, so queueing into a queue this session has never read back would drop
  -- whatever the last session left. A review view has already restored by the time it
  -- gets here; capture from a buffer can be the very first thing a session does.
  local staled = require("codereview.state").ensure_queue()
  if staled > 0 then
    -- Said before the composer opens, in the queue's own wording: which path happened to
    -- read the queue back is not something a reviewer should be able to hear.
    info(queue.stale_phrase(staled))
  end
  collect(compose_ctx(entry, type_def), "queue", function(text)
    entry.note = note_with(text, opts)
    queue.add(entry)
    local view = require("codereview.view")
    view.paint()
    view.persist()
    info(("Queued %s %s (%d in queue)"):format(entry.type or "untyped", M.describe(entry), queue.count()))
  end)
end

---Collect a note for an already-built entry and deliver it on its own.
---
---The queued path's twin, and deliberately the same shape: the same composer context, the
---same note suffix, the same focus restore. What differs is the tail -- this one renders a
---batch of one through the payload renderer (ADR-0004) and hands it to the send adapter,
---never touching the queue. An errand does not disturb a batch you are still assembling.
---@param entry CRAnnotation
---@param type_def CRType|nil nil for an untyped annotation. The reason a type became
---       optional at all (ADR-0004): a batch of one must not be the one interaction that
---       forces a type onto a remark that carries no instruction.
---@param opts? { note_suffix?: string }
function M.send_entry(entry, type_def, opts)
  entry.type = type_def and type_def.name

  -- Said the same way from both places the absence can be discovered: before the composer
  -- opens, and from the routing key once it is.
  local NO_PICKER = "No pick_target adapter configured — sending to the default target"

  ---Where this one note goes. Held here rather than in the view because it belongs to the
  ---note: an errand must not redirect the batch you are still assembling.
  ---@type table|nil
  local to = nil

  ---What the composer names in its footer and changes with its routing key. The batch's
  ---equivalent is `delivery.routing()`; this is the same shape for a note that owns its own
  ---destination, which is what lets one composer tell the truth on both paths.
  local routing = {
    label = function()
      return delivery.label_of(to)
    end,
    pick = function(on_done)
      local asked = delivery.choose_target(function(picked)
        -- Declining a reroute is "never mind", not "send it nowhere". The note is written
        -- by now, and dropping the target it already had would redirect it in the one
        -- direction nobody asked for.
        if picked then
          to = picked
        end
        if on_done then
          on_done()
        end
      end)
      if not asked then
        info(NO_PICKER)
      end
    end,
  }

  local function compose_and_send()
    collect(compose_ctx(entry, type_def, routing), "send", function(text)
      entry.note = note_with(text, opts)
      -- No context to hand over: this note was captured from a buffer, so there is no
      -- review whose root and scope the payload could describe.
      --
      -- Confirmed only on a dispatch, which is the rule a batch submits under. A send
      -- that did not go has already said why; saying it was sent on top of that is the
      -- one thing that would lose the note in silence.
      if delivery.deliver({ entry }, to) then
        info(
          ("Sent %s %s to %s"):format(
            entry.type or "untyped",
            M.describe(entry),
            to and (to.short or "agent") or "local"
          )
        )
      end
    end)
  end

  -- Asked before the composer opens, not after it closes: declining then costs nothing,
  -- where declining after the note is written costs the note.
  local asked = delivery.choose_target(function(picked)
    -- A picker that ran and came back empty is a reviewer who chose not to send. Said out
    -- loud, because a note that goes nowhere in silence looks exactly like one that was
    -- delivered.
    if not picked then
      warn("No target chosen — nothing sent")
      return
    end
    to = picked
    compose_and_send()
  end)
  -- Nothing to choose between, and no way to decline. The plugin has no opinion about
  -- where a payload goes (ADR-0001), so it hands this one over with no target and lets
  -- the send adapter decide what that means, exactly as a batch does.
  if not asked then
    info(NO_PICKER)
    compose_and_send()
  end
end

---Annotate a target that was resolved earlier.
---@param V CRView
---@param target CRTarget
---@param type_name string|nil nil annotates without a type
function M.annotate_target(V, target, type_name)
  local type_def = type_name and types.get(config.get().types, type_name)
  if type_name and not type_def then
    return
  end
  if target.clamped then
    info(("Selection spans more than one file — clamped to %s"):format(target.file.path))
  end
  M.queue_entry(build(V, target), type_def)
end

---Drop the annotation the cursor is sitting on.
function M.drop()
  local view = require("codereview.view")
  local V = view.current()
  if not V then
    return
  end
  local anchor, row = view.anchor_at_cursor()
  if not anchor then
    return
  end

  local file = V.files[anchor.file]
  local key
  if anchor.kind == "line" then
    key = render.line_key(file.path, file.hunks[anchor.hunk].lines[anchor.line])
  else
    key = render.file_key(file.path)
  end

  local at = queue.at(key)
  if #at == 0 then
    info("No annotation on this line")
    return
  end
  -- Most recent first: dropping is nearly always undoing what you just wrote.
  local removed = queue.remove(at[#at].id)
  view.paint()
  view.persist()
  if removed then
    info(("Dropped %s note (%d left)"):format(removed.type or "untyped", queue.count()))
  end
end

return M
