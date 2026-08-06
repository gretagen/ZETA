-- manifest.lua -- normalization and validation of package.lua manifests.
--
-- Every manifest is a single Lua file returning a table:
--
--   return {
--     name, version, summary, url, sha256, arch, deps, prefix,
--     archive = { strip = N },          -- declarative binary install
--     files   = { "usr/bin/foo" },      -- optional whitelist of committed paths
--     install = function(p) ... end,    -- custom binary install
--     build   = function(p) ... end,    -- build-from-source
--     test    = function(p) ... end,    -- optional verification hook (-Test)
--   }
--
-- Exactly one of archive / install / build must be present. Validation here
-- is strict because bad manifests are the most common source of broken or
-- unsafe installs.

local manifest = {}

local path = require("path")
local vercmp = require("vercmp")
local sandbox = require("sandbox")
local log = require("log")

local KNOWN_KEYS = {
  "name", "version", "summary", "url", "sha256", "arch", "prefix",
  "deps", "files", "archive", "install", "build", "test",
}

local HEX64 = "^" .. string.rep("%x", 64) .. "$"

-- Normalize a user-provided relative path ("/usr/bin/foo", "usr/bin/foo",
-- "./usr/bin/foo") into the canonical root-relative form "usr/bin/foo".
local function clean_rel(p)
  p = p:gsub("^%./+", "")
  p = p:gsub("^/+", "")
  p = p:gsub("/+$", "")
  return p
end

