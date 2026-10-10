-- repo.lua -- remote repository access.
--
-- The client can consult several repositories at once, in order. Each
-- repository has the same fixed and simple layout:
--
--   <base>/packages/<name>/package.lua  -- per-package manifest
--   <base>/packages/index.lua           -- optional search index for -Localize
--
-- config.get().repos is the consultation list: fetch_manifest tries each
-- repository and the first to yield a valid manifest wins, so a package name
-- present in an earlier repository shadows the same name in a later one.
-- Package names are sanitized before being spliced into URLs, so a name can
-- never escape the repository path ("../" traversal). Indexes from every
-- repository are merged (first name wins) for -Localize, and each entry
-- carries an optional `origin` label naming the artifact repository.
--
-- repo.manifest_url/index_url are convenience accessors for the *first*
-- configured repository (used to label manifests and to warm the parallel
-- prefetch); resolution itself always walks the full list.

local repo = {}

local config = require("config")
local fetch = require("fetch")
local manifest = require("manifest")
local path = require("path")
local sandbox = require("sandbox")
local log = require("log")

-- The configured repository list, in consultation order.
function repo.list()
  return config.get().repos
end

function repo.manifest_url(name)
  return path.join(repo.list()[1], "packages", name, "package.lua")
end

function repo.index_url()
  return path.join(repo.list()[1], "packages", "index.lua")
end

-- Fetch and validate a package manifest, trying every configured repository
-- in order. Returns the first valid manifest or nil, err.
function repo.fetch_manifest(name)
  name = path.sanitize_name(name)
  if not name then
    return nil, ("invalid package name %q"):format(tostring(name))
  end
  local repos = repo.list()
  local last_err
  for _, base in ipairs(repos) do
    local url = path.join(base, "packages", name, "package.lua")
    log.detail(("fetching manifest %s"):format(url))
    local src, err = fetch.read(url)
    if not src then
      last_err = err
    else
      local m, merr = manifest.load_string(src, url)
      if not m then
        last_err = merr
      else
        local ok, cerr = manifest.check_name(m, name)
        if not ok then
          return nil, cerr
        end
        return m
      end
    end
  end
  if #repos == 0 then
    return nil, "no repositories configured"
  end
  return nil, ("could not fetch %q from any of %d configured repositories: %s"):format(
    name, #repos, tostring(last_err or "not found"))
end

-- Fetch and merge the search indexes of every configured repository into a
-- single list, first repository to declare a name winning. Each entry keeps
-- the optional `origin` label from its index. Returns a list or nil, err when
-- nothing could be loaded.
function repo.fetch_index()
  local repos = repo.list()
  local merged, seen = {}, {}
  local any_err
  for _, base in ipairs(repos) do
    local url = path.join(base, "packages", "index.lua")
    log.detail(("fetching index %s"):format(url))
    local src, err = fetch.read(url)
    if not src then
      any_err = any_err or err
    else
      local chunk, cerr = sandbox.compile(src, url)
      if not chunk then
        any_err = any_err or cerr
      else
        local ok, raw = pcall(chunk)
        if not ok or type(raw) ~= "table" then
          any_err = any_err or "index.lua did not return a list"
        else
          for _, entry in ipairs(raw) do
            if type(entry) == "table" and type(entry.name) == "string" and not seen[entry.name] then
              seen[entry.name] = true
              merged[#merged + 1] = {
                name = entry.name,
                version = type(entry.version) == "string" and entry.version or nil,
                summary = type(entry.summary) == "string" and entry.summary or nil,
                -- Optional artifact repository label (newer indexes); nil when absent.
                origin = type(entry.origin) == "string" and entry.origin ~= "" and entry.origin or nil,
              }
            end
          end
        end
      end
    end
  end
  if #merged == 0 and (#repos == 0 or any_err) then
    return nil, any_err or "no repositories configured"
  end
  return merged
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
-- the payload actually lives in. A "zeta-<repo>" segment (present in both
-- github.com/gretagen/zeta-providence/... and files.spectoria.dev/zeta-monsters/...)
-- maps to <repo>. Other GitHub repositories owned by gretagen map to their
-- repository name (e.g. declarative-plugins); GitHub repositories owned by
-- anyone else are "upstream". A manifest without a url is a metapackage;
-- non-GitHub hosts are reported by host.
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
  -- GitHub raw/release URLs: gretagen's own repos are labelled by repository
  -- name (stripping a "zeta-" prefix when present); other owners are upstream.
  local owner, rname = url:match("^https?://raw%.githubusercontent%.com/([^/]+)/([^/#?]+)")
  if not owner then
    owner, rname = url:match("^https?://[^/]*github%.com/([^/]+)/([^/#?]+)")
  end
  if owner then
    if owner:lower() == "gretagen" and rname and rname ~= "" then
      return (rname:gsub("^zeta%-", "")):lower()
    end
    return "upstream"
  end
  local host = url:match("^%a[%w+.-]*://([^/@]+)")
  if host and host ~= "" then
    return (host:gsub("^www%.", "")):lower()
  end
  return "unknown"
end

-- Resolve artifact-repository origins for a list of package names when the
-- index predates the `origin` field. Each name's manifest is searched across
-- every configured repository (first hit wins), and the downloads run in
-- parallel. Names that cannot be resolved map to "unknown" (never an error --
-- -Localize must still print its results). Returns a map name -> label.
function repo.origins(names)
  local repos = repo.list()
  local out = {}
  local items = {}
  local order = {}      -- unique resolved names, first-seen order
  local index_of = {}   -- name -> item indices, one per repository
  local seen = {}
  local tmp = config.get().tmp_dir
  for _, raw_name in ipairs(names) do
    local name = path.sanitize_name(raw_name)
    if name and not seen[name] then
      seen[name] = true
      order[#order + 1] = name
      index_of[name] = {}
      for bi, base in ipairs(repos) do
        items[#items + 1] = {
          name = name,
          bi = bi,
          url = path.join(base, "packages", name, "package.lua"),
          dest = path.join(tmp, ("origin-%s-%d.lua"):format(name, bi)),
        }
        index_of[name][#index_of[name] + 1] = #items
      end
    end
  end
  if #items == 0 then return out end

  local results = fetch.get_parallel(items, { label = "resolving origins (%d)" })
  for _, name in ipairs(order) do
    local best, best_bi
    for _, idx in ipairs(index_of[name]) do
      local r = results[idx]
      if r and r.dest then
        local f = io.open(r.dest, "rb")
        local src
        if f then src = f:read("*a"); f:close() end
        os.remove(r.dest)
        if src then
          local m = manifest.load_string(src, items[idx].url)
          if m and (not best_bi or items[idx].bi < best_bi) then
            best = repo.origin_from_url(m.url)
            best_bi = items[idx].bi
          end
        end
      end
    end
    out[name] = best or "unknown"
  end
  return out
end

return repo
