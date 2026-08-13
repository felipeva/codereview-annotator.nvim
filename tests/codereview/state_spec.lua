-- Persistence across a real restart, and the blob check that makes persisting safe.
--
-- A review spans hours, so reviewed marks and unsent annotations are worth keeping. What
-- makes that safe rather than reckless is that everything records the blob it was written
-- against: a reviewed mark whose file moved is dropped, an annotation whose file moved is
-- kept but flagged stale.
local h = require("tests.helpers")

h.ui(110, 40)
local fixture = h.cd_fixture("mkfixture")

local view = require("codereview.view")
local queue = require("codereview.queue")
local state = require("codereview.state")
local payload = require("codereview.payload")
local config = require("codereview.config")

require("codereview").setup({
  syntax = false,
  compose = function(ctx, on_accept, _)
    on_accept(nil, "note on " .. ctx.rel_path)
  end,
})

describe("the writing process", function()
  -- The child shares this process's throwaway XDG_STATE_HOME and nothing else. It runs
  -- with `--clean` so no user config, and no minimal_init, can hand it a different one.
  local cmd = {
    vim.v.progpath,
    "--clean",
    "-l",
    vim.fs.joinpath(h.root, "tests", "codereview", "state_child.lua"),
  }
  local proc = vim.system(cmd, {
    cwd = fixture,
    text = true,
    env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME, FIXTURE = fixture },
  })
  local child = proc:wait(60000)

  it("exits cleanly", function()
    assert.same(0, child.code, (child.stderr or "") .. (child.stdout or ""))
  end)

  it("leaves a state file behind", function()
    local path = state.path(vim.uv.fs_realpath(fixture))
    assert.same(1, vim.fn.filereadable(path), "no state at " .. path .. "\n" .. (child.stdout or ""))
  end)
end)

