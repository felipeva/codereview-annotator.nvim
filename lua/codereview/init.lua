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
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return name:sub(1, #lead) == lead
      end, vim.deepcopy(require("codereview.git").CYCLE))
    end,
  })

  vim.api.nvim_create_user_command("CodeReviewAnnotate", function(cmd)
    M.annotate(cmd.args ~= "" and cmd.args or nil)
  end, {
    nargs = "?",
    desc = "Annotate the current file (annotation type, or the picker with none)",
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

---Annotate the file in the current buffer, from anywhere.
---
---The one entry point a host config needs for capture: no review view has to be open, and
---nothing reaches into the queue, annotate or state modules to do it.
---@param type_name string|nil Falls back to the type picker
function M.annotate(type_name)
  require("codereview.capture").annotate(type_name)
end

---Open the queue for review, with drop / route / submit.
function M.queue()
  require("codereview.view").review_queue()
end

---Submit the queued annotations as one batch.
function M.submit()
  require("codereview.view").submit()
end

---@return integer
function M.count()
  return require("codereview.queue").count()
end

---@return boolean
function M.is_open()
  return require("codereview.view").current() ~= nil
end

return M
