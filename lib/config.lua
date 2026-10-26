-- config.lua -- configuration with layered precedence:
--   1. Environment variables (highest priority)
--   2. /etc/zeta/configuration.lua (config file)
--   3. Built-in defaults (lowest priority)
--
-- ZETA_ROOT is how Zeta stays "rooted" and testable: point it at a scratch
-- directory and every install, database write, and deletion happens under it.
--
-- The client can consult several remote repositories at once. `repos` is the
-- resolved consultation list (first hit wins) and comes from, in order:
-- the ZETA_REPOS env var (space-separated URLs), the ZETA_REPO env var
-- (single URL, kept so existing setups keep working), a `repos = { ... }`
-- table in the config file, or a single `repo = "..."` string there.
-- Defaults to the single zeta-index repository.

local config = {}

local path = require("path")

-- Environment overrides. Tests (and only tests) use config.setenv to inject
-- values portably on Lua 5.1, which has no os.setenv.
local _overrides = {}
local _cfg
local _script_dir
local _config_file = "/etc/zeta/configuration.lua"

function config.setenv(k, v)
  _overrides[k] = v
end

function config.reset()
  _overrides = {}
  _cfg = nil
  _script_dir = nil
end

local function getenv(k)
  local v = _overrides[k]
  if v ~= nil then return v end
  return os.getenv(k)
end

-- The machine's core count, for `jobs = nproc`. Probed from `nproc`, then
-- `getconf`, then /proc/cpuinfo; falls back to the default pool size.
local function core_count()
  for _, cmd in ipairs({ "nproc", "getconf _NPROCESSORS_ONLN" }) do
    local f = path.popen(cmd .. " 2>/dev/null")
    if f then
      local n = tonumber(f:read("*l"))
      f:close()
      if n and n >= 1 then return math.floor(n) end
    end
  end
  local f = io.open("/proc/cpuinfo", "rb")
  if f then
    local n = 0
    for line in f:lines() do
      if line:match("^processor%s*:") then n = n + 1 end
    end
    f:close()
    if n >= 1 then return n end
  end
  return 2
end

-- Load a Lua config file that returns a table. Returns the table or nil.
-- While the file runs, the global `nproc` holds the machine's core count so
-- `jobs = nproc` uses every core.
local function load_config_file(filepath)
  local saved_nproc = rawget(_G, "nproc")
  _G.nproc = core_count()
  local ok, result = pcall(dofile, filepath)
  _G.nproc = saved_nproc
  if ok and type(result) == "table" then
    return result
  end
  return nil
end

-- Resolve the local package tree. ZETA_LOCAL_PACKAGES is authoritative when
-- set; otherwise the documented default <root>/usr/share/packages wins if it
-- exists, and only then we fall back to <script_dir>/packages so an unpacked
-- checkout works offline with no environment at all.
local function resolve_local_packages(root, under, cfg_file)
  local env = getenv("ZETA_LOCAL_PACKAGES")
  if env then return env end
  if cfg_file and cfg_file.local_packages then return cfg_file.local_packages end
  local sys = under("usr/share/packages")
  if path.exists(sys) then return sys end
  if _script_dir then
    local checkout = path.join(_script_dir, "packages")
    if path.exists(checkout) then return checkout end
  end
  return sys
end

-- Resolve the remote repository list. Precedence:
--   ZETA_REPOS (env, space-separated) > ZETA_REPO (env, single) >
--   config file repos (list) > config file repo (single) > default.
local function resolve_repos(cfg_file)
  local list = getenv("ZETA_REPOS")
  if list and list ~= "" then
    local repos = {}
    for url in list:gmatch("%S+") do
      if url ~= "" then repos[#repos + 1] = url end
    end
    if #repos > 0 then return repos end
  end
  local single = getenv("ZETA_REPO")
  if single and single ~= "" then return { single } end
  if cfg_file then
    if type(cfg_file.repos) == "table" then
      local repos = {}
      for _, url in ipairs(cfg_file.repos) do
        if type(url) == "string" and url ~= "" then repos[#repos + 1] = url end
      end
      if #repos > 0 then return repos end
    end
    if type(cfg_file.repo) == "string" and cfg_file.repo ~= "" then
      return { cfg_file.repo }
    end
  end
  return { "https://github.com/gretagen/zeta-index" }
end

-- Resolve the commit pool size: how many packages may be "provided" at the
-- same time. ZETA_JOBS (env) > config file `jobs` > default 2. The value
-- "nproc" (or the nproc global in the config file) means every core.
local function resolve_jobs(cfg_file)
  local env = getenv("ZETA_JOBS")
  if env == "nproc" then return core_count() end
  local v = tonumber(env) or (cfg_file and tonumber(cfg_file.jobs))
  if v and v >= 1 then return math.floor(v) end
  return 2
end

function config.load(script_dir)
  if script_dir then _script_dir = script_dir end

  -- Layer 1: Load config file.
  local cfg_file = load_config_file(_config_file)

  -- Layer 2: Resolve root (env > config file > default).
  local root = getenv("ZETA_ROOT") or (cfg_file and cfg_file.root) or "/"
  if root == "" then root = "/" end
  local function under(p)
    if path.is_abs(p) then return p end
    return path.join(root, p)
  end

  -- Layer 3: Build full config table with env > file > defaults.
  local repos = resolve_repos(cfg_file)
  _cfg = {
    root = root,
    repos = repos,
    repo = repos[1],
    local_packages = resolve_local_packages(root, under, cfg_file),
    cache_dir = getenv("ZETA_CACHE") or (cfg_file and cfg_file.cache_dir) or under("var/cache/zeta"),
    state_dir = getenv("ZETA_STATE") or (cfg_file and cfg_file.state_dir) or under("var/db/zeta"),
    tmp_dir = getenv("ZETA_TMP") or (cfg_file and cfg_file.tmp_dir) or under("var/tmp/zeta"),
    reserve_dir = getenv("ZETA_RESERVE") or (cfg_file and cfg_file.reserve_dir) or under("zeta/reserve"),
    jobs = resolve_jobs(cfg_file),
    verbose = (getenv("ZETA_VERBOSE") == "1" or getenv("ZETA_VERBOSE") == "true")
              or (cfg_file and cfg_file.verbose == true)
              or false,
    quotes = not (
      (getenv("ZETA_QUOTES") == "false" or getenv("ZETA_QUOTES") == "0")
      or (cfg_file and cfg_file.quotes == false)
    ),
  }
  return _cfg
end

function config.get()
  if not _cfg then config.load() end
  return _cfg
end

return config
