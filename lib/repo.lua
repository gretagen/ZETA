-- repo.lua -- remote repository access.
--
-- The repository layout is fixed and simple:
--
--   <ZETA_REPO>/packages/<name>/package.lua  -- per-package manifest
--   <ZETA_REPO>/packages/index.lua          -- optional search index for -Localize
--
-- Package names are sanitized before being spliced into URLs, so a name can
-- never escape the repository path ("../" traversal). The index, when
-- present, is itself a sandboxed Lua file returning a list of
-- { name, version, summary } entries.

local repo = {}

local config = require("config")
local fetch = require("fetch")
local manifest = require("manifest")
local path = require("path")
local sandbox = require("sandbox")
local log = require("log")

function repo.manifest_url(name)
  return path.join(config.get().repo, "packages", name, "package.lua")
end

function repo.index_url()
  return path.join(config.get().repo, "packages", "index.lua")
end

-- Fetch and validate a package manifest from the repository.
function repo.fetch_manifest(name)
  name = path.sanitize_name(name)
  if not name then
    return nil, ("invalid package name %q"):format(tostring(name))
  end
  local url = repo.manifest_url(name)
  log.detail(("fetching manifest %s"):format(url))
  local src, err = fetch.read(url)
  if not src then
    return nil, ("could not fetch %s: %s"):format(url, tostring(err))
  end
  local m, merr = manifest.load_string(src, url)
  if not m then return nil, merr end
  local ok, cerr = manifest.check_name(m, name)
  if not ok then return nil, cerr end
  return m
end

-- Fetch the search index. Returns a list or nil, err.
function repo.fetch_index()
  local url = repo.index_url()
  log.detail(("fetching index %s"):format(url))
  local src, err = fetch.read(url)
  if not src then
    return nil, ("could not fetch %s: %s"):format(url, tostring(err))
  end
  local chunk, cerr = sandbox.compile(src, url)
  if not chunk then return nil, cerr end
  local ok, raw = pcall(chunk)
  if not ok or type(raw) ~= "table" then
    return nil, "index.lua did not return a list"
  end
  local list = {}
  for _, entry in ipairs(raw) do
    if type(entry) == "table" and type(entry.name) == "string" then
      list[#list + 1] = {
        name = entry.name,
        version = type(entry.version) == "string" and entry.version or nil,
        summary = type(entry.summary) == "string" and entry.summary or nil,
      }
    end
  end
  return list
end

-- Case-insensitive substring search over name + summary + version.
function repo.search(query)
  local list, err = repo.fetch_index()
  if not list then return nil, err end
  local q = query:lower()
  local matches = {}
  for _, e in ipairs(list) do
    local hay = (e.name .. " " .. (e.summary or "") .. " " .. (e.version or "")):lower()
    if hay:find(q, 1, true) then
      matches[#matches + 1] = e
    end
  end
  return matches
end

return repo