describe("a cold start", function()
  -- Nothing in memory: everything asserted below came off the disk.
  it("starts with an empty queue", function()
    assert.same(0, queue.count())
  end)

  view.open("branch")
  local V = view.current()

  it("restores the reviewed mark, and only that one", function()
    assert.is_not_nil(V.reviewed["src/main.lua"])
    assert.same(1, vim.tbl_count(V.reviewed))
  end)

  it("restores the queue", function()
    assert.same(2, queue.count())
  end)

  it("restores each note's type and text", function()
    assert.same(
      { "bug", "nitpick" },
      vim.tbl_map(function(i)
        return i.type
      end, queue.all())
    )
    assert.same("note on src/fresh.lua", queue.all()[1].note)
  end)

  it("flags nothing stale, because nothing moved", function()
    assert.same(0, queue.stale_count())
  end)

  it("collapses the restored file", function()
    for _, a in pairs(V.render.anchors) do
      assert.is_false(V.files[a.file].path == "src/main.lua" and a.kind == "line")
    end
  end)

  -- Ids come off the disk; the counter has to resume past them or the next annotation
  -- shares an id with a restored one and `drop` removes the wrong entry.
  it("continues ids rather than colliding with restored ones", function()
    local before = queue.count()
    queue.add({ type = "bug", kind = "file", path = "x", key = "x:f:0", note = "n" })

    local seen, dupes = {}, 0
    for _, i in ipairs(queue.all()) do
      dupes = dupes + (seen[i.id] and 1 or 0)
      seen[i.id] = true
    end

    queue.remove(queue.all()[#queue.all()].id)
    assert.same(0, dupes)
    assert.same(before, queue.count())
  end)
end)

describe("when an annotated file changes underneath", function()
  local V = view.current()
  local messages, restore = h.capture_notify()

  vim.fn.writefile({ "local function fresh() end", "-- touched after annotating" }, "src/fresh.lua")
  view.refresh()
  restore()

  -- The prose is still worth sending; only its line anchor is untrustworthy.
  it("keeps the note but flags it stale", function()
    assert.same(2, queue.count())
    assert.is_true(queue.all()[1].stale)
  end)

  it("leaves the untouched note alone", function()
    assert.is_nil(queue.all()[2].stale)
  end)

  it("reports the staleness", function()
    assert.is_true(h.notified(messages, "stale"))
  end)

  it("marks it stale in the buffer", function()
    view.paint()
    local saw = false
    for _, m in ipairs(h.virt_marks(V)) do
      for _, line in ipairs(m[4].virt_lines) do
        for _, chunk in ipairs(line) do
          saw = saw or (type(chunk[1]) == "string" and chunk[1]:find("stale", 1, true) ~= nil)
        end
      end
    end
    assert.is_true(saw)
  end)

  it("never lets a stale note travel as an @ref", function()
    local text = payload.render(queue.all(), V.root, { types = config.get().types })
    assert.is_nil(text:find("@src/fresh.lua", 1, true))
    assert.is_truthy(text:find("line numbers may be stale", 1, true))
  end)
end)

describe("when a reviewed file changes underneath", function()
  local V = view.current()
  local messages, restore = h.capture_notify()

  vim.fn.writefile({
    'local app = require("app")',
    "local cfg = load_config()",
    "app.listen(cfg.port)",
    "-- touched",
  }, "src/main.lua")
  view.refresh()
  restore()

  -- You have not reviewed what is there now, so the mark is dropped outright rather than
  -- flagged.
  it("drops the mark", function()
    assert.is_nil(V.reviewed["src/main.lua"])
  end)

  it("reports the un-marking", function()
    assert.is_true(h.notified(messages, "changed since review"))
  end)

  it("expands the file again", function()
    local expanded = false
    for _, a in pairs(V.render.anchors) do
      expanded = expanded or (V.files[a.file].path == "src/main.lua" and a.kind == "line")
    end
    assert.is_true(expanded)
  end)
end)

describe("an unreadable state file", function()
  local root = view.current().root
  local path = state.path(root)

  -- Losing review progress costs far less than restoring marks that mean something
  -- different than they did when written, so neither case is repaired.
  it("loads a corrupt file as empty", function()
    vim.fn.writefile({ "{ this is not json" }, path)
    local loaded = state.load(root)
    assert.same({ 0, 0 }, { vim.tbl_count(loaded.scopes), #loaded.queue })
  end)

  it("discards a future version rather than migrating it", function()
    vim.fn.writefile({ vim.json.encode({ version = 99, scopes = { a = 1 }, queue = { 1, 2 } }) }, path)
    local loaded = state.load(root)
    assert.same({ 0, 0 }, { vim.tbl_count(loaded.scopes), #loaded.queue })
  end)

  it("clears the file on request", function()
    state.clear(root)
    assert.same(0, vim.fn.filereadable(path))
  end)

  it("treats a missing file as empty, not an error", function()
    assert.same(1, state.load(root).version)
  end)
end)

-- Reviewed marks are the expensive state here -- they stand for hours of reading -- and a
-- write rebuilt the whole scopes table from the open view's `per_scope`. A view only knows
-- the scopes it has itself opened, so every scope it had not seen was overwritten by its
-- own absence, silently, on the next `R`.
--
-- One process is enough, unlike the queue: a view has no session-wide latch. Every
-- `view.open` builds a fresh `per_scope`, so reopening in another scope reproduces exactly
-- what a new session does.
describe("marks belonging to a scope this view never opened", function()
  local root = assert(vim.uv.fs_realpath(fixture))

  ---Mark the file at `path` reviewed in the open view.
  ---@param path string
  local function toggle_reviewed_on(path)
    local V = assert(view.current(), "no view open")
    local index = assert(h.file_index(V, path), path .. " is not in this scope")
    vim.api.nvim_win_set_cursor(V.win, { V.render.file_rows[index], 0 })
    view.toggle_reviewed()
  end

  ---The key the plugin files this scope's progress under.
  ---
  ---Built from the scope's **identity** and never from its pre-image, which is the same
  ---rule the view itself follows. The two agree for every scope that carries no **trim**,
  ---so a key spelled with `before` reads correctly here and quietly stops naming anything
  ---the moment a trimmed branch review is opened -- and the assertions below then compare
  ---two empty tables instead of failing.
  ---@return string
  local function scope_key_of()
    local V = assert(view.current())
    return V.scope.name .. ":" .. V.scope.identity
  end

  view.close()
  queue.clear()
  state.clear(root)

  -- One review, in one scope.
  view.open("branch")
  local branch_key = scope_key_of()
  toggle_reviewed_on("src/routes.lua")
  view.close()

  it("saved the first scope's mark", function()
    assert.is_truthy(state.load(root).scopes[branch_key], "nothing was saved to begin with")
  end)

  -- A different scope, in a view that has never seen the first one.
  view.open("staged")
  local staged_key = scope_key_of()
  toggle_reviewed_on("src/routes.lua")

  it("saved the second scope's mark", function()
    assert.is_truthy(state.load(root).scopes[staged_key])
  end)

  it("kept the first scope's mark, which this view could not see", function()
    local scopes = state.load(root).scopes
    assert.is_truthy(scopes[branch_key], "the earlier scope's reviewed marks were lost")
    assert.same(2, vim.tbl_count(scopes))
  end)

  -- The half a naive merge gets wrong. Un-marking has to remove the scope outright, or
  -- merging over what is stored hands back the marks that were just cleared.
  it("removes a scope once its last mark is cleared, rather than resurrecting it", function()
    toggle_reviewed_on("src/routes.lua")
    local scopes = state.load(root).scopes
    assert.is_nil(scopes[staged_key], "an emptied scope came back from the stored document")
    assert.is_truthy(scopes[branch_key], "the other scope was lost while removing this one")
  end)

  view.close()
end)
