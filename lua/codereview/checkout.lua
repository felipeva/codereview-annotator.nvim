---Moving the review from one **checkout** to another.
---
---A **switch** is one operation: open the review against a chosen checkout. Opening with
---nothing already open is simply the case with nothing to close first, which is how a
---reviewer opens a review somewhere else in the first place — so this works with no review
---on screen and there is no second door for that.
---
---The split between what the plugin knows and what the **host** does is ADR-0007's. What a
---checkout *is* is the plugin's own knowledge, from `git worktree list`, and it does not
---move under this the way the agent tooling behind ADR-0001 does. How a list is put in
---front of a reviewer is the host's, through a `pick_checkout` adapter whose default
---implementation the plugin ships — ADR-0003's shape, where the shipped one is handed
---exactly what a host's is handed, and not `pick_file`'s, where the plugin ships nothing.
---
---Nothing here changes a directory. The review's root is what everything resolves against
---(ADR-0008); the `:tcd` the view sets on the new tab is for the host alone, and the global
---working directory is never touched, which is what guarantees a reviewer can always reach
---the checkout Neovim started in.
local config = require("codereview.config")
local git = require("codereview.git")

local M = {}

---@param msg string
local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "Code review" })
end

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

--- The trail back ---------------------------------------------------------------

---The **checkouts** the reviewer has been in, most recent first, and never the one they
---are in now.
---
---Module-level, and that is the whole of its lifetime: it is navigation history rather than
---review state, and persisting it would resurrect a path through checkouts that may no
---longer exist. Nothing writes it to disk and nothing reads it back.
---
---It has no term in the glossary and no surface of its own, deliberately -- a reviewer
---never handles it. What they see of it is the order the picker offers, which is this
---order: going back is then the first entry of the list they already know rather than a
---second gesture to learn, and going forward again is the same single keystroke, which is
---why there is no forward.
---@type string[]
local trail = {}

---Take a checkout out of the trail, wherever it is.
---@param path string
local function forget(path)
  for i = #trail, 1, -1 do
    if trail[i] == path then
      table.remove(trail, i)
    end
  end
end

---Open the review on a checkout, and record the journey only if it opened.
---
---Both halves are load-bearing and neither is obvious.
---
---**Only if it opened.** `view.open` declines an empty scope, an unresolvable one and a
---failed diff, and it declines each of them *before* it closes anything -- the review the
---reviewer was reading is still on screen. A push made on the switch rather than on the
---open would then name a checkout they never left, which is the one they are standing in:
---the picker would offer the row marked `(current)` first and going back would go nowhere.
---
---**The checkout arrived at leaves the trail.** Removing it here rather than
---de-duplicating the push is what keeps the trail to where the reviewer has *been*. De-
---duplicating alone holds each checkout once as well, and still leaves the checkout they
---are standing in in the trail, ranked above one they have never opened. It also makes a
---push impossible to duplicate, since a checkout can only be pushed by being left and can
---only be left after being entered here.
---
---Reopening the checkout the review is already on is a legitimate thing to ask the picker
---for, and it must leave the trail alone: it is not a journey.
---@param path string
---@return boolean opened `view.open` has already said why it did not
local function enter(path)
  -- Before the open, which replaces the review this reads from.
  local from = require("codereview.state").current_checkout()
  local opened = require("codereview.view").open(nil, path)

  -- The sweep of **orphaned** state, #178's, moved here from the pick callback when these
  -- two slices met. Its own reasoning is unchanged and is what puts it at this line rather
  -- than another: a switch is the moment a checkout's existence is most likely to have just
  -- changed, it is rare and nowhere near a hot path -- so no startup scan and no timer --
  -- and it runs **after** the open so a line reporting work destroyed is the last thing
  -- said rather than the first thing buried under the review's own sentences.
  --
  -- What the move buys is `:CodeReviewBack`. A switch is a switch whichever door it came
  -- through -- the glossary's **Switch** has no clause about the gesture -- and going back
  -- is the door most likely to arrive at a checkout that has just stopped existing, being
  -- the only one in the plugin that already tests for a gone directory. Left in the pick
  -- callback it was the one switch that never swept.
  --
  -- Before the failure return, not after it, so the picker path behaves exactly as it did
  -- when it lived one function out: a switch the *plugin* refused swept then and sweeps
  -- now. A picker the reviewer dismissed still never reaches this at all -- declining a
  -- menu is not a switch.
  require("codereview.state").sweep_orphans()

  if not opened then
    return false
  end
  forget(path)
  if from and from ~= path then
    table.insert(trail, 1, from)
  end
  return true
