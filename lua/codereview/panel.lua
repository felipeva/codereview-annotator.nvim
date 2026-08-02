---The file tree panel.
---
---The main buffer answers "what changed here"; this answers "where am I and how much is
---left", which a single scrolling document cannot show. A flat list of basenames could not
---either: in any real repository half the entries are called `index.ts`.
local M = {}

---@class CRPanelNode
---@field kind "dir"|"file"
---@field name string          Display segment (a dir may hold several, e.g. "apps/api")
---@field path string          Full path from the repository root
---@field children CRPanelNode[]|nil
---@field index integer|nil    Index into the file list, for a file node
---@field total integer        Files in this subtree
---@field reviewed integer     Reviewed files in this subtree
---@field notes integer        Annotations in this subtree

---@class CRPanelRender
---@field lines string[]
---@field marks table[]
---@field row_file table<integer, integer>   Buffer row -> file index
---@field row_dir table<integer, string>     Buffer row -> directory path
---@field row_depth table<integer, integer>  Buffer row -> tree depth
---@field file_row table<integer, integer>   File index -> buffer row
---@field file_rows integer[]                Every file row, ascending, for ]f / [f

---@param text string
---@param width integer
---@return string
local function truncate_left(text, width)
  if width <= 1 or vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  -- Truncate from the LEFT: the tail of a name identifies it, the head is usually shared
  -- boilerplate with its siblings.
  local chars = vim.fn.strcharlen(text)
  return "…" .. vim.fn.strcharpart(text, chars - width + 1)
end

--- Tree construction -----------------------------------------------------------

---@param files CRFile[]
---@return table root
local function build(files)
  local root = { kind = "dir", name = "", path = "", dirs = {}, files = {} }
  for index, file in ipairs(files) do
    local parts = vim.split(file.path, "/", { plain = true })
    local leaf = table.remove(parts)
    local node, acc = root, {}
    for _, part in ipairs(parts) do
      acc[#acc + 1] = part
      if not node.dirs[part] then
        node.dirs[part] = { kind = "dir", name = part, path = table.concat(acc, "/"), dirs = {}, files = {} }
      end
      node = node.dirs[part]
    end
    node.files[#node.files + 1] = { kind = "file", name = leaf, path = file.path, index = index, file = file }
  end
  return root
end

---Compact, sort and total a subtree.
---
---Compaction merges a directory that holds exactly one directory and no files into its
---child, so a monorepo shows `apps/api/src` on one row instead of burning three rows and
---six columns of indent on path segments that carry no information.
---@param node table
---@param stat fun(file: CRFile, path: string): boolean reviewed, integer notes
---@return CRPanelNode
local function finish(node, stat)
  -- The root is virtual and has no row of its own, so it must not absorb its only child;
  -- that child compacts on its own and renders at depth zero anyway.
  while node.path ~= "" and vim.tbl_count(node.dirs) == 1 and #node.files == 0 do
    local _, only = next(node.dirs)
    node.name = node.name .. "/" .. only.name
    node.path = only.path
    node.dirs, node.files = only.dirs, only.files
  end

  local children = {}
  local dir_names = vim.tbl_keys(node.dirs)
  table.sort(dir_names, function(a, b)
    return a:lower() < b:lower()
  end)
  -- Directories first, then files: the ordering every file explorer uses.
  for _, name in ipairs(dir_names) do
    children[#children + 1] = finish(node.dirs[name], stat)
  end
  table.sort(node.files, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  for _, file in ipairs(node.files) do
    local reviewed, notes = stat(file.file, file.path)
    file.reviewed = reviewed and 1 or 0
    file.total = 1
    file.notes = notes
    children[#children + 1] = file
  end

  node.children = children
  node.total, node.reviewed, node.notes = 0, 0, 0
  for _, child in ipairs(children) do
    node.total = node.total + child.total
    node.reviewed = node.reviewed + child.reviewed
    node.notes = node.notes + child.notes
  end
  node.dirs, node.files = nil, nil
  return node
end

---@param files CRFile[]
---@param opts { reviewed: table<string, string>, notes: table<string, table[]> }
---@return CRPanelNode
function M.tree(files, opts)
  -- Note counts are bucketed once rather than rescanned per file: the naive form is
  -- O(files x annotations), which is the whole panel's cost on a large review.
  local per_path = {}
  for key, items in pairs(opts.notes or {}) do
    local path = key:match("^(.*):[nof]:%d+$")
    if path then
      per_path[path] = (per_path[path] or 0) + #items
    end
  end

  return finish(build(files), function(_, path)
    return (opts.reviewed or {})[path] ~= nil, per_path[path] or 0
  end)
end

--- Rendering -------------------------------------------------------------------

---@param files CRFile[]
---@param opts { width: integer, icons: table, reviewed: table<string, string>, notes: table<string, table[]>, collapsed: table<string, boolean>, current: integer|nil }
---@return CRPanelRender
function M.build(files, opts)
  local icons = opts.icons
  local width = math.max(14, opts.width)
  local collapsed = opts.collapsed or {}
  local tree = M.tree(files, opts)

  local lines, marks = {}, {}
  local row_file, row_dir, row_depth, file_row, file_rows = {}, {}, {}, {}, {}

  ---@param row integer
  ---@param col integer
  ---@param o table
  local function mark(row, col, o)
    marks[#marks + 1] = { row = row - 1, col = col, opts = o }
  end

  ---@param node CRPanelNode
  ---@param depth integer
  local function draw(node, depth)
    local indent = ("  "):rep(depth)

    if node.kind == "dir" then
      local shut = collapsed[node.path]
      local chevron = shut and icons.collapsed or icons.expanded
      local right = ("%d/%d"):format(node.reviewed, node.total)
      local name = truncate_left(node.name, width - #indent - 2 - #right - 2)
      local head = ("%s%s %s"):format(indent, chevron, name)
      local pad = math.max(1, width - vim.fn.strdisplaywidth(head) - #right - 1)
      local text = head .. (" "):rep(pad) .. right

      lines[#lines + 1] = text
      local row = #lines
      row_dir[row] = node.path
      row_depth[row] = depth
      mark(row, 0, { end_col = #head, hl_group = "CodeReviewPanelDir" })
      mark(row, #text - #right, {
        end_col = #text,
        -- A fully-reviewed directory reads as done at a glance, without counting.
        hl_group = node.reviewed == node.total and "CodeReviewStatAdd" or "CodeReviewNoteCount",
      })

      if not shut then
        for _, child in ipairs(node.children) do
          draw(child, depth + 1)
        end
      end
      return
    end

    local reviewed = node.reviewed == 1
    local icon = reviewed and icons.reviewed or (node.notes > 0 and icons.annotated or icons.unreviewed)
    local right = node.notes > 0 and tostring(node.notes) or ""
    local name = truncate_left(node.name, width - #indent - 2 - #right - 2)
    local head = ("%s%s %s"):format(indent, icon, name)
    local pad = math.max(1, width - vim.fn.strdisplaywidth(head) - #right - 1)
    local text = head .. (" "):rep(pad) .. right

    lines[#lines + 1] = text
    local row = #lines
    row_file[row] = node.index
    row_depth[row] = depth
    file_row[node.index] = row
    file_rows[#file_rows + 1] = row

    mark(
      row,
      #indent,
      { end_col = #indent + #icon, hl_group = reviewed and "CodeReviewStatAdd" or "CodeReviewNoteCount" }
    )
    if reviewed then
      mark(row, 0, { line_hl_group = "CodeReviewFileReviewed" })
    end
    if node.notes > 0 then
      mark(row, #text - #right, { end_col = #text, hl_group = "CodeReviewNoteCount" })
    end
    -- Where the diff cursor currently is. Painted last so it wins over the reviewed dim.
    if opts.current and node.index == opts.current then
      mark(row, 0, { line_hl_group = "CodeReviewPanelSel", priority = 200 })
    end
  end

  for _, child in ipairs(tree.children) do
    draw(child, 0)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = ("%d/%d reviewed"):format(tree.reviewed, tree.total)
  mark(#lines, 0, { line_hl_group = "CodeReviewTitle" })

  return {
    lines = lines,
    marks = marks,
    row_file = row_file,
    row_dir = row_dir,
    row_depth = row_depth,
    file_row = file_row,
    file_rows = file_rows,
  }
end

---Every file index beneath a directory path.
---@param files CRFile[]
---@param dir string
---@return integer[]
function M.files_under(files, dir)
  local out = {}
  local prefix = dir .. "/"
  for index, file in ipairs(files) do
    if file.path:sub(1, #prefix) == prefix then
      out[#out + 1] = index
    end
  end
  return out
end

---Directory paths in the tree, for collapse-all.
---@param tree CRPanelNode
---@return string[]
function M.dir_paths(tree)
  local out = {}
  local function walk(node)
    for _, child in ipairs(node.children or {}) do
      if child.kind == "dir" then
        out[#out + 1] = child.path
        walk(child)
      end
    end
  end
  walk(tree)
  return out
end

return M
