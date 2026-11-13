-- path.lua -- filesystem path helpers shared by every Zeta module.
--
-- Everything here is plain POSIX: string manipulation plus `mkdir -p`,
-- `cp -a`, etc. All paths are derived from environment variables (see
-- config.lua) and validated before use.

local path = {}

-- ---------------------------------------------------------------------------
-- Cleanup hooks for signal handling
-- ---------------------------------------------------------------------------

-- Functions registered here are called by path.run_cleanup() so background
-- processes (spinner, download scripts) are killed on Ctrl+C.
local cleanup_hooks = {}

function path.on_cleanup(fn)
  cleanup_hooks[#cleanup_hooks + 1] = fn
end

function path.remove_cleanup(fn)
  for i = #cleanup_hooks, 1, -1 do
    if cleanup_hooks[i] == fn then
      table.remove(cleanup_hooks, i)
      return
    end
  end
end

function path.run_cleanup()
  for _, fn in ipairs(cleanup_hooks) do fn() end
end

-- ---------------------------------------------------------------------------
-- String helpers
-- ---------------------------------------------------------------------------

-- Join path components with a single separator. Only the first non-empty
-- component decides whether the result is absolute; later components are
-- treated as plain name pieces even if they happen to carry a leading slash.
function path.join(...)
  local parts = {}
  local abs = false
  local first = true
  for i = 1, select("#", ...) do
    local part = tostring((select(i, ...)))
    if part == "/" then
      if first then abs = true end
    elseif part ~= "" then
      local p = part:gsub("^/+", ""):gsub("/+$", "")
      if p ~= "" then
        if first then abs = (part:match("^/") ~= nil) end
        parts[#parts + 1] = p
      end
    end
    first = false
  end
  if #parts == 0 then return "/" end
  local out = table.concat(parts, "/")
  if abs then out = "/" .. out end
  return out
end

function path.is_abs(p)
  return p:match("^/") ~= nil
end

function path.basename(p)
  p = p:gsub("/+$", "")
  return p:match("[^/]+$") or p
end

function path.dirname(p)
  p = p:gsub("/+$", "")
  if p == "" then return "." end
  local d = p:match("^(.*)/[^/]+$")
  if not d then return "." end
  if d == "" then return "/" end
  return d
end

-- Quote a value for safe use in a single shell command. Values that contain
-- only "safe" characters are returned as-is (fast path); anything else is
-- wrapped in single quotes with embedded quotes escaped.
function path.quote(s)
  if s == "" then return "''" end
  if s:match("^[%w%._%/+%-:=@,]+$") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- True if the relative path never climbs above the root (".." escape).
function path.relative_inside(p)
  local depth = 0
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      depth = depth - 1
      if depth < 0 then return false end
    elseif seg ~= "." then
      depth = depth + 1
    end
  end
  return true
end

-- True if a symlink located at `rel` whose target is `target` would escape
-- the installation root. Absolute targets are allowed — they resolve at
-- runtime against the real root. Relative targets are checked for ".."
-- traversal that would climb above the root.
function path.symlink_escapes(rel, target)
  if not target or target == "" then return false end
  local dir = rel:match("^(.*)/[^/]+$") or ""
  local combined = dir .. "/" .. target
  return not path.relative_inside(combined)
end

-- Package/dependency names are used to build repo URLs and database paths,
-- so they must be tightly constrained. This rejects anything containing "/",
-- "..", leading dots, or any other character outside [A-Za-z0-9_.+-].
function path.sanitize_name(name)
  if type(name) ~= "string" then return nil end
  if name == "" then return nil end
  if name:match("^%.") then return nil end
  if not name:match("^[%w%._+%-]+$") then return nil end
  return name
end

-- ---------------------------------------------------------------------------
-- Subprocess helpers
-- ---------------------------------------------------------------------------

-- Resolve the shell used for every subprocess. /bin/sh is not guaranteed to
-- be POSIX-bash (e.g. Haliade's lean custom shell 'thesh' lacks redirections,
-- $(...) substitution and control flow), so prefer bash when it exists and
-- fall back to sh. The probe is deliberately minimal so the system sh (even a
-- stripped one) can parse it: `bash -c 'echo OK'`.
local function detect_shell()
  -- Ask bash for its own absolute path (we need it for shebangs too). The
  -- outer probe stays minimal so the system sh (even a stripped one) parses
  -- it; the inner `command -v bash` runs inside bash itself.
  local f = io.popen("bash -c 'command -v bash'")
  if f then
    local out = f:read("*l")
    f:close()
    if out and out:match("^/") then return out end
  end
  return "/bin/sh"
end

path.shell = detect_shell()

-- Run a command through the resolved shell. Zero overhead on systems where
-- /bin/sh already is bash; correctness on systems where it is not.
function path.run(cmd)
  local a, b, c = os.execute(path.shell .. " -c " .. path.quote(cmd))
  if type(a) == "number" then return a == 0 end
  return a == true and b == "exit" and c == 0
end

-- io.popen through the resolved shell, matching path.run. Prefer this over
-- raw io.popen(cmd) so captured-output commands behave identically.
function path.popen(cmd)
  return io.popen(path.shell .. " -c " .. path.quote(cmd))
end

-- ---------------------------------------------------------------------------
-- Signal-safe subprocess helpers
-- ---------------------------------------------------------------------------
--
-- os.execute() is system(3), and POSIX requires system() to block SIGINT for
-- the whole call. ZETA's download monitor loops sit inside os.execute ~100%
-- of the time (a `kill -0` poll followed by a `sleep`), so Ctrl+C was ignored
-- there and the cleanup hooks never ran. io.popen() carries no such rule: the
-- signal stays live, Lua's handler fires as soon as the read wakes, and
-- zeta.lua's pcall then drains the cleanup hooks.

-- Sleep while staying interruptible.
function path.sleep(secs)
  local f = io.popen(path.shell .. " -c " .. path.quote("sleep " .. tostring(secs)))
  if f then f:read("*a"); f:close() end
end

-- True while `pid` is still running. Interruptible, like path.sleep().
function path.alive(pid)
  if not pid then return false end
  local f = path.popen("kill -0 " .. tostring(pid) .. " 2>/dev/null && echo YES || echo NO")
  if not f then return false end
  local out = f:read("*l")
  f:close()
  return out == "YES"
end

-- Run a command the user sits in front of (a download) and still get its exit
-- status. stdout is captured and discarded -- every caller here writes to a
-- file with -o/-O -- while stderr stays on the terminal exactly as it did
-- under path.run. Blocking inside f:read() keeps SIGINT live, which is why
-- Ctrl+C lands during a transfer at all.
--
-- The child reports its own pid on the first line, before any real output, so
-- a cleanup hook can be registered *before* the blocking read: if that read is
-- interrupted, zeta.lua drains the hooks and takes the process group down
-- rather than leaving curl orphaned. Returns ok[, rc][, pid].
function path.run_interruptible(cmd)
  -- setsid makes that pid the session leader so it doubles as the process
  -- group id, and keeps the job out of the terminal's foreground group so the
  -- terminal's own SIGINT cannot race our cleanup.
  local inner = "echo ZETA_PID=$$; " .. path.shell .. " -c " .. path.quote(cmd)
    .. "; printf 'ZETA_RC=%d' \"$?\""
  local prefix = path.have_setsid() and "setsid " or ""
  local f = io.popen(prefix .. path.shell .. " -c " .. path.quote(inner))
  if not f then return false, 127, nil end

  local first = f:read("*l")
  local pid = first and tonumber(first:match("ZETA_PID=(%d+)")) or nil
  local hook
  if pid then
    hook = function() path.kill_tree(pid) end
    path.on_cleanup(hook)
  end

  local rest = f:read("*a") or ""
  f:close()
  if hook then path.remove_cleanup(hook) end

  local rc = tonumber(rest:match("ZETA_RC=(%d+)%s*$"))
  if rc == nil then return false, nil, pid end
  return rc == 0, rc, pid
end

-- ---------------------------------------------------------------------------
-- Background jobs that can be killed as a tree
-- ---------------------------------------------------------------------------
--
-- A job started with `&` from a non-interactive shell has SIGINT ignored, so
-- the `trap ... INT; kill 0` in ZETA's download scripts can never fire -- and
-- killing only the script's pid leaves the curl/wget it spawned running (both
-- verified). Launch under setsid so the job owns a process group, then one
-- kill to that group takes the whole tree.
local setsid_ok

function path.have_setsid()
  if setsid_ok == nil then
    local f = path.popen("command -v setsid >/dev/null 2>&1 && echo YES || echo NO")
    if f then
      local out = f:read("*l")
      f:close()
      setsid_ok = out == "YES"
    else
      setsid_ok = false
    end
  end
  return setsid_ok
end

-- Launch `cmd` in the background and return its pid, or nil.
-- The pid doubles as the process-group id when setsid is used, which is what
-- lets path.kill_tree() reach the job's children. `$$` is recorded rather than
-- `$!`: if setsid ever has to fork, `$!` names the short-lived parent while
-- `$$` always names the real session leader.
function path.spawn_bg(cmd, pidfile)
  os.remove(pidfile)
  local launch
  if path.have_setsid() then
    launch = "setsid " .. path.shell .. " -c " ..
      path.quote("echo $$ > " .. path.quote(pidfile) .. "; exec " .. cmd)
  else
    launch = cmd .. " & echo $! > " .. path.quote(pidfile)
  end
  path.run(launch .. " </dev/null &")

  local pid
  for _ = 1, 40 do
    local f = io.open(pidfile, "rb")
    if f then
      pid = tonumber(f:read("*a"))
      f:close()
      if pid then break end
    end
    path.sleep(0.005)
  end
  os.remove(pidfile)
  return pid
end

-- Stop a job started by path.spawn_bg(), taking everything it spawned with it.
function path.kill_tree(pid)
  if not pid then return end
  if path.have_setsid() then
    -- A negative pid names a process group, and it keeps working after the
    -- leader has exited -- exactly the case where its children were orphaned.
    path.run("kill -TERM -- -" .. tostring(pid) .. " 2>/dev/null")
  else
    path.run("kill " .. tostring(pid) .. " 2>/dev/null")
  end
end

-- mkdir -p wrapper. Safe: the directory name is shell-quoted.
function path.mkdir_p(dir)
  if dir == "" or dir == "/" then return true end
  return path.run("mkdir -p " .. path.quote(dir))
end

-- readlink wrapper: returns the symlink target, or nil when `p` is not a
-- symlink (readlink(1) prints nothing and exits non-zero otherwise).
function path.readlink(p)
  local f = path.popen("readlink " .. path.quote(p) .. " 2>/dev/null")
  if not f then return nil end
  local target = f:read("*l")
  f:close()
  if target == nil or target == "" then return nil end
  return target
end

-- True if a file or directory exists (never follows a dangling symlink as a
-- hit, which matters for package-tree discovery).
function path.exists(p)
  local f = io.open(p, "rb")
  if f then
    f:close()
    return true
  end
  local r = path.run("test -e " .. path.quote(p) .. " -o -L " .. path.quote(p))
  return r
end

-- Return the numeric uid and octal permission mode of a file, or nil on
-- failure. Used by hooks to verify that hook files and their parent
-- directories are owned by root and not writable by group or world.
function path.stat_owner_and_perms(filepath)
  local f = path.popen("stat -c '%u %a' " .. path.quote(filepath) .. " 2>/dev/null")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  if not line then return nil end
  local uid, perms = line:match("^(%d+)%s+(%d+)$")
  if not uid then return nil end
  return tonumber(uid), tonumber(perms)
end

return path
