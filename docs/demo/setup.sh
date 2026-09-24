#!/bin/sh
# Build the throwaway repository that demo.tape records. A bare "origin" sits beside it,
# so the branch review has an origin/HEAD to diff against, as a real clone does.
set -eu

dir=${1:-/tmp/codereview-demo}
rm -rf "$dir" "$dir.git"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
g() { git -C "$dir" -c user.name=demo -c user.email=demo@example.com "$@"; }

git init -q --bare -b master "$dir.git"
git clone -q "$dir.git" "$dir" 2>/dev/null
mkdir -p "$dir/lua/app/routes"

cat > "$dir/lua/app/config.lua" <<'LUA'
local M = {}

function M.load()
  return { port = 8080, host = "localhost" }
end

return M
LUA
cat > "$dir/lua/app/server.lua" <<'LUA'
local config = require("app.config")
local routes = require("app.routes.users")

local M = {}

function M.boot()
  local app = { handlers = {} }
  local cfg = config.load()
  routes.mount(app)
  return app, cfg.port
end

return M
LUA
cat > "$dir/lua/app/routes/users.lua" <<'LUA'
local M = {}

function M.mount(app)
  app.handlers["/users"] = function()
    return { status = 200 }
  end
end

return M
LUA
printf '# app\n\nA small server.\n' > "$dir/README.md"
g add -A && g commit -q -m "initial" && g push -q origin master
git -C "$dir" remote set-head origin master >/dev/null

g switch -q -c feature/config
cat > "$dir/lua/app/config.lua" <<'LUA'
local M = {}

function M.load_config(env)
  local port = tonumber(os.getenv("PORT")) or 8080
  return { port = port, host = env.host or "localhost", debug = env.debug }
end

return M
LUA
cat > "$dir/lua/app/server.lua" <<'LUA'
local config = require("app.config")
local routes = require("app.routes.users")

local M = {}

function M.boot(env)
  local app = { handlers = {} }
  local cfg = config.load_config(env)
  routes.mount(app, cfg)
  return app, cfg.port
end

return M
LUA
cat > "$dir/lua/app/routes/users.lua" <<'LUA'
local M = {}

function M.mount(app, cfg)
  app.handlers["/users"] = function()
    return { status = 200 }
  end
  if cfg.debug then
    app.handlers["/debug"] = function()
      return { status = 200, body = cfg }
    end
  end
end

return M
LUA
printf '# app\n\nA small server. Set PORT to change the port.\n' > "$dir/README.md"
g commit -qam "read the port from the environment"
