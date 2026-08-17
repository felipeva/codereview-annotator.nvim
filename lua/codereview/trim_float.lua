---The commits on the branch, read from inside the review, and the **trim** taken off them.
---
---A module of its own, in the shape of `queue_float.lua`: a float needs a buffer, a window
---and keys, and none of the review view's mutable state. What it acts through is handed in
----- the view module for the one action `<CR>` runs, and the repository and the commit the
---branch starts at as plain values -- so nothing here reads the view, which is what keeps
---this module out of the cycle `view` and `annotate` already sit in.
---
---What a row carries is a checkbox, the short sha, the subject and the relative date. The
---checkbox is on every row because the question a reviewer answers here is *is this commit
---in my review*, one commit at a time, and a set with a hole in it is a set no single mark
---on a single row can state. Not the author -- you are reading your own branch.
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

---The checkbox column, at the head of every row: whether that commit is in the review.
---
---The two states are the same width in both rulers, so nothing beside a box moves when it
---is toggled and the byte offsets the highlights are placed at are the columns a reviewer
---counts. Brackets rather than the tree's `✓` and `○`: that pair already says *I have read
---this file*, and one glyph must not do two jobs.
local CHECKED = "[x]"
local UNCHECKED = "[ ]"

---Two spaces between the columns, so the box, the sha, the subject and the date read as
---four columns rather than as one sentence.
local GAP = "  "

---One column kept clear on the right, so a row that fills the float does not run into the
---border.
local MARGIN = 1

---The top row, which puts the whole branch in the review or takes the whole branch out.
---
---Above the commits rather than below them: it is the state a review opens in, and a
---reviewer widening a long branch back out should not have to walk to the bottom to do it.
local ALL = "All commits"

---Whether the whole branch is in the review.
---
---One rule with one answer, because two things ask it: the top row's own box says this, and
---a press on that row makes it true or false.
---@param commits CRCommit[]
---@param checked boolean[]
---@return boolean
local function all_in(commits, checked)
  for i = 1, #commits do
    if not checked[i] then
      return false
    end
  end
  return true
end

