---codereview-annotator.nvim
---
---A unified, syntax-highlighted diff view with typed annotations that queue up and get
---submitted as one batch. Delivery is injected (`opts.send`), so the plugin carries no
---opinion about which agent or transport receives a review.
local config = require("codereview.config")

local M = {}

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  require("codereview.hl").setup()

  vim.api.nvim_create_user_command("CodeReview", function(cmd)
    M.open(cmd.args ~= "" and cmd.args or nil)
  end, {
    nargs = "?",
    desc = "Open the code review view (scope name or any git revspec)",
    -- Every named scope, unconditionally -- including `since-batch` in a repository with an
    -- empty archive, which answers with a sentence. Completion says what exists; whether
    -- there is anything to show is the scope's own answer to give.
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return name:sub(1, #lead) == lead
      end, vim.deepcopy(require("codereview.git").SCOPES))
    end,
  })

  -- Takes no arguments and needs no review open: the batch it copies is the one the queue
  -- holds, which is the same batch wherever it is asked for.
  vim.api.nvim_create_user_command("CodeReviewCopy", M.copy, {
    desc = "Copy the queued batch to the + register, without submitting it",
  })

  -- A command as well as `gS`, because a **switch** has to work with no review open --
  -- which is how a reviewer opens a review in another **checkout** in the first place --
  -- and keys exist only inside a review.
  vim.api.nvim_create_user_command("CodeReviewSwitch", M.switch, {
    desc = "Switch the review to another checkout of this repository",
  })

  -- No key of its own, and that is the design rather than an omission: the previous
  -- **checkout** is the first entry |:CodeReviewSwitch| offers, so going back already has a
  -- gesture. A command, for the reason the switch is one -- it has to work with no review
  -- open.
  vim.api.nvim_create_user_command("CodeReviewBack", M.back, {
    desc = "Go back to the checkout the review came from",
  })

  -- Takes no arguments and needs no review open, for the reason the copy above does not:
  -- the batch it reads back has already gone, so nothing about the current window could
  -- change which one went last.
  vim.api.nvim_create_user_command("CodeReviewLastBatch", M.last_batch, {
    desc = "Read the last dispatched batch back: its annotations, where it went and when",
  })

  vim.api.nvim_create_user_command("CodeReviewAnnotate", function(cmd)
    -- `cmd.range` counts the addresses given, not the lines covered. Reading line1/line2
    -- unconditionally would turn a bare `:CodeReviewAnnotate` into a one-line capture of
    -- wherever the cursor happened to be, instead of the whole file.
    local range = cmd.range > 0 and { first = cmd.line1, last = cmd.line2 } or nil
    M.annotate(cmd.args ~= "" and cmd.args or nil, range)
  end, {
    nargs = "?",
    range = true,
    desc = "Annotate the current file, or a given range (type, or the picker with none)",
    -- Completed from the configured list, not the built-in five: a host that replaced the
    -- vocabulary would otherwise be offered types that no longer exist.
    complete = function(lead)
      local names = {}
      for _, t in ipairs(config.get().types) do
        if t.name:sub(1, #lead) == lead then
          names[#names + 1] = t.name
        end
      end
      return names
    end,
  })
end

---@param spec string|nil "branch"|"staged"|"unstaged"|"worktree"|any git revspec
function M.open(spec)
  require("codereview.view").open(spec)
end

function M.close()
  require("codereview.view").close()
end

---**Switch** the review to another **checkout** of this repository.
---
---Works with no review open, which is how a reviewer opens a review somewhere else in the
---first place: opening with nothing already open is simply the case with nothing to close
---first, and there is no second entry point for it.
---
---The list is built from git's own worktree listing and put in front of the reviewer by the
---`pick_checkout` adapter, whose default the plugin ships (ADR-0007).
function M.switch()
  require("codereview.checkout").switch()
end

---Go back to the **checkout** the review came from.
---
---The same journey a **switch** makes, with the destination taken from where the reviewer
---has been rather than asked for. There is no forward beside it: the checkout just left is
---the first entry the picker offers, so going forward again is the same single keystroke.
---
---Checkouts that no longer exist are walked over and named. One that is still there and
---declines to open -- an agent worktree whose branch has been merged has an empty branch
---scope -- is left on the trail rather than spent, because nothing here could give it back.
---
---The trail lives for the session and is never written to disk. It is navigation history,
---not review state.
function M.back()
  require("codereview.checkout").back()
end

---Annotate the file in the current buffer, from anywhere.
---
---The one entry point a host config needs for capture: no review view has to be open, and
---nothing reaches into the queue, annotate or state modules to do it.
---With a visual selection live, captures those lines; otherwise the whole file.
---@param type_name string|nil Falls back to the type picker
---@param range { first: integer, last: integer }|nil Explicit lines, overriding both
---@param opts { immediate?: boolean }|nil `immediate` delivers this one annotation on its
---       own instead of queueing it -- see `codereview-immediate-send`
function M.annotate(type_name, range, opts)
  require("codereview.capture").annotate(type_name, range, opts)
end

---Open the queue for review, with drop / route / submit.
function M.queue()
  require("codereview.view").review_queue()
end

---Submit the queued annotations as one batch.
function M.submit()
  require("codereview.view").submit()
end

---Copy the batch to the `+` register, without submitting it.
---
---Reads the payload rather than spending it: the queue keeps every entry, nothing is
---handed to the `send` adapter and nothing is archived. Through the view, as submitting
---is, so what is copied describes the open review when there is one.
function M.copy()
  require("codereview.view").copy()
end

---Read the last dispatched batch back: its annotations, where it went and when.
---
---Read-only. An archived entry records something that happened, so nothing in it can be
---dropped, edited or resubmitted -- re-raising a point means annotating again. Opens with
---no review view, as the queue float does: a batch is not a window.
function M.last_batch()
  require("codereview.archive").open()
end

---How many annotations are queued for the **checkout** being reviewed -- the number a
---statusline shows.
---
---The review's own checkout when one is open, and the one the caller is standing in
---otherwise, which is `current_checkout`'s answer and not a second reading of the question.
---After a **switch** those are different checkouts, and the review's is the right one: the
---number beside a diff has to be about the diff.
---
---Cheap by contract, because a statusline asks it on every redraw. With a review open it is
---a field read and two table lengths and touches git not at all; with none open it is a
---working-directory read, a memoised resolution and the same two lengths, and the git
---process behind that resolution is spawned once per checkout ever seen.
---
---Reports what the queue *holds* for that checkout, not what its store holds. A checkout
---nothing has read back yet counts 0 until a capture, submit, copy, switch or queue float
---restores it; reading a state file per redraw is the cost this number has never paid.
---@return integer
function M.count()
  return require("codereview.queue").count_for(require("codereview.state").current_checkout())
end

---@return boolean
function M.is_open()
  return require("codereview.view").current() ~= nil
end

return M
