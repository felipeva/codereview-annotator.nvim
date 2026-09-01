---The commits on the branch, read from inside the review, and the **trim** taken off them.
---
---A module of its own, in the shape of `queue_float.lua`: a float needs a buffer, a window
---and keys, and none of the review view's mutable state. What it acts through is handed in
----- the view module for the one action `<CR>` runs, and the repository and the commit the
---branch starts at as plain values -- so nothing here reads the view, which is what keeps
---this module out of the cycle `view` and `annotate` already sit in.
---
---What a row carries is a checkbox, the short sha, the subject, how much the commit changed
---and the relative date. The checkbox is on every row because the question a reviewer
---answers here is *is this commit in my review*, one commit at a time, and a set with a hole
---in it is a set no single mark on a single row can state. The size is on every row because
---that question needs an answer a subject cannot give: a formatter run over three hundred
---files and a one-line fix read alike until the row says how big each one is.
---
---**The size was refused on this row once, and half of that refusal stands.** It was written
---for a float where a reviewer picked one starting row: the question was *where do I start
---reading*, which the subject answers, and what it refused was making the float wait on a
---second pass over the whole branch -- the listing is a metadata query and near-instant,
---while the counts are a diff of every commit on it. That cost has not changed, so it is
---still refused: the float opens on the listing alone, and the columns fill when git answers
---on a later tick. Nothing here waits for them, and a float closed before the answer arrives
---is answered into nothing.
---
---Not the author -- you are reading your own branch, and that half of the refusal is
---untouched.
---
---**The title counts the boxes, and it counts nothing else.** A running total of what the
---checked commits add up to was refused rather than merely left out: the per-commit figures
---are on the rows already, so summing them is cheap and tempting -- and wrong. Two commits
---that both touch one file count it twice, so the total overstates exactly when the set is
---large enough for a reviewer to want it, and a number they cannot trust is worse than no
---number at all.
---
---**Search is not reimplemented here.** This is an ordinary buffer in an ordinary window,
---so `/`, `n`, `N`, `gg` and `G` reach a commit by its subject and reach the ends of the
---list already. Nothing below may be mapped over them: a key this float takes is a key a
---reviewer no longer has, and none of them is worth what it would cost.
---
---**A run of rows pressed together is made uniform, and flipping each of them was refused.**
---Flipping every row a reviewer drew over is the cheaper rule and the obvious reading of the
---key -- and over a run that is already mixed it hands back a set they have to work out row
---by row, which is the state the press was reached for to get out of. What the rows become
---follows the row the run started at, so the answer is read off where the motion began rather
---than off whatever the rows between the two ends happen to hold.
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

---Two spaces between the columns, so the box, the sha, the subject, the size and the date
---read as five columns rather than as one sentence. Inside the size it is one space, which
---is what keeps its three figures one column of the row rather than three of them.
local GAP = "  "

---How the file count is spelled.
---
---A marker rather than a bare number: the rows carry no header, and a number standing
---between a subject and two signed counts says how many of nothing. One letter rather than
---the word, because the float is fifty columns at its narrowest and every column this takes
---is a column the subject does not get.
---
---The two line counts are spelled `+N -M`, which is what the file header and the **sticky
---header** already spell a size with -- and they take those surfaces' colors as well, so one
---color means one thing wherever a reviewer meets it.
local FILES = "%df"

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

---How much of the terminal's height the float takes, and the fewest rows it takes on a
---terminal too short to give it that share.
---
---A share of the screen rather than a row count. The twenty-eight rows this replaces were
---chosen when the list was something a reviewer glanced at to find one row to start reading
---from; it is the surface a **trim** is built on now, and a branch of sixty scrolling through
---a third of a tall terminal is the room that cap gave away. A share uses what is there at
---every size, where a cap stops using it at one.
---
---Not the whole screen, deliberately: a float leaving no review around it is a different
---class of surface, and `gc` would read as leaving the review rather than as adjusting it.
---The floor is what a terminal too short for a share of any use gets instead.
local HEIGHT_SHARE = 0.8
local HEIGHT_FLOOR = 10

---How tall the float opens, against the terminal it opens on.
---
---Never taller than the listing it holds, either. A five-commit branch on a tall terminal
---would otherwise open a window that is mostly blank -- the same room given away as the cap
---gave away, from the other end -- and the floor is about a short *terminal*, not about a
---short branch: a listing that fits inside it is a listing a reviewer can already see whole.
---@param rows integer Rows the listing has, the row that takes the whole branch included
---@return integer
local function height_for(rows)
  return math.min(rows, math.max(HEIGHT_FLOOR, math.floor(vim.o.lines * HEIGHT_SHARE)))
end

