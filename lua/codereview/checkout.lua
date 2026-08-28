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
    require("codereview.view").open(nil, path)
  end)
end

return M
