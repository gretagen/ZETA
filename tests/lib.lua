-- lib.lua -- tiny test harness shared by every suite.
--
-- Each suite module calls lib.new_suite("name") and registers tests with
-- suite:test("description", fn). run.lua collects all suites, runs every test
-- inside a pcall, and prints a PASS/FAIL summary. Assertions raise on failure;
-- a failing test is reported but the remaining tests still run.

local lib = {}

local path = require("path")

-- Locate the repo root (parent of tests/) and the real zeta.lua entry point.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
lib.root = here:gsub("[/\\]tests$", "")
if lib.root == here then lib.root = path.dirname(here) end
if lib.root == "" then lib.root = "." end
lib.zeta = path.join(lib.root, "zeta.lua")
lib.lua_bin = arg[-1] or "lua"

-- A scratch area for everything the suites create; removed by run.lua.
lib.tmp_root = path.join("/tmp", "zeta-suite-" .. tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999)))
os.execute("mkdir -p " .. path.quote(lib.tmp_root))

local created = {}

function lib.tmpdir(prefix)
  local dir = path.join(lib.tmp_root, (prefix or "t") .. "-" .. tostring(#created + 1))
  created[#created + 1] = dir
  os.execute("mkdir -p " .. path.quote(dir))
  return dir
end

function lib.cleanup()
  for i = #created, 1, -1 do
    os.execute("rm -rf " .. path.quote(created[i]))
  end
  os.execute("rm -rf " .. path.quote(lib.tmp_root))
end

-- ---------------------------------------------------------------------------
-- Suites
-- ---------------------------------------------------------------------------

function lib.new_suite(name)
  local tests = {}
  local suite = { name = name, tests = tests }
  function suite:test(n, fn)
    tests[#tests + 1] = { name = n, fn = fn }
  end
  return suite
end

-- ---------------------------------------------------------------------------
-- Assertions (all raise on failure)
-- ---------------------------------------------------------------------------

local function fail(msg)
  error(msg, 3)
end

function lib.assert_eq(got, want, msg)
  if not lib.deep_eq(got, want) then
    fail(("%s: got %s, want %s"):format(msg or "assert_eq", lib.dump(got), lib.dump(want)))
  end
end

-- Deep equality: scalars compare directly; tables compare by key/value.
-- Array-shaped tables (integer keys 1..n, nothing else) compare by order;
-- every other table compares as a map. Used so suites can assert against
-- freshly-built tables without sharing references.
function lib.deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  local function is_array(t)
    for k in pairs(t) do
      if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    end
    for i = 1, #t do if t[i] == nil then return false end end
    return true
  end
  local aa, ab = is_array(a), is_array(b)
  if aa ~= ab then return false end
  if aa then
    if #a ~= #b then return false end
    for i = 1, #a do
      if not lib.deep_eq(a[i], b[i]) then return false end
    end
    return true
  end
  local n = 0
  for _ in pairs(a) do n = n + 1 end
  for _ in pairs(b) do n = n - 1 end
  if n ~= 0 then return false end
  for k, v in pairs(a) do
    if not lib.deep_eq(v, b[k]) then return false end
  end
  return true
end

function lib.dump(v, indent)
  if type(v) ~= "table" then return string.format("%q", tostring(v)) end
  indent = indent or 0
  local pad = string.rep(" ", indent)
  local parts = {}
  for k, val in pairs(v) do
    local key = type(k) == "string" and k or "[" .. tostring(k) .. "]"
    parts[#parts + 1] = key .. "=" .. lib.dump(val, indent + 2)
  end
  table.sort(parts)
  return "{\n" .. pad .. "  " .. table.concat(parts, ",\n" .. pad .. "  ") .. "\n" .. pad .. "}"
end

function lib.assert_true(v, msg)
  if not v then fail(msg or "assert_true: expected a truthy value") end
end

function lib.assert_false(v, msg)
  if v then fail(msg or ("assert_false: expected falsy, got %q"):format(tostring(v))) end
end

function lib.assert_nil(v, msg)
  if v ~= nil then fail(msg or ("assert_nil: expected nil, got %q"):format(tostring(v))) end
end

-- fn must raise; optionally assert the error message contains `pattern`.
function lib.assert_error(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then fail(msg or "assert_error: expected an error, none raised") end
  if pattern and not tostring(err):find(pattern, 1, true) then
    fail(("%s: error %q does not contain %q"):format(msg or "assert_error", tostring(err), pattern))
  end
  return err
end

function lib.assert_contains(hay, needle, msg)
  if not tostring(hay):find(tostring(needle), 1, true) then
    fail(("%s: %q does not contain %q"):format(msg or "assert_contains", tostring(hay), tostring(needle)))
  end
end

function lib.assert_not_contains(hay, needle, msg)
  if tostring(hay):find(tostring(needle), 1, true) then
    fail(("%s: %q unexpectedly contains %q"):format(msg or "assert_not_contains", tostring(hay), tostring(needle)))
  end
end

-- ---------------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------------

function lib.write(p, content)
  local f = io.open(p, "wb")
  if not f then fail("lib.write: cannot open " .. p) end
  f:write(content)
  f:close()
end

function lib.read(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function lib.exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

function lib.is_symlink(p)
  -- readlink(1) is on every POSIX system; returns 0 when p is a symlink.
  local a, b, c = os.execute("readlink " .. path.quote(p) .. " >/dev/null 2>&1")
  if type(a) == "number" then return a == 0 end
  return a == true and b == "exit" and c == 0
end

-- ---------------------------------------------------------------------------
-- Subprocess (run the real zeta binary with a custom environment)
-- ---------------------------------------------------------------------------

local runs = 0

-- Run the real zeta binary with a custom environment. `input`, when given,
-- is piped to stdin (used to answer Y/N confirmation prompts).
function lib.run_zeta(args, env, input)
  runs = runs + 1
  local out = path.join(lib.tmp_root, "out-" .. tostring(runs) .. ".txt")
  local code_file = out .. ".code"
  local cmd = {}
  for k, v in pairs(env or {}) do
    cmd[#cmd + 1] = k .. "=" .. path.quote(v)
  end
  cmd[#cmd + 1] = path.quote(lib.lua_bin)
  cmd[#cmd + 1] = path.quote(lib.zeta)
  for _, a in ipairs(args) do cmd[#cmd + 1] = path.quote(a) end
  -- Capture the exit status via $? rather than relying on os.execute, whose
  -- return value differs between Lua 5.1 (raw wait status, e.g. 256 for
  -- exit 1) and Lua 5.2+ (status, "exit"/"signal", code).
  local redir = " > " .. path.quote(out) .. " 2>&1"
  if input then
    local in_file = out .. ".in"
    lib.write(in_file, input)
    redir = redir .. " < " .. path.quote(in_file)
  end
  local full = table.concat(cmd, " ") .. redir
    .. "; echo $? > " .. path.quote(code_file)
  os.execute(full)
  local f = io.open(code_file, "rb")
  local code = 1
  if f then
    code = tonumber(f:read("*a")) or 1
    f:close()
  end
  os.remove(code_file)
  local content = lib.read(out) or ""
  os.remove(out)
  return code, content
end

-- Re-read config from the given root, portably on Lua 5.1 (no os.setenv).
-- reset() clears the cached config but MUST run first: it also wipes any
-- previously set overrides, so they are applied afterwards.
function lib.use_root(root)
  local config = require("config")
  config.reset()
  config.setenv("ZETA_ROOT", root)
  config.setenv("ZETA_STATE", path.join(root, "var/db/zeta"))
  config.setenv("ZETA_CACHE", path.join(root, "var/cache/zeta"))
  config.setenv("ZETA_TMP", path.join(root, "var/tmp/zeta"))
  require("db") -- reloaded lazily via config.get() on first use
end

return lib
