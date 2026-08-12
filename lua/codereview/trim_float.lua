---The commits on the branch, read from inside the review.
---
---A module of its own, in the shape of `queue_float.lua`: a float needs a buffer, a window
---and keys, and none of the review view's mutable state. The repository to ask about is
---handed in as a plain string, so nothing here reads the view -- which is what keeps this
---module out of the cycle `view` and `annotate` already sit in.
---
---**Nothing here picks a row yet.** When a key that acts on one arrives it arrives the way
---the queue float's keys did: the view hands itself in and the float runs its exported
---actions, rather than requiring `view` for them.
---
---What a row carries is the short sha, the subject and the relative date. Not the author --
---you are reading your own branch. Not the added and deleted counts -- they cost a second
---pass over the whole branch to fill, and the subject is what a reviewer recognises.
local git = require("codereview.git")
local render = require("codereview.render")

local M = {}

---@param msg string
local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "Code review" })
end

--- Rendering the commits as rows -------------------------------------------------

---Extmarks belonging to this float, in a namespace of its own so clearing them cannot
---disturb the diff's, the tree's or the queue float's.
local NS_TRIM = vim.api.nvim_create_namespace("codereview_trim")

---One column to the left of every row, reserved so that marking the row a trim starts at
---costs no realignment of everything beside it. Nothing draws in it yet.
local GUTTER = " "

---Two spaces between the sha and the subject, and at least two between the subject and the
---date, so the three read as three columns rather than as one sentence.
local GAP = "  "

---Turn the commits into the float's rows.
---
---The subject keeps the buffer's own colour, which is the brightest thing this float has,
---for the reason the **sticky header** leaves the path in the bar's own group: the sha and
---the date are what a row is found by, and the subject is what it is read for.
---
---Its highlight columns are byte offsets, not display columns -- a subject is free to be
---any width in either ruler, and the two part company at the first accented character.
---@param commits CRCommit[]
---@param width integer Columns the float has to draw into
---@return { lines: string[], marks: table[] }
local function build(commits, width)
  local lines, marks = {}, {}
  -- Padded to the widest sha in the listing. git abbreviates to whatever the repository
  -- needs, and it needs more of them on a big one, so the column cannot be assumed.
  local sha_width = 0
  for _, commit in ipairs(commits) do
    sha_width = math.max(sha_width, #commit.sha)
  end
  local indent = #GUTTER + sha_width + #GAP
  local body = math.max(8, width - indent - #GUTTER)

  for _, commit in ipairs(commits) do
    local when = commit.when or ""
    local room = body - (when ~= "" and vim.fn.strdisplaywidth(when) + #GAP or 0)
    local subject = render.truncate(commit.subject, math.max(8, room))
    local head = GUTTER .. ("%-" .. sha_width .. "s"):format(commit.sha) .. GAP .. subject
    if when ~= "" then
      head = head .. (" "):rep(math.max(#GAP, room - vim.fn.strdisplaywidth(subject) + #GAP)) .. when
    end

    lines[#lines + 1] = head
    local row = #lines - 1
    marks[#marks + 1] = {
      row = row,
      col = #GUTTER,
      opts = { end_col = #GUTTER + #commit.sha, hl_group = "CodeReviewQueueIndex" },
    }
    if when ~= "" then
      marks[#marks + 1] = {
        row = row,
        col = #head - #when,
        opts = { end_col = #head, hl_group = "CodeReviewQueueState" },
      }
    end
  end

  return { lines = lines, marks = marks }
end

--- The float --------------------------------------------------------------------

---List the commits on the branch, newest first.
---
---Refuses rather than opening onto one unusable row: a branch whose `HEAD` is the merge
---base has done no work of its own, which is an ordinary state and not a failure, and a
---float holding nothing a reviewer can act on would leave them wondering which of the two
---had gone wrong.
---@param root string The repository the branch belongs to
function M.open(root)
  local commits, err = git.branch_commits(root)
  if not commits then
    info(err or "could not read the commits on this branch")
    return
  end
  if #commits == 0 then
    info("This branch has no commits of its own — its HEAD is the merge base")
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(100, math.max(50, math.floor(vim.o.columns * 0.8)))
  local height = math.min(28, math.max(10, math.floor(vim.o.lines * 0.7)))
  local n = #commits
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = (" Commits on this branch · %d commit%s "):format(n, n == 1 and "" or "s"),
    title_pos = "center",
    -- Only what works. A key that is not built is not advertised: a footer offering one is
    -- a promise the float cannot keep.
    footer = " q close ",
    footer_pos = "center",
  })
  -- The rows are fitted to a width they know, so that every one of them stays one row.
  -- Letting the window wrap instead would fold a long subject onto a second line, where a
  -- reviewer counting rows against commits would find one too many.
  vim.wo[win].wrap = false

  local painted = build(commits, vim.api.nvim_win_get_width(win))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, painted.lines)
  vim.bo[buf].modifiable = false
  for _, m in ipairs(painted.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS_TRIM, m.row, m.col, m.opts)
  end

  -- The cursor opens on the newest commit, which is where a fresh window puts it and where
  -- the row a reviewer wants nearly always is -- so reading this list costs no movement.
  -- Nothing places it here, because there is nothing yet that would want it elsewhere.

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close the commit list" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Close the commit list" })
end

return M