function manifest.normalize(raw)
  if type(raw) ~= "table" then
    error("package.lua must return a table", 2)
  end

  local name = raw.name
  if type(name) ~= "string" or not path.sanitize_name(name) then
    error("manifest: missing or invalid package name", 2)
  end
  local version = raw.version
  if type(version) ~= "string" or version == "" then
    error(("manifest: package %q missing version"):format(name), 2)
  end

  local m = {
    name = name,
    version = version,
    summary = type(raw.summary) == "string" and raw.summary or nil,
    url = type(raw.url) == "string" and raw.url or nil,
    sha256 = nil,
    arch = type(raw.arch) == "string" and raw.arch or nil,
    prefix = type(raw.prefix) == "string" and raw.prefix or "/usr",
    deps = {},
    files = nil,
    archive = nil,
    install = nil,
    build = nil,
    test = nil,
  }

  if raw.sha256 ~= nil then
    if type(raw.sha256) ~= "string" or not raw.sha256:lower():match(HEX64) then
      error(("manifest: package %q sha256 must be exactly 64 hex characters"):format(name), 2)
    end
    m.sha256 = raw.sha256:lower()
  end

  -- A URL must be http(s) or a "safe" local reference (no whitespace/backslash,
  -- so it can never smuggle shell metacharacters or query noise into commands).
  if m.url then
    if not m.url:match("^https?://") and m.url:match("[%s\\]") then
      error(("manifest: package %q url %q looks unsafe"):format(name, m.url), 2)
    end
  end

  -- Dependencies: names or NAME OP VERSION constraints.
  if raw.deps ~= nil then
    if type(raw.deps) ~= "table" then
      error(("manifest: package %q deps must be a list"):format(name), 2)
    end
    for _, d in ipairs(raw.deps) do
      local parsed, err = vercmp.parse_dep(d)
      if not parsed then
        error(("manifest: package %q: %s"):format(name, err), 2)
      end
      if parsed.name == name then
        error(("manifest: package %q depends on itself"):format(name), 2)
      end
      m.deps[#m.deps + 1] = parsed
    end
  end

  -- Optional whitelist of committed paths (relative to the install root).
  if raw.files ~= nil then
    if type(raw.files) ~= "table" then
      error(("manifest: package %q files must be a list"):format(name), 2)
    end
    local seen = {}
    local files = {}
    for _, f in ipairs(raw.files) do
      if type(f) ~= "string" or f == "" then
        error(("manifest: package %q has an empty files entry"):format(name), 2)
      end
      local rel = clean_rel(f)
      if rel == "" or not path.relative_inside(rel) then
        error(("manifest: package %q files entry %q escapes the root"):format(name, f), 2)
      end
      if seen[rel] then
        error(("manifest: package %q lists %q twice in files"):format(name, rel), 2)
      end
      seen[rel] = true
      files[#files + 1] = rel
    end
    m.files = files
  end

  if raw.archive ~= nil then
    if type(raw.archive) ~= "table" then
      error(("manifest: package %q archive must be a table"):format(name), 2)
    end
    local strip = raw.archive.strip or 0
    if type(strip) ~= "number" or strip < 0 or strip % 1 ~= 0 then
      error(("manifest: package %q archive.strip must be a non-negative integer"):format(name), 2)
    end
    m.archive = { strip = strip }
  end

  if raw.install ~= nil then
    if type(raw.install) ~= "function" then
      error(("manifest: package %q install must be a function"):format(name), 2)
    end
    m.install = raw.install
  end

  if raw.build ~= nil then
    if type(raw.build) ~= "function" then
      error(("manifest: package %q build must be a function"):format(name), 2)
    end
    m.build = raw.build
  end

  -- Optional verification hook used by -Test. It is not an install strategy,
  -- so it does not participate in the exactly-one rule below.
  if raw.test ~= nil then
    if type(raw.test) ~= "function" then
      error(("manifest: package %q test must be a function"):format(name), 2)
    end
    m.test = raw.test
  end

  -- Exactly one install strategy is allowed.
  local count = (m.archive and 1 or 0) + (m.install and 1 or 0) + (m.build and 1 or 0)
  if count ~= 1 then
    error(("manifest: package %q needs exactly one of archive/install/build"):format(name), 2)
  end

  if m.archive and not m.url then
    error(("manifest: package %q archive mode requires a url"):format(name), 2)
  end

  -- Remote payloads MUST have a checksum; local payloads may omit it (the
  -- maintainer controls the local tree), though Zeta still warns on install.
  if m.url and m.url:match("^https?://") and not m.sha256 then
    error(("manifest: package %q must declare sha256 for a remote url"):format(name), 2)
  end

  -- Flag unknown fields (forward compatibility) so typos are visible.
  for k in pairs(raw) do
    local known = false
    for _, kk in ipairs(KNOWN_KEYS) do
      if k == kk then known = true break end
    end
    if not known then
      log.warn(("manifest: package %q has unknown field %q (ignored)"):format(name, tostring(k)))
    end
  end

  return m
end

-- Load + validate a manifest file from disk. Returns manifest or nil, err.
function manifest.load(filepath)
  local chunk, err = sandbox.loadfile(filepath)
  if not chunk then return nil, err end
  local ok, raw = pcall(chunk)
  if not ok then
    return nil, ("package.lua runtime error: %s"):format(tostring(raw))
  end
  local ok2, m = pcall(manifest.normalize, raw)
  if not ok2 then
    return nil, tostring(m)
  end
  return m
end

-- Load + validate manifest Lua source (used for remote package.lua files).
function manifest.load_string(src, name)
  local chunk, err = sandbox.compile(src, name or "=(package.lua)")
  if not chunk then return nil, err end
  local ok, raw = pcall(chunk)
  if not ok then
    return nil, ("package.lua runtime error: %s"):format(tostring(raw))
  end
  local ok2, m = pcall(manifest.normalize, raw)
  if not ok2 then
    return nil, tostring(m)
  end
  return m
end

-- A manifest fetched from <repo>/<name>/package.lua (or a local
-- <pkgdir>/package.lua) must declare the name it was requested under, so a
-- repo can't serve a mismatched package.
function manifest.check_name(m, expected)
  if m.name ~= expected then
    return nil, ("manifest declares name %q but was requested as %q"):format(m.name, expected)
  end
  return true
end

return manifest
