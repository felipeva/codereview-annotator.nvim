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
end

---@param spec string|nil "branch"|"staged"|"unstaged"|"worktree"|any git revspec
function M.open(spec)
  require("codereview.view").open(spec)
end

function M.close()
  require("codereview.view").close()
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
