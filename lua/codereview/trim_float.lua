---The commits on the branch, read from inside the review, and the **trim** picked off them.
---
---A module of its own, in the shape of `queue_float.lua`: a float needs a buffer, a window
---and keys, and none of the review view's mutable state. What it acts through is handed in
----- the view module for the one action `<CR>` runs, and the repository and the commit the
---branch starts at as plain values -- so nothing here reads the view, which is what keeps
---this module out of the cycle `view` and `annotate` already sit in.
---
---What a row carries is the short sha, the subject and the relative date. Not the author --
---you are reading your own branch. Not the added and deleted counts -- they cost a second
---pass over the whole branch to fill, and the subject is what a reviewer recognizes.
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

---One column to the left of every row, where the row the current **trim** starts at is
---called out. Blank on every other row, so nothing beside it moves when one is marked.
local GUTTER = " "

---What that column holds on the row the review currently starts at.
local MARK = "▸"

---Two spaces between the sha and the subject, and at least two between the subject and the
---date, so the three read as three columns rather than as one sentence.
local GAP = "  "

---The top row, which removes the trim.
---
---Above the commits rather than below them: it is the state a review opens in, and a
---reviewer widening a long branch back out should not have to walk to the bottom to do it.
local ALL = "All commits"

---Turn the commits into the float's rows.
---
---The subject keeps the buffer's own color, which is the brightest thing this float has,
---for the reason the **sticky header** leaves the path in the bar's own group: the sha and
---the date are what a row is found by, and the subject is what it is read for.
---
---Its highlight columns are byte offsets, not display columns -- a subject is free to be
---any width in either ruler, and the two part company at the first accented character.
---@param commits CRCommit[]
---@param width integer Columns the float has to draw into
---@param at integer Which commit the review starts at; 0 for none, which is `ALL`
---@return { lines: string[], marks: table[] }
local function build(commits, width, at)
  local lines, marks = { GUTTER .. ALL }, {}
  -- Padded to the widest sha in the listing. git abbreviates to whatever the repository
  -- needs, and it needs more of them on a big one, so the column cannot be assumed.
  local sha_width = 0
  for _, commit in ipairs(commits) do
    sha_width = math.max(sha_width, #commit.sha)
  end
  local indent = #GUTTER + sha_width + #GAP
  local body = math.max(8, width - indent - #GUTTER)

  for i, commit in ipairs(commits) do
    local when = commit.when or ""
    local room = body - (when ~= "" and vim.fn.strdisplaywidth(when) + #GAP or 0)
    local subject = render.truncate(commit.subject, math.max(8, room))
    local gutter = i == at and MARK or GUTTER
    local head = gutter .. ("%-" .. sha_width .. "s"):format(commit.sha) .. GAP .. subject
    if when ~= "" then
      head = head .. (" "):rep(math.max(#GAP, room - vim.fn.strdisplaywidth(subject) + #GAP)) .. when
    end

    lines[#lines + 1] = head
    local row = #lines - 1
    if i == at then
      marks[#marks + 1] = { row = row, col = 0, opts = { end_col = #MARK, hl_group = "CodeReviewTrimMark" } }
    end
    marks[#marks + 1] = {
      row = row,
      col = #gutter,
      opts = { end_col = #gutter + #commit.sha, hl_group = "CodeReviewQueueIndex" },
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

---List the commits on the branch, newest first, and trim the review to the one picked.
---
---Refuses rather than opening onto one unusable row: a branch whose `HEAD` is the merge
---base has done no work of its own, which is an ordinary state and not a failure, and a
---float holding nothing a reviewer can act on would leave them wondering which of the two
---had gone wrong.
---
---The cursor opens on the row the review currently starts at, so reading this list costs no
---movement -- on `ALL` while the whole branch is in scope, which is the row that says so.
---@param view table The view module, which `<CR>` runs the trim through
---@param root string The repository the branch belongs to
---@param base string Where the branch starts: the review's own scope identity
function M.open(view, root, base)
  local commits, err = git.branch_commits(root, base)
  if not commits then
    info(err or "could not read the commits on this branch")
    return
  end
  if #commits == 0 then
    info("This branch has no commits of its own — its HEAD is the merge base")
    return
  end

  -- Which row the review starts at: the oldest commit the trim did not take out, read back
  -- out of the stored trim rather than off the scope's pre-image. The two agree, but only
  -- the stored trim tells a review trimmed to the oldest commit from a review that was never
  -- trimmed at all -- one review, two rows, and the cursor belongs on a different one in
  -- each.
  local skipped = require("codereview.state").trim(root)
  local at = 0
  if skipped then
    local taken = {}
    for _, sha in ipairs(skipped) do
      taken[sha] = true
    end
    -- From the oldest row up, which is the end of a listing drawn newest first.
    for i = #commits, 1, -1 do
      if not taken[commits[i].id] then
        at = i
        break
      end
    end
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
    footer = " ⏎ review from here · q close ",
    footer_pos = "center",
  })
  -- The rows are fitted to a width they know, so that every one of them stays one row.
  -- Letting the window wrap instead would fold a long subject onto a second line, where a
  -- reviewer counting rows against commits would find one too many.
  vim.wo[win].wrap = false

  local painted = build(commits, vim.api.nvim_win_get_width(win), at)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, painted.lines)
  vim.bo[buf].modifiable = false
  for _, m in ipairs(painted.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS_TRIM, m.row, m.col, m.opts)
  end
  -- Placed rather than left where a fresh window puts it, which is row one: that is the
  -- right row only while nothing is trimmed.
  pcall(vim.api.nvim_win_set_cursor, win, { at + 1, 0 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  ---Apply the row under the cursor and close.
  ---
  ---What a pick applies is the commits it takes **out**: everything older than the row it
  ---lands on, which on `ALL` is nothing at all. The commits kept are never spelled out, so a
  ---commit made after this pick is in the review without the reviewer coming back here.
  ---
  ---Closed first, and then the trim: applying it repaints the review and puts the cursor
  ---back in it, and a float still on screen would take that focus straight back off it.
  local function pick()
    -- The listing starts one row below `ALL`, so the cursor's row is the commit's place in
    -- it plus one -- and row one is `ALL`, which is no commit and takes nothing out.
    local starts_at = vim.api.nvim_win_get_cursor(win)[1] - 1
    local skipped
    if commits[starts_at] then
      skipped = {}
      for i = starts_at + 1, #commits do
        skipped[#skipped + 1] = commits[i].id
      end
    end
    close()
    view.trim_to(skipped)
  end

  vim.keymap.set("n", "<CR>", pick, { buffer = buf, desc = "Review from this commit forward" })
  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close the commit list" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Close the commit list" })
end

return M
