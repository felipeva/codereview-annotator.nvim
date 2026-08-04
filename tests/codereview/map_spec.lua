-- The module map lists exactly the modules that exist.
--
-- `lua/codereview/CLAUDE.md` is loaded automatically for work in that directory, so it is
-- read without being asked for -- which is why a stale row costs more here than in a
-- document someone chose to open. `docs/agents/domain.md` announced that `CONTEXT.md` and
-- `docs/adr/` did not exist yet, long after both did, and nothing noticed. That is the
-- drift this pins.
--
-- Only the row set is checked, in both directions: a module with no row, and a row naming
-- a module that is gone. Prose accuracy is not machine-checkable and is not attempted --
-- the map stays terse so that keeping it true by hand is cheap.
local h = require("tests.helpers")

local dir = vim.fs.joinpath(h.root, "lua", "codereview")
local map = vim.fs.joinpath(dir, "CLAUDE.md")

---Every module in `lua/codereview/`, by name, without the extension.
---@return string[]
local function modules()
  local names = {}
  for entry, kind in vim.fs.dir(dir) do
    local name = kind ~= "directory" and entry:match("^(.+)%.lua$")
    if name then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

---Every module named in the first column of the map's table.
---@return string[]
local function rows()
  local names = {}
  for _, line in ipairs(vim.fn.readfile(map)) do
    local name = line:match("^|%s*`([%w_]+)%.lua`%s*|")
    if name then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

---@param subject string[]
---@param allowed string[]
---@return string[]
local function missing_from(subject, allowed)
  local index = {}
  for _, name in ipairs(allowed) do
    index[name] = true
  end
  return vim.tbl_filter(function(name)
    return not index[name]
  end, subject)
end

describe("the module map", function()
  -- Both cases below compare one set against another, and everything is present in a set
  -- that was never read. A row pattern that quietly stopped matching would leave "no row
  -- names a module that is gone" passing with no rows at all.
  it("has both sides to compare", function()
    assert.is_true(#modules() > 0)
    assert.is_true(#rows() > 0)
  end)

  it("carries a row for every module", function()
    assert.same({}, missing_from(modules(), rows()))
  end)

  it("names no module that does not exist", function()
    assert.same({}, missing_from(rows(), modules()))
  end)
end)
