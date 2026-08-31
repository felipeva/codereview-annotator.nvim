---Shared plumbing for the spec files.
---
---Each spec runs in its own Neovim (PlenaryBustedDirectory spawns one process per file),
---so a fixture built here is private to that spec and nothing needs to reset between
---files. Fixtures land under Neovim's own tempdir, which it removes on exit.
local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

---Build a fixture repository and return its path.
---
---Anything after the script name is passed to it after the path, which is how `mkbig` is
---asked for a diff of a particular height: it takes a file count and a line count.
---@param script "mkfixture"|"mktree"|"mkbig"|"mkcommits"|"mkcheckouts"|"mktextconv"
---@param ... string
---@return string dir
function M.fixture(script, ...)
  local dir = vim.fn.tempname() .. "-" .. script
  local sh = vim.fs.joinpath(M.root, "tests", "fixtures", script .. ".sh")
  local res = vim.system(vim.list_extend({ "bash", sh, dir }, { ... }), { text = true }):wait(60000)
  assert(res.code == 0, ("%s failed (%d): %s"):format(script, res.code, res.stderr or ""))
  return dir
end

---Build a fixture and make it the current directory.
---@param script "mkfixture"|"mktree"|"mkbig"|"mkcommits"|"mkcheckouts"|"mktextconv"
---@param ... string
---@return string dir
function M.cd_fixture(script, ...)
  local dir = M.fixture(script, ...)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  return dir
end

---A window big enough that rendering and the viewport-bounded syntax pass behave as they
---do interactively. Headless Neovim defaults to 80x24, which is small enough to change
---which files get parsed.
---@param columns? integer
---@param lines? integer
function M.ui(columns, lines)
  vim.o.columns = columns or 110
  vim.o.lines = lines or 40
end

---Run git in `root` and return its stdout split into lines.
---@param root string
---@param args string[]
---@return string[]
function M.git_lines(root, args)
  local res = vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = root }):wait()
  return vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true })
end

---Collect everything `vim.notify` is handed until `restore()` is called.
---@return string[] messages, fun() restore
function M.capture_notify()
  local messages = {}
  local orig = vim.notify
  vim.notify = function(msg, ...)
    messages[#messages + 1] = msg
    return orig(msg, ...)
  end
  return messages, function()
    vim.notify = orig
  end
end

---Collect notifications with the level each was reported at, which `capture_notify`
---drops. For the cases where *how loudly* something was said is the point.
---@return { msg: string, level: integer }[] records, fun() restore
function M.capture_notify_levels()
  local records = {}
  local orig = vim.notify
  vim.notify = function(msg, level, ...)
    records[#records + 1] = { msg = msg, level = level }
    return orig(msg, level, ...)
  end
  return records, function()
    vim.notify = orig
  end
end

---@param messages string[]|{ msg: string, level: integer }[] Either capture's shape
---@param needle string
---@return boolean
function M.notified(messages, needle)
  for _, m in ipairs(messages) do
    local text = type(m) == "table" and m.msg or m
    if type(text) == "string" and text:find(needle, 1, true) then
      return true
    end
  end
  return false
end

---The level a matching notification was reported at.
---@param records { msg: string, level: integer }[]
---@param needle string
---@return integer|nil level nil when nothing matched
function M.notified_level(records, needle)
  for _, r in ipairs(records) do
    if type(r.msg) == "string" and r.msg:find(needle, 1, true) then
      return r.level
    end
  end
end

---Feed keys and let them run to completion.
---@param keys string
function M.feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---Index of a file in the view, by path.
---@param view CRView
---@param path string
---@return integer|nil
function M.file_index(view, path)
  for i, f in ipairs(view.files) do
    if f.path == path then
      return i
    end
  end
end

---First buffer row anchored to `path` that satisfies `pred`.
---@param view CRView
---@param path string
---@param pred fun(anchor: table, row: integer): boolean
---@return integer|nil
function M.row_of(view, path, pred)
  for row, a in pairs(view.render.anchors) do
    if view.files[a.file].path == path and pred(a, row) then
      return row
    end
  end
end

---First row anchored to any diff line of `path`.
---@param view CRView
---@param path string
---@return integer|nil
function M.line_row(view, path)
  return M.row_of(view, path, function(a)
    return a.kind == "line"
  end)
end

---What a window's **sticky header** draws, and how many columns of it.
---
---Read through Neovim's own statusline parser rather than off the window option, and every
---assertion about what a bar *says* has to come through here. The option holds markup: a
---needle spanning two segments is not in that string at all, so an `is_nil` for one passes
---whatever the bar says, and a width taken from it counts the highlight markers -- several
---characters each and no columns at all on the screen. Both are the same trap the bar's own
---padding walked into from the other side. What must still read the raw option is the one
---assertion about the *escape*, which is a claim about the markup itself.
---@param win integer
---@return string text, integer width
function M.winbar(win)
  local drawn = vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true })
  return drawn.str, drawn.width
end

---The group of the plugin's own that the first byte of `needle` is drawn in, or nil.
---
---**nil means the bar's own group**, which is the brightest thing a winbar has -- and it is
---reported as an absence rather than by name because that name is `WinBar` in the pane with
---focus and `WinBarNC` in the other one. A case naming it answers differently depending on
---where the cursor was, which is a case that reds for a reason that has nothing to do with
---color. What is read is the group stacked *on top of* the bar's own, which is exactly the
---question every caller is asking.
---
---Read through the same parser `M.winbar` uses, so a marker that landed one segment out is
---visible here. What this cannot say is that the cell on the screen took that group's
---color. Only a painted cell can, and `split_spec` reads two.
---@param win integer
---@param needle string
---@return string|nil
function M.winbar_group(win, needle)
  local opts = { winid = win, use_winbar = true, highlights = true }
  local drawn = vim.api.nvim_eval_statusline(vim.wo[win].winbar, opts)
  local at = assert(drawn.str:find(needle, 1, true), ("%q is not on the bar: %s"):format(needle, drawn.str)) - 1
  local stack = {}
  for _, run in ipairs(drawn.highlights) do
    if run.start <= at then
      stack = run.groups
    end
  end
  return #stack > 1 and stack[#stack] or nil
end

M.NS = vim.api.nvim_create_namespace("codereview")

---@param view CRView
---@return table[]
function M.extmarks(view)
  return vim.api.nvim_buf_get_extmarks(view.buf, M.NS, 0, -1, { details = true })
end

---Extmarks carrying an annotation's virtual lines.
---@param view CRView
---@return table[]
function M.virt_marks(view)
  return vim.tbl_filter(function(m)
    return m[4].virt_lines ~= nil
  end, M.extmarks(view))
end

---The highlight groups the virtual lines on a view's diff are drawn in, as a set.
---
---What tells a queued annotation from an archived one without reading a color: an entry
---drawn out of the queue carries its annotation type's group, and one drawn out of the
---archive carries the archive's own.
---@param view CRView
---@return table<string, boolean>
function M.virt_groups(view)
  local groups = {}
  for _, m in ipairs(M.virt_marks(view)) do
    for _, line in ipairs(m[4].virt_lines) do
      for _, chunk in ipairs(line) do
        groups[chunk[2]] = true
      end
    end
  end
  return groups
end

---Extmarks emitted by the treesitter replay.
---@param view CRView
---@return table[]
function M.syntax_marks(view)
  local priority = require("codereview.render").PRIORITY.syntax
  return vim.tbl_filter(function(m)
    return m[4].priority == priority
  end, M.extmarks(view))
end

return M
