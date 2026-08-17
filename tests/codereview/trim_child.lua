-- The second process every claim about a kept **trim** needs, in its two directions: a
-- Neovim that trims two branches and exits, and a Neovim that opens a branch review and
-- reports what is in it.
--
-- Deliberately a separate process, for the reason state_child is one: a trim that outlives
-- a session is a claim about what reached the disk, and reading it back in the process that
-- set it proves nothing about that.
--
-- Not named `*_spec.lua`, so PlenaryBustedDirectory does not collect it. It is spawned by
-- trim_spec with XDG_STATE_HOME, FIXTURE and MODE in its environment, and it must NOT load
-- tests/minimal_init.lua, which would mint a state directory of its own.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
vim.o.columns = 110
vim.o.lines = 40
local fixture = assert(vim.env.FIXTURE, "FIXTURE is not set")
local mode = assert(vim.env.MODE, "MODE is not set")
vim.cmd("cd " .. vim.fn.fnameescape(fixture))

require("codereview").setup({ syntax = false })

local view = require("codereview.view")

---@param args string[]
local function git(args)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = fixture, text = true }):wait()
  assert(res.code == 0, table.concat(args, " ") .. ": " .. (res.stderr or ""))
end

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---@return string[]
local function paths()
  return vim.tbl_map(function(f)
    return f.path
  end, assert(view.current(), "no review view open").files)
end

---Read the open review from the row that says `subject` forward, exactly as a reviewer does
---it: `gc` in the diff, `<Space>` on every commit older than that row to take it out, and
---`<CR>` to apply the boxes.
---
---Every box is checked when the list opens, because neither branch here has been trimmed
---before this process runs -- so what this presses is exactly the difference. Asserted
---rather than assumed, because a box that started the other way would silently build the
---wrong reading for the process that reads it back.
---@param subject string
local function trim_by_key(subject)
  local review = assert(view.current(), "no review view open")
  assert(require("codereview.state").trim(review.root) == nil, "this branch is trimmed already")
  vim.api.nvim_set_current_win(review.win)
  feed("gc")
  local win = vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_get_config(win).relative ~= "", "gc opened no float")
  local rows = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  for i, row in ipairs(rows) do
    if row:find(subject, 1, true) then
      for below = i + 1, #rows do
        vim.api.nvim_win_set_cursor(win, { below, 0 })
        feed("<Space>")
      end
      feed("<CR>")
      return
    end
  end
  error(subject .. " is on no row of the commit list:\n" .. table.concat(rows, "\n"))
end

view.open("branch")

if mode == "read" then
  -- What a reviewer opening this repository again would be looking at. Printed rather than
  -- asserted here: the spec owns the expectations, and `nvim -l` sends this to stderr.
  print("paths: " .. table.concat(paths(), ","))
else
  -- Two branches over one history, trimmed to two different commits. Which is what says a
  -- trim belongs to the branch rather than to the repository -- with one trim between them
  -- the two branches cannot be told apart.
  trim_by_key("docs: write the readme")
  git({ "checkout", "-q", "second" })
  -- The branch under the review changed, so the review is resolved again -- the same entry
  -- point `gs` back onto the branch goes through.
  view.set_scope("branch")
  trim_by_key("test: cover the config reader")
  -- Left where a reviewer left it, so the process that reads this back opens the branch it
  -- was reading rather than whichever one this one finished on.
  git({ "checkout", "-q", "feature" })
  print("state file: " .. require("codereview.state").path(assert(view.current()).root))
end

vim.cmd("qa!")