---Turn the commits into the float's rows.
---
---The subject keeps the buffer's own color, which is the brightest thing this float has,
---for the reason the **sticky header** leaves the path in the bar's own group: the sha and
---the date are what a row is found by, and the subject is what it is read for.
---
---Its highlight columns are byte offsets, not display columns -- a subject is free to be
---any width in either ruler, and the two part company at the first accented character.
---
---The checkbox column takes its width from the subject and from neither of the other two:
---a sha truncated is a sha a reviewer cannot match against `git log`, and a date is the
---narrowest thing on the row already.
---@param commits CRCommit[]
---@param width integer Columns the float has to draw into
---@param checked boolean[] Whether each commit is in the review, by its place in the listing
---@return { lines: string[], marks: table[] }
local function build(commits, width, checked)
  -- The top row's own box is checked only while every commit is, because that is what it
  -- says.
  local whole = all_in(commits, checked)
  local lines, marks = { (whole and CHECKED or UNCHECKED) .. GAP .. ALL }, {}
  if whole then
    marks[#marks + 1] = { row = 0, col = 0, opts = { end_col = #CHECKED, hl_group = "CodeReviewTrimMark" } }
  end

  -- Padded to the widest sha in the listing. git abbreviates to whatever the repository
  -- needs, and it needs more of them on a big one, so the column cannot be assumed.
  local sha_width = 0
  for _, commit in ipairs(commits) do
    sha_width = math.max(sha_width, #commit.sha)
  end
  local indent = #CHECKED + #GAP + sha_width + #GAP
  local body = math.max(8, width - indent - MARGIN)

  for i, commit in ipairs(commits) do
    local when = commit.when or ""
    local room = body - (when ~= "" and vim.fn.strdisplaywidth(when) + #GAP or 0)
    local subject = render.truncate(commit.subject, math.max(8, room))
    local box = checked[i] and CHECKED or UNCHECKED
    local head = box .. GAP .. ("%-" .. sha_width .. "s"):format(commit.sha) .. GAP .. subject
    if when ~= "" then
      head = head .. (" "):rep(math.max(#GAP, room - vim.fn.strdisplaywidth(subject) + #GAP)) .. when
    end

    lines[#lines + 1] = head
    local row = #lines - 1
    if checked[i] then
      marks[#marks + 1] = { row = row, col = 0, opts = { end_col = #box, hl_group = "CodeReviewTrimMark" } }
    end
    marks[#marks + 1] = {
      row = row,
      col = #box + #GAP,
      opts = { end_col = #box + #GAP + #commit.sha, hl_group = "CodeReviewQueueIndex" },
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

---List the commits on the branch, newest first, and trim the review to the ones checked.
---
---Refuses rather than opening onto one unusable row: a branch whose `HEAD` is the merge
---base has done no work of its own, which is an ordinary state and not a failure, and a
---float holding nothing a reviewer can act on would leave them wondering which of the two
---had gone wrong.
---
---The cursor opens on the reading the reviewer already has, so reading this list back costs
---no movement: the oldest commit still in the review, or the top row while the whole branch
---is in it or the whole branch is out of it -- both of which are what that row says.
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

  -- Every box, read back out of the stored trim rather than off the scope's pre-image. The
  -- two agree on where the review starts, but a pre-image is one commit and a trim can have
  -- a hole in it: only the stored set says which of the rows above that commit are in.
  local skipped = require("codereview.state").trim(root)
  local taken = {}
  for _, sha in ipairs(skipped or {}) do
    taken[sha] = true
  end
  local checked = {}
  for i, commit in ipairs(commits) do
    checked[i] = not taken[commit.id]
  end

  -- The oldest commit still in the review, from the oldest row up -- which is the end of a
  -- listing drawn newest first. With nothing taken out the top row is the reading, and it
  -- is the row that says so.
  local at = 0
  if skipped and #skipped > 0 then
    for i = #commits, 1, -1 do
      if checked[i] then
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
    footer = " Space toggle · ⏎ apply · q close ",
    footer_pos = "center",
  })
  -- The rows are fitted to a width they know, so that every one of them stays one row.
  -- Letting the window wrap instead would fold a long subject onto a second line, where a
  -- reviewer counting rows against commits would find one too many.
  vim.wo[win].wrap = false

  ---Draw every row again from the boxes as they now stand.
  ---
  ---The whole listing rather than the one box that moved: the top row answers for all of
  ---them, so a toggle anywhere can change two rows -- and a rule that redrew only what it
  ---believed had changed is a second answer to what a row says.
  ---
  ---One row is replaced by one row, so the cursor stays where the reviewer left it and
  ---nothing here has to put it back. A repaint that emptied the buffer first would not.
  local function paint()
    local painted = build(commits, vim.api.nvim_win_get_width(win), checked)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, painted.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, NS_TRIM, 0, -1)
    for _, m in ipairs(painted.marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, NS_TRIM, m.row, m.col, m.opts)
    end
  end

  paint()
  -- Placed rather than left where a fresh window puts it, which is row one: that is the
  -- right row only while nothing is trimmed.
  pcall(vim.api.nvim_win_set_cursor, win, { at + 1, 0 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  ---Take the commit under the cursor in or out of the review, and say so on its row.
  ---
  ---On the top row it is every commit at once, in whichever direction that row's own box is
  ---not already pointing: checked, so a narrowed review is widened back out with one key,
  ---and unchecked, which leaves a review of the reviewer's uncommitted work. Nothing is
  ---applied and nothing is stored -- `<CR>` is what does that, so a reviewer builds the set
  ---they want before the review behind them redraws once.
  local function toggle()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    if row == 1 then
      local whole = all_in(commits, checked)
      for i = 1, #commits do
        checked[i] = not whole
      end
    else
      -- The listing starts one row below the top row, so the cursor's row is the commit's
      -- place in it plus one.
      checked[row - 1] = not checked[row - 1]
    end
    paint()
  end

  ---Apply the boxes and close.
  ---
  ---What a pick applies is the commits it takes **out**, which is every row left unchecked.
  ---The commits kept are never spelled out, so a commit made after this pick is in the
  ---review without the reviewer coming back here.
  ---
  ---**A set that cannot be built is refused before anything is stored.** Taking one commit
  ---out can need a commit that is staying, and this is the one moment the refusal is
  ---actionable: the float is still open, the cursor is still on the row, the review behind
  ---it is the review that was there, and unchecking the commit that blocked it is the next
  ---keystroke. It is asked here rather than after the close for that reason alone -- the
  ---view refuses the same set at the same seam, for every caller that is not this float.
  ---
  ---Closed first, and then the trim: applying it repaints the review and puts the cursor
  ---back in it, and a float still on screen would take that focus straight back off it.
  local function pick()
    local skipped = {}
    for i, commit in ipairs(commits) do
      if not checked[i] then
        skipped[#skipped + 1] = commit.id
      end
    end
    -- Nothing rather than an empty set: a review with every box checked has no trim at all,
    -- and a stored set that takes nothing out would still count itself onto the label.
    if #skipped == 0 then
      skipped = nil
    end

    local refused = git.trim_refusal(root, base, skipped)
    if refused then
      info(refused)
      return
    end

    close()
    view.trim_to(skipped)
  end

  vim.keymap.set("n", "<Space>", toggle, { buffer = buf, desc = "Take this commit in or out of the review" })
  vim.keymap.set("n", "<CR>", pick, { buffer = buf, desc = "Review the commits that are checked" })
  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close the commit list" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Close the commit list" })
end

return M
