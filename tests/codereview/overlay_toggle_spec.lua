-- `overlay.enabled` is what a new Neovim starts from: the margin open from `true`, closed
-- from `false`, and the toggle leaving it the other way either time.
--
-- Two children, the solo toggle spec's shape: a configured default is only observable in a
-- process nothing has toggled in yet, and this one is never it. Both share this process's
-- throwaway XDG_STATE_HOME and nothing else, and run with `--clean` so no user config and no
-- minimal_init can hand them a different one.
local h = require("tests.helpers")

local fixture = h.fixture("mkfixture")

---@param enabled boolean
---@return string out Both streams of the child, which prints to stderr under `-l`
local function run_child(enabled)
  local run = vim
    .system({
      vim.v.progpath,
      "--clean",
      "-l",
      vim.fs.joinpath(h.root, "tests", "codereview", "overlay_toggle_child.lua"),
    }, {
      cwd = fixture,
      text = true,
      env = {
        XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
        FIXTURE = fixture,
        OVERLAY = tostring(enabled),
        GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_CONFIG_SYSTEM = "/dev/null",
      },
    })
    :wait(60000)
  local out = (run.stdout or "") .. (run.stderr or "")
  assert(run.code == 0, out)
  return out
end

describe("a session configured with the overlay on", function()
  local out = run_child(true)

  it("opens with the margin beside the window, at the configured width", function()
    assert.is_truthy(out:find("opened=true beside=true", 1, true), out)
  end)

  it("turns it off at the first toggle", function()
    assert.is_truthy(out:find("toggled=false margin_after=false", 1, true), out)
  end)
end)

describe("a session configured with the overlay off", function()
  local out = run_child(false)

  it("opens with no margin", function()
    assert.is_truthy(out:find("opened=false", 1, true), out)
  end)

  it("turns it on at the first toggle", function()
    assert.is_truthy(out:find("toggled=true margin_after=true", 1, true), out)
  end)
end)
