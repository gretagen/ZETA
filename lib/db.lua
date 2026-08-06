-- db.lua -- the installed-package database.
--
-- State lives at <ZETA_ROOT>/var/db/zeta/<name>/ containing:
--   meta.lua  -- a serialized manifest (return {...}), loaded under the sandbox
--   files     -- one owned relative path per line
--
-- The "files" list is the authoritative set of what -Remove may touch: removal
-- unlinks exactly those paths and then prunes now-empty parent directories.
-- Files are plain text / Lua for transparency and easy manual inspection.

local db = {}

local config = require("config")
local path = require("path")
local sandbox = require("sandbox")

-- ---------------------------------------------------------------------------
-- Minimal Lua table serializer (for meta.lua)
-- ---------------------------------------------------------------------------

local function ser(v)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local key
      if type(k) == "number" then
        key = "[" .. tostring(k) .. "]"
      elseif type(k) == "string" and k:match("^[%a_][%w_]*$") then
        key = k
      else
        key = "[" .. string.format("%q", tostring(k)) .. "]"
      end
      parts[#parts + 1] = key .. " = " .. ser(val)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  return "nil"
end

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

function db.dir()
  return config.get().state_dir
end

function db.pkg_dir(name)
  return path.join(db.dir(), name)
end

function db.meta_path(name)
  return path.join(db.dir(), name, "meta.lua")
end

function db.files_path(name)
  return path.join(db.dir(), name, "files")
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

function db.is_installed(name)
  local f = io.open(db.meta_path(name), "rb")
  if not f then return false end
  f:close()
  return true
end

function db.get(name)
  if not db.is_installed(name) then return nil end
  local chunk, err = sandbox.loadfile(db.meta_path(name))
  if not chunk then return nil end
  local ok, m = pcall(chunk)
  if not ok or type(m) ~= "table" then return nil end
  return m
end

function db.list()
  local names = {}
  local f = io.popen("ls -1 " .. path.quote(db.dir()) .. " 2>/dev/null")
  if f then
    for line in f:lines() do
      if line ~= "" and db.is_installed(line) then names[#names + 1] = line end
    end
    f:close()
  end
  table.sort(names)
  return names
end

function db.files(name)
  local f = io.open(db.files_path(name), "rb")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local files = {}
  for line in content:gmatch("[^\n]+") do
    if line ~= "" then files[#files + 1] = line end
  end
  return files
end

-- Installed packages that declare `name` as a dependency.
function db.reverse_dependents(name)
  local out = {}
  for _, n in ipairs(db.list()) do
    local m = db.get(n)
    if m and m.deps then
      for _, d in ipairs(m.deps) do
        if d == name then
          out[#out + 1] = n
          break
        end
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Mutation
-- ---------------------------------------------------------------------------

-- Record an installed package. Writes are atomic (write temp, then rename),
-- so an interrupted install never leaves a half-written database entry.
function db.record(name, meta, files)
  local dir = db.pkg_dir(name)
  path.mkdir_p(dir)
  local deps = {}
  for _, d in ipairs(meta.deps or {}) do
    deps[#deps + 1] = d.name
  end
  local m = {
    name = meta.name,
    version = meta.version,
    summary = meta.summary,
    url = meta.url,
    sha256 = meta.sha256,
    arch = meta.arch,
    prefix = meta.prefix,
    deps = deps,
    source = meta.source or "remote",
    installed_at = os.time(),
  }
  local t1 = db.meta_path(name) .. ".tmp"
  local t2 = db.files_path(name) .. ".tmp"
  local f = io.open(t1, "wb")
  f:write("return " .. ser(m) .. "\n")
  f:close()
  local g = io.open(t2, "wb")
  g:write(table.concat(files, "\n") .. "\n")
  g:close()
  os.rename(t1, db.meta_path(name))
  os.rename(t2, db.files_path(name))
end

function db.remove(name)
  path.run("rm -rf " .. path.quote(db.pkg_dir(name)))
end

return db
