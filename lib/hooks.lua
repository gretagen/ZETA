-- hooks.lua -- runtime execution of post-transaction package hooks.
--
-- A package may ship hook files under usr/share/zeta/hooks/*.hook (the
-- toolchain validates and packages these at build time). Each hook is a
-- pure-data Lua file returning:
--
--   return {
--     order   = 50,
--     trigger = { op = "install", type = "package", target = { "mypkg" } },
--     action  = { when = "post", exec = "true", description = "..." },
--   }
--
-- After an install transaction completes, every hook installed in the root
-- is evaluated against the set of packages just installed. Hooks whose
-- trigger matches and whose action.when == "post" have action.exec run
-- through the shell. This lets a package perform post-install work that
-- depends on its payload being committed and its dependencies present
-- (e.g. dkms rebuilding kernel modules after the driver source lands).
--
-- Executed commands carry the same trust as a package's install/build
-- functions: the hook ships inside the package itself, so it is no more or
-- less privileged than the code that staged its payload.

local hooks = {}

local config = require("config")
local log = require("log")
local path = require("path")
local sandbox = require("sandbox")

-- Load and validate a hook file from the installed root. Returns the hook
-- table or raises.
local function load_hook(filepath)
  local chunk, err = sandbox.loadfile(filepath)
  if not chunk then
    error(("hook %q: %s"):format(filepath, tostring(err)), 0)
  end
  local ok, raw = pcall(chunk)
  if not ok then
    error(("hook %q: runtime error: %s"):format(filepath, tostring(raw)), 0)
  end
  if type(raw) ~= "table" then
    error(("hook %q: must return a table"):format(filepath), 0)
  end
  if type(raw.trigger) ~= "table" then
    error(("hook %q: missing trigger table"):format(filepath), 0)
  end
  if type(raw.action) ~= "table" then
    error(("hook %q: missing action table"):format(filepath), 0)
  end
  return raw
end

-- True when the hook's trigger matches a transaction that installed any of
-- `installed` (a set of package names). A trigger with no target list fires
-- on every install transaction.
local function trigger_matches(trigger, installed)
  if trigger.op and trigger.op ~= "install" then return false end
  if trigger.type and trigger.type ~= "package" then return false end
  local targets = trigger.target
  if type(targets) == "table" and #targets > 0 then
    for _, t in ipairs(targets) do
      if installed[t] then return true end
    end
    return false
  end
  return true
end

-- Run hooks. `installed` is a map of package names -> true for every package
-- installed by the just-completed transaction. Hooks are executed in `order`
-- ascending; failures are logged and collected, never fatal (the payload is
-- already committed and recorded). Returns the number of hooks that failed.
function hooks.run_installed(installed)
  local hooks_dir = path.join(config.get().root, "usr/share/zeta/hooks")
  if not path.exists(hooks_dir) then
    return 0
  end

  local f = io.popen("find " .. path.quote(hooks_dir)
    .. " -type f -name '*.hook' 2>/dev/null | sort")
  if not f then return 0 end
  local files = {}
  for line in f:lines() do files[#files + 1] = line end
  f:close()
  if #files == 0 then return 0 end

  local pending = {}
  for _, filepath in ipairs(files) do
    local ok, hook = pcall(load_hook, filepath)
    if not ok then
      log.warn(tostring(hook))
    elseif trigger_matches(hook.trigger, installed) then
      pending[#pending + 1] = {
        file = filepath,
        order = hook.order or 100,
        action = hook.action,
      }
    end
  end
  if #pending == 0 then return 0 end

  table.sort(pending, function(a, b) return a.order < b.order end)

  local failures = 0
  for _, h in ipairs(pending) do
    local exec = h.action.exec
    if exec and exec ~= "" then
      local when = h.action.when or "post"
      if when == "post" then
        log.step(("running hook %s"):format(h.file))
        if path.run(exec) then
          log.ok(("hook ok: %s"):format(h.action.description or h.file))
        else
          failures = failures + 1
          log.error(("hook failed: %s (%s)"):format(
            h.action.description or h.file, exec))
        end
      end
    end
  end
  return failures
end

return hooks