---What the title says about the branch and about the set being built on it.
---
---The branch's own count is on it whatever the boxes say, because a checked count is read
---against something: *three of sixty-five* is a set, *three* is a number.
---
---The whole branch checked falls back to that count alone. It is the state a review opens in,
---and spelling out that nothing has been taken out of it yet says nothing extra. Nothing
---checked is spelled in a word rather than as a `0` standing between two counts, because that
---is the reading worth not misreading: the review is the reviewer's uncommitted work and no
---commit at all.
---
---`N of M` is how the review's own label spells the same fact, so one spelling means one
---thing on both surfaces. Said here while the set is still being built, which is what the
---label cannot do -- it says nothing until a pick is applied, and by then the reviewer has
---already committed to what they built.
---@param commits CRCommit[]
---@param checked boolean[]
---@return string
local function title_for(commits, checked)
  local total = #commits
  local n = 0
  for i = 1, total do
    if checked[i] then
      n = n + 1
    end
  end

  local set
  if n == total then
    set = ("%d commit%s"):format(total, total == 1 and "" or "s")
  elseif n == 0 then
    set = ("none of %d checked"):format(total)
  else
    set = ("%d of %d checked"):format(n, total)
  end
  return (" Commits on this branch · %s "):format(set)
end

---How wide each of the three size columns has to be drawn to line up down the listing.
---
---The widest figure any row carries, and no wider. A reviewer comparing two commits' sizes
---is comparing two columns or they are doing arithmetic, and the sha column is padded to the
---widest sha for the same reason.
---
---All three are zero until git answers, which is what leaves the columns off a row rather
---than blank on it: a width reserved before the answer is a width the answer changes anyway.
---@param commits CRCommit[]
---@param sizes table<string, CRCommitSize>
---@return { files: integer, added: integer, deleted: integer }
local function size_widths(commits, sizes)
  local at = { files = 0, added = 0, deleted = 0 }
  for _, commit in ipairs(commits) do
    local size = sizes[commit.id]
    if size then
      at.files = math.max(at.files, #FILES:format(size.files))
      at.added = math.max(at.added, #("+%d"):format(size.added))
      at.deleted = math.max(at.deleted, #("-%d"):format(size.deleted))
    end
  end
  return at
end

---Turn the commits into the float's rows.
---
---The subject keeps the buffer's own color, which is the brightest thing this float has, for
---the reason the **sticky header** leaves the file's own name the loudest thing on the left:
---the sha and the date are what a row is found by, and the subject is what it is read for.
---
---Its highlight columns are byte offsets, not display columns -- a subject is free to be
---any width in either ruler, and the two part company at the first accented character. Every
---column to the right of it is placed by measuring back from the end of the row in bytes for
---that reason, and never by adding up what is drawn.
---
---The checkbox column takes its width from the subject, and so do the size columns; from
---neither of the other two. A sha truncated is a sha a reviewer cannot match against
---`git log`, and a date is the narrowest thing on the row already.
---@param commits CRCommit[]
---@param width integer Columns the float has to draw into
---@param checked boolean[] Whether each commit is in the review, by its place in the listing
---@param sizes table<string, CRCommitSize> How much each commit changed, empty until git answers
---@return { lines: string[], marks: table[] }
local function build(commits, width, checked, sizes)
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

  -- The right of a row: the size, then the date. Both are as wide as the widest the listing
  -- carries and the same width on every row, which is the whole of what makes them columns
  -- -- a date left to its own width moves the size beside it, and comparing two commits'
  -- sizes is then arithmetic rather than a glance down the rows.
  local size_at = size_widths(commits, sizes)
  local stat_width = size_at.files > 0 and (size_at.files + 1 + size_at.added + 1 + size_at.deleted) or 0
  local stat_format = ("%%%ds %%%ds %%%ds"):format(size_at.files, size_at.added, size_at.deleted)
  local when_width = 0
  for _, commit in ipairs(commits) do
    when_width = math.max(when_width, vim.fn.strdisplaywidth(commit.when or ""))
  end
  local tail_width = stat_width + when_width + ((stat_width > 0 and when_width > 0) and #GAP or 0)

  -- So the subject is the same width on every row as well, and it is what pays for both.
  local room = body - (tail_width > 0 and tail_width + #GAP or 0)
  room = math.max(8, room)

  for i, commit in ipairs(commits) do
    local size = sizes[commit.id]
    -- A commit git answered nothing for keeps its columns clear rather than pulling every
    -- row under it out of line.
    local stat = ""
    if stat_width > 0 then
      stat = size
          and stat_format:format(FILES:format(size.files), ("+%d"):format(size.added), ("-%d"):format(size.deleted))
        or (" "):rep(stat_width)
    end

    local when = commit.when or ""
    local tail = stat
    if when ~= "" then
      when = (" "):rep(when_width - vim.fn.strdisplaywidth(when)) .. when
      tail = tail ~= "" and (tail .. GAP .. when) or when
    end
    local subject = render.truncate(commit.subject, room)
    local box = checked[i] and CHECKED or UNCHECKED
    local head = box .. GAP .. ("%-" .. sha_width .. "s"):format(commit.sha) .. GAP .. subject
    if tail ~= "" then
      head = head .. (" "):rep(math.max(#GAP, room - vim.fn.strdisplaywidth(subject) + #GAP)) .. tail
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
    -- Measured back from the end of the row, in bytes: the subject between here and the sha
    -- is any number of bytes wide at a given number of columns, and adding up what is drawn
    -- would put every mark on this side of it one accented character out.
    if size and stat_width > 0 then
      local at = #head - #tail
      marks[#marks + 1] = {
        row = row,
        col = at,
        opts = { end_col = at + size_at.files, hl_group = "CodeReviewQueueState" },
      }
      local plus = at + size_at.files + 1
      marks[#marks + 1] = {
        row = row,
        col = plus,
        opts = { end_col = plus + size_at.added, hl_group = "CodeReviewStatAdd" },
      }
      local minus = plus + size_at.added + 1
      marks[#marks + 1] = {
        row = row,
        col = minus,
        opts = { end_col = minus + size_at.deleted, hl_group = "CodeReviewStatDel" },
      }
    end
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
  -- The listing, plus the row above it that takes the whole branch in or out.
  local height = height_for(#commits + 1)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = title_for(commits, checked),
    title_pos = "center",
    -- Only what works. A key that is not built is not advertised: a footer offering one is
    -- a promise the float cannot keep.
    --
    -- Fifty columns, which is the narrowest this float is ever drawn: a footer wider than
    -- the border it sits on is clipped from the left, silently, and the keys go with it. The
    -- run is what the room went to -- the two spellings of the one key read as one item
    -- together, and the jump pair gives up the word that said what it moves between, which
    -- its own brackets say to anybody who has met `]f` or `]h`.
    footer = " Space toggle, v rows · ]c/[c · ⏎ apply · q close ",
    footer_pos = "center",
  })
  -- The rows are fitted to a width they know, so that every one of them stays one row.
  -- Letting the window wrap instead would fold a long subject onto a second line, where a
  -- reviewer counting rows against commits would find one too many.
  vim.wo[win].wrap = false

  ---How much each commit changed, empty until git answers. See the header: the listing is
  ---what the float opens on, and this is what it fills in.
  local sizes = {}

  ---Draw every row again from the boxes as they now stand.
  ---
  ---The whole listing rather than the one box that moved: the top row answers for all of
  ---them, so a toggle anywhere can change two rows -- and a rule that redrew only what it
  ---believed had changed is a second answer to what a row says. The size columns are as
  ---wide as the listing's widest figure, so the answer arriving moves every row as well.
  ---
  ---One row is replaced by one row, so the cursor stays where the reviewer left it and
  ---nothing here has to put it back. A repaint that emptied the buffer first would not.
  ---
  ---The title is written again from the same boxes, because it counts them: a reviewer
  ---building a set watches the count move as they press, rather than learning what they built
  ---from the review's label once it is too late to change. Only the title is handed back, so
  ---nothing else the window was opened with is restated here to be kept.
  local function paint()
    local painted = build(commits, vim.api.nvim_win_get_width(win), checked, sizes)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, painted.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, NS_TRIM, 0, -1)
    for _, m in ipairs(painted.marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, NS_TRIM, m.row, m.col, m.opts)
    end
    vim.api.nvim_win_set_config(win, { title = title_for(commits, checked), title_pos = "center" })
  end

  paint()
  -- Placed rather than left where a fresh window puts it, which is row one: that is the
  -- right row only while nothing is trimmed.
  pcall(vim.api.nvim_win_set_cursor, win, { at + 1, 0 })

  -- The sizes, asked for after the rows are on screen and drawn whenever the answer
  -- arrives. A reviewer is reading subjects and moving the cursor by then, and the paint
  -- takes neither away: the rows are the same rows, in the same order, and the cursor sits
  -- on the one it sat on.
  --
  -- **The float can be gone by the time git answers**, which is the ordinary end of a list
  -- opened to check one thing: `q` closes the window and the buffer is wiped with it. So
  -- both are asked before anything is written, and the answer is dropped rather than
  -- painted into a window that is not there. Nothing here can be latched to the close
  -- instead -- the window can also go with the tab it was in, or with the review behind it.
  git.branch_sizes(root, base, function(answered)
    if not answered or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
      return
    end
    sizes = answered
    paint()
  end)

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  ---Take a run of rows in or out of the review, and say so on every one of them.
  ---
  ---One row is a run of one, which is what a press with no motion behind it is. On the top
  ---row that is every commit at once, in whichever direction that row's own box is not
  ---already pointing: checked, so a narrowed review is widened back out with one key, and
  ---unchecked, which leaves a review of the reviewer's uncommitted work. Nothing is applied
  ---and nothing is stored -- `<CR>` is what does that, so a reviewer builds the set they want
  ---before the review behind them redraws once.
  ---
  ---**A longer run is made uniform rather than flipped row by row**, and what its rows become
  ---is read off the row it started at. See the header for what that refuses.
  ---
  ---The top row inside a longer run is stepped over rather than folded into it: it is not a
  ---commit, and it already means *every box at once* -- a run that happened to reach the top
  ---of the list would otherwise do something far larger than the reviewer drew. A run that
  ---started there is read from the first commit in it instead, that row being the first one
  ---the run can act on at all.
  ---
  ---Every press comes through here, however many rows it carries, so the repaint that follows
  ---it -- the boxes, the top row's own box and the count on the title -- is one answer to what
  ---the reviewer did rather than two that have to agree.
  ---@param first integer The first row of the run, 1-based
  ---@param last integer The last row of the run
  ---@param from integer The row the run started at, which is what decides the direction
  local function toggle(first, last, from)
    if last == 1 then
      local whole = all_in(commits, checked)
      for i = 1, #commits do
        checked[i] = not whole
      end
    else
      -- The listing starts one row below the top row, so a row is the commit's place in it
      -- plus one.
      local head = math.max(first, 2)
      local want = not checked[math.max(from, head) - 1]
      for row = head, last do
        checked[row - 1] = want
      end
    end
    paint()
  end

  ---The row under the cursor, pressed on its own.
  local function toggle_row()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    toggle(row, row, row)
  end

  ---The rows a reviewer drew over, pressed together.
  ---
  ---`v` is the end the run started at and the cursor is the end it stopped at, whichever way
  ---round the two are on the screen. Read from those two rather than from `'<` and `'>`: those
  ---marks are not written until visual mode is left, and they say which row is higher rather
  ---than which one the reviewer began on -- which is the whole of what decides the direction.
  ---
  ---Visual mode is left on the way out, so the reviewer is back in the mode every other key on
  ---this float is pressed in. Left with `<C-\><C-n>` rather than with `<Esc>`, and fed
  ---unmapped: `<Esc>` is this float's own key for closing, so a press that let that mapping
  ---run would shut the list on the reviewer as they built a set on it. The composer settles
  ---out of a mode the same way, for the same reason -- the key that leaves a mode must not be
  ---a key the surface has taken for something else.
  local function toggle_run()
    local from, to = vim.fn.line("v"), vim.fn.line(".")
    toggle(math.min(from, to), math.max(from, to), from)
    vim.api.nvim_feedkeys(vim.keycode("<C-\\><C-n>"), "n", false)
  end

  ---Move to the next or the previous commit that is checked.
  ---
  ---Neither direction wraps. Reaching the end of the run reports it, which is what `]f` and
  ---`]h` do on the diff behind this float: the end of a list is a fact, and a jump that came
  ---back round would move a reviewer somewhere they did not ask to be.
  ---
  ---The top row is not a target: it is not a commit. Jumping *from* it is ordinary, which is
  ---what puts the newest checked commit one press away from the row the float opens on.
  ---@param forward boolean
  local function jump(forward)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local found, any
    for i = 1, #commits do
      if checked[i] then
        any = true
        -- The listing starts one row below the top row, so a commit sits on its place in the
        -- listing plus one -- the arithmetic `toggle` reads a press with.
        local at = i + 1
        if forward and at > row then
          -- The first row past the cursor, and the rows are walked in the order they are
          -- drawn in, so the first match forward is the nearest one.
          found = found or at
        elseif not forward and at < row then
          found = at
        end
      end
    end
    -- Said apart from the sentence below, because they are different facts: one is a list
    -- with nothing to move between, the other is a reviewer already at the end of it.
    if not any then
      info("No commit is checked")
      return
    end
    if not found then
      info(("No %s checked commit here"):format(forward and "next" or "previous"))
      return
    end
    vim.api.nvim_win_set_cursor(win, { found, 0 })
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

  vim.keymap.set("n", "<Space>", toggle_row, { buffer = buf, desc = "Take this commit in or out of the review" })
  vim.keymap.set(
    "x",
    "<Space>",
    toggle_run,
    { buffer = buf, desc = "Take the commits on these rows in or out of the review" }
  )
  vim.keymap.set("n", "]c", function()
    jump(true)
  end, { buffer = buf, desc = "Next checked commit" })
  vim.keymap.set("n", "[c", function()
    jump(false)
  end, { buffer = buf, desc = "Previous checked commit" })
  vim.keymap.set("n", "<CR>", pick, { buffer = buf, desc = "Review the commits that are checked" })
  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close the commit list" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Close the commit list" })
end

return M