end

---The listing, ordered by the trail: where the reviewer has been, most recent first, then
---everything else in the order git named it.
---
---A permutation of what it was handed and never an addition to it. A checkout offered twice
---would answer with a row the reviewer did not believe they were choosing.
---@param checkouts CRCheckout[]
---@return CRCheckout[]
local function in_trail_order(checkouts)
  local rank = {}
  for i, path in ipairs(trail) do
    rank[path] = i
  end

  local been, rest = {}, {}
  for _, checkout in ipairs(checkouts) do
    if rank[checkout.path] then
      been[#been + 1] = checkout
    else
      rest[#rest + 1] = checkout
    end
  end
  table.sort(been, function(a, b)
    return rank[a.path] < rank[b.path]
  end)
  return vim.list_extend(been, rest)
end

---What was walked over on the way back, named.
---
---By full path rather than by the directory name the picker leads with. The picker can
---afford the short name because it draws the branch beside it and the reviewer is choosing
---from a list they can see; a line about a checkout that is gone has neither, and two
---worktrees under different parents can share a name.
---
---One line rather than one notification per checkout: going back over three pruned agent
---worktrees would otherwise be three warnings in a row, which is a worse answer than the
---silence the naming exists to prevent.
---@param paths string[]
---@return string
local function skipped_line(paths)
  if #paths == 1 then
    return ("Skipped a checkout that no longer exists: %s"):format(paths[1])
  end
  return ("Skipped %d checkouts that no longer exist: %s"):format(#paths, table.concat(paths, ", "))
end

---One row of the picker, as the reviewer reads it.
---
---The directory's own name first, because that is what a reviewer named the checkout when
---they created it and it is what they are looking for. The branch beside it, because two
---checkouts of one repository differ by branch and by nothing else a list can show. The
---checkout being reviewed right now is marked rather than left out: a list whose shape
---changes with where you are standing is harder to read, and reopening where you are is a
---legitimate thing to ask for.
---@param checkout CRCheckout
---@return string
function M.label(checkout)
  return ("%s  %s%s"):format(
    vim.fn.fnamemodify(checkout.path, ":t"),
    checkout.branch or "detached",
    checkout.current and "  (current)" or ""
  )
end

---The picker the plugin ships: the default implementation of the `pick_checkout` adapter.
---
---Through `vim.ui.select`, which is the surface every configuration has already replaced or
---kept deliberately — the same door the annotation type picker asks through. It answers
---with a path rather than with a row, so a host adapter is free to offer a checkout that
---was never in the list it was handed. That is what ADR-0007 defers cross-repository
---listing to.
---@param checkouts CRCheckout[]
---@param on_choice fun(path: string|nil) nil when the reviewer chose nothing
function M.pick(checkouts, on_choice)
  vim.ui.select(checkouts, {
    prompt = "Switch the review to:",
    format_item = M.label,
  }, function(chosen)
    on_choice(chosen and chosen.path or nil)
  end)
end

---Switch the review to another checkout of this repository.
---
---The list is built from the checkout the plugin is already acting on, which is the
---review's own when one is open. A reviewer who has switched once is offered the checkouts
---of the repository they are *looking at*, not of the one they happen to be standing in —
---the two are the same repository here, and asking the review is what keeps that true
---rather than coincidental.
function M.switch()
  local root = require("codereview.state").current_checkout()
  if not root then
    warn("not inside a git repository")
    return
  end

  local checkouts = git.checkouts(root)

  -- **A review whose checkout was deleted underneath it can still be left.**
  --
  -- The listing is built by asking git from the checkout the plugin is acting on, and that
  -- is exactly the directory that went: `vim.system` raises on a cwd that is not there, so
  -- the answer is an empty list and the reviewer is told no checkout can be opened. With
  -- `:CodeReview` resolving through the same question, a switch is the only way out of such
  -- a review -- so the one gesture that must keep working is the one a deletion took away.
  --
  -- Asked again from the *global* working directory, which is the checkout Neovim started
  -- in: it is never moved (ADR-0008), which is the whole of why a reviewer can always get
  -- back to where they began. Strictly the repository it lists is the one the reviewer is
  -- standing in rather than the one the dead review was of. Nothing can list the latter --
  -- a linked checkout's git directory is reached through the directory that is gone -- and
  -- in the case this exists for the two are the same repository anyway.
  --
  -- Gated on the checkout being gone, not merely on an empty list. An empty list from a
  -- checkout that is *there* means git named nothing openable in that repository, and
  -- answering that with another repository's checkouts would be the cross-repository
  -- listing #171 rules out.
  if #checkouts == 0 and (vim.uv.fs_stat(root) or {}).type ~= "directory" then
    checkouts = git.checkouts(vim.fn.getcwd(-1, -1))
  end

  if #checkouts == 0 then
    -- Reachable only when git listed nothing this plugin could open: every checkout it
    -- named was bare, or gone, or unresolvable. Said rather than opening an empty picker,
    -- which would leave a reviewer pressing keys at a list that can never answer.
    warn("no checkout of this repository can be opened")
    return
  end

  -- Ordered here, as a step of its own after the listing has been settled: the checkout
  -- the reviewer came from is the first row, which is what makes going back the gesture
  -- they already have.
  checkouts = in_trail_order(checkouts)

  -- The shipped picker is the *default implementation* of the adapter, not a lesser path
  -- beside it (ADR-0003): both are handed the same list and both answer the same way.
  local pick = config.get().pick_checkout or M.pick
  pick(checkouts, function(path)
    -- A picker the reviewer dismissed. Nothing has moved, and nothing is said: declining a
    -- menu is not an error.
    if not path then
      return
    end
    -- The branch scope, as `:CodeReview` with no argument opens. Carrying the current
    -- review's scope across would be wrong rather than convenient: a revspec resolved in
    -- one checkout need not exist in another, and `since-batch` names the archive of the
    -- checkout being left. Which scope a checkout was last reviewed at is #175's.
    -- The sweep of **orphaned** state (#178) is inside `enter`, which is why it is not
    -- here: it belongs to the journey and not to this door onto it.
    enter(path)
  end)
end

---Go back along the trail, to the **checkout** the reviewer came from.
---
---The same journey a switch makes, with the destination chosen for them instead of asked
---for -- so there is nothing here that a switch does not also do, and nothing to learn
---beyond which key it is on.
---
---A checkout whose directory is gone is walked over and named. A checkout that is *there*
---and declines to open is not: it is left exactly where it is on the trail, because the
---reviewer has not been anywhere and a trail entry once consumed cannot be got back --
---there is no forward. An agent worktree whose branch has been merged has an empty branch
---scope and declines, which makes this the ordinary case rather than the exotic one.
---
---Walking over entries always terminates, because the trail is finite and every skip takes
---one entry off it. Not because the checkout Neovim started in is protected: it reaches the
---trail by being left, like any other, and its directory can be deleted like any other. So
---the bottom of the trail is reachable, and being there is said rather than left as a press
---that does nothing.
function M.back()
  local skipped, landed = {}, false

  ---Name what was walked over, and only once however often this is reached.
  ---
  ---Said *before* the open rather than after this function has finished, so that the sweep
  ---the open ends in keeps the last word. #178 puts a line about destroyed work last on
  ---purpose, and reporting the walk afterwards would have buried it -- the one thing the
  ---move of that sweep into `enter` changed about it.
  local function say_skipped()
    if #skipped > 0 then
      warn(skipped_line(skipped))
      skipped = {}
    end
  end

  while #trail > 0 do
    local path = trail[1]
    if (vim.uv.fs_stat(path) or {}).type ~= "directory" then
      table.remove(trail, 1)
      skipped[#skipped + 1] = path
    else
      say_skipped()
      -- `enter` takes it off the trail itself, and only once the open has succeeded.
      landed = enter(path)
      break
    end
  end

  say_skipped()
  -- Nothing was refused and there is nothing left: said, for the reason an empty listing is
  -- said rather than opened as an empty picker. A refusal has already spoken for itself and
  -- has left its checkout on the trail, so it is not this.
  if not landed and #trail == 0 then
    info("No checkout to go back to")
  end
end

return M
