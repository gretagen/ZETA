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
--
-- Security notes:
--   * The sandbox (sandbox.loadfile) only restricts the DATA DECLARATION
--     phase: the hook file is compiled in a restricted Lua environment with
--     no io/os/require access. However, action.exec is passed straight to
--     path.run() -> os.execute() and runs arbitrary shell with full
--     privileges. The sandbox does NOT restrict what exec can do.
--   * Hook files and their parent directories must be owned by root and not
--     writable by group or world (see check_hook_safety).
--   * A hook's trigger target is validated against the package that owns the
--     hook file in the database. Hooks targeting unrelated packages or with
--     no target (global) are warned about but still allowed.

local hooks = {}

local config = require("config")
local db = require("db")
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

-- Verify that a hook file and its parent directories up to the install root
-- are owned by root and not writable by group or world. Returns true if safe,
-- or nil, reason on failure.
local function check_hook_safety(filepath)
  local root = config.get().root

  -- Check the hook file itself.
  local uid, perms = path.stat_owner_and_perms(filepath)
  if not uid then
    return nil, ("could not stat hook %s"):format(filepath)
  end
  if uid ~= 0 then
    return nil, ("hook %s not owned by root (uid %d)"):format(filepath, uid)
  end
  if perms % 10 >= 2 or math.floor(perms / 10) % 10 >= 2 then
    return nil, ("hook %s has insecure permissions %04d (group/world writable)"):format(filepath, perms)
  end

  -- Walk from the hooks directory up to the install root, checking each
  -- parent. This prevents exploitation via a world-writable intermediate
  -- directory even when the hook file itself is correctly permissioned.
  local hooks_dir = path.join(root, "usr/share/zeta/hooks")
  local dir = path.dirname(filepath)
  while dir and dir ~= root and dir ~= "/" do
    -- Stop once we reach the hooks directory itself (already checked above
    -- implicitly via the file check, and we don't want to re-check root).
    if dir == hooks_dir then break end
    local d_uid, d_perms = path.stat_owner_and_perms(dir)
    if d_uid then
      if d_uid ~= 0 then
        return nil, ("directory %s not owned by root (uid %d)"):format(dir, d_uid)
      end
      if d_perms % 10 >= 2 or math.floor(d_perms / 10) % 10 >= 2 then
        return nil, ("directory %s has insecure permissions %04d"):format(dir, d_perms)
      end
    end
    dir = path.dirname(dir)
  end

  return true
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
    -- Security: verify file and directory ownership/permissions before loading.
    local safe, safe_err = check_hook_safety(filepath)
    if not safe then
      log.warn(tostring(safe_err))
    else
      local ok, hook = pcall(load_hook, filepath)
      if not ok then
        log.warn(tostring(hook))
      else
        -- Security: validate that the trigger targets the owning package.
        local root = config.get().root
        local rel = filepath:match("^" .. root .. "/?(.*)")
        if rel then
          local owner = db.file_owner(rel)
          if owner then
            local targets = hook.trigger.target
            if type(targets) == "table" and #targets > 0 then
              local found = false
              for _, t in ipairs(targets) do
                if t == owner then found = true break end
              end
              if not found then
                log.warn(("hook %s: owned by %s but trigger targets {%s}, skipping"):format(
                  filepath, owner, table.concat(targets, ", ")))
                goto continue
              end
            elseif targets == nil or (type(targets) == "table" and #targets == 0) then
              log.warn(("hook %s: owned by %s but trigger has no target (global hook)"):format(
                filepath, owner))
            end
          end
        end

        if trigger_matches(hook.trigger, installed) then
          pending[#pending + 1] = {
            file = filepath,
            order = hook.order or 100,
            action = hook.action,
          }
        end
      end
    end
    ::continue::
  end
  if #pending == 0 then return 0 end

  table.sort(pending, function(a, b) return a.order < b.order end)

  local failures = 0
  for _, h in ipairs(pending) do
    local exec = h.action.exec
    -- exec must be a string; non-string types (table, number, bool) are
    -- rejected here rather than passed to os.execute where they would be
    -- coerced to a string representation.
    if type(exec) == "string" and exec ~= "" then
      local when = h.action.when or "post"
      if when == "post" then
        log.step(("running hook %s"):format(h.file))
        -- NOTE: exec runs with full privileges; the sandbox only covers
        -- the data declaration phase above.
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
