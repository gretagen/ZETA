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
        -- Optional artifact repository label (newer indexes); nil when absent.
        origin = type(entry.origin) == "string" and entry.origin ~= "" and entry.origin or nil,
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

-- Map an artifact `url` to a short, lowercase origin label: the repository
-- the payload actually lives in. Most urls carry a "zeta-<repo>" segment
-- (github.com/gretagen/zeta-providence/..., files.spectoria.dev/zeta-monsters/...).
-- A manifest without a url is a metapackage; anything that isn't a local or
-- gretagen-hosted artifact is reported by host (or "upstream" for GitHub).
function repo.origin_from_url(url)
  if type(url) ~= "string" or url == "" then
    return "meta"
  end
  local z = url:match("zeta%-([%w_]+)")
  if z then return z:lower() end
  if url:match("^file://") or url:match("^/")
     or not url:match("^%a[%w+.-]*://") then
    return "local"
  end
  if url:match("github%.com") then
    return "upstream"
  end
  local host = url:match("^%a[%w+.-]*://([^/@]+)")
  if host and host ~= "" then
    return (host:gsub("^www%.", "")):lower()
  end
  return "unknown"
end

-- Resolve artifact-repository origins for a list of package names by
-- downloading each package.lua and mapping its `url`. Only needed when the
-- index predates the `origin` field. Downloads run in parallel; names that
-- cannot be resolved map to "unknown" (never an error -- -Localize must still
-- print its results). Returns a map name -> label.
function repo.origins(names)
  local out = {}
  local items = {}
  local seen = {}
  local tmp = config.get().tmp_dir
  for _, raw_name in ipairs(names) do
    local name = path.sanitize_name(raw_name)
    if name and not seen[name] then
      seen[name] = true
      items[#items + 1] = {
        name = name,
        url = repo.manifest_url(name),
        dest = path.join(tmp, "origin-" .. name .. ".lua"),
        label = name,
      }
    end
  end
  if #items == 0 then return out end

  local results = fetch.get_parallel(items, { label = "resolving origins (%d)" })
  for i, item in ipairs(items) do
    local label = "unknown"
    local r = results[i]
    if r and r.dest then
      local f = io.open(r.dest, "rb")
      local src
      if f then src = f:read("*a"); f:close() end
      os.remove(r.dest)
      if src then
        local m = manifest.load_string(src, item.url)
        if m then label = repo.origin_from_url(m.url) end
      end
    end
    out[item.name] = label
  end
  return out
end

return repo
