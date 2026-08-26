-- path.lua -- filesystem path helpers shared by every Zeta module.
--
-- Everything here is plain POSIX: string manipulation plus `mkdir -p`,
-- `cp -a`, etc. All paths are derived from environment variables (see
-- config.lua) and validated before use.

local path = {}

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
-- the installation root. Absolute targets always escape (Zeta relocates
-- staging trees into ZETA_ROOT, which may not be "/"), and relative targets
-- are resolved against the symlink's directory.
function path.symlink_escapes(rel, target)
  if not target or target == "" then return false end
  if target:match("^/") then return true end
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

-- Run a command, streaming its output to the parent (verbose by construction).
-- Returns true on exit status 0. Handles the os.execute return conventions of
-- Lua 5.1 (numeric code) and Lua 5.2+ (status, "exit"/"signal", code).
function path.run(cmd)
  local a, b, c = os.execute(cmd)
  if type(a) == "number" then return a == 0 end
  return a == true and b == "exit" and c == 0
end

-- mkdir -p wrapper. Safe: the directory name is shell-quoted.
function path.mkdir_p(dir)
  if dir == "" or dir == "/" then return true end
  return path.run("mkdir -p " .. path.quote(dir))
end

-- readlink wrapper: returns the symlink target, or nil when `p` is not a
-- symlink (readlink(1) prints nothing and exits non-zero otherwise).
function path.readlink(p)
  local f = io.popen("readlink " .. path.quote(p) .. " 2>/dev/null")
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

return path
