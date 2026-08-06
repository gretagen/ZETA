-- sandbox.lua suite -- the manifest sandbox must cut off every escape hatch
-- while still letting plain compute and function declarations through.

local lib = require("lib")
local sandbox = require("sandbox")
local suite = lib.new_suite("sandbox")

local function run(src)
  local chunk, err = sandbox.compile(src, "=(test)")
  lib.assert_true(chunk ~= nil, "compile failed: " .. tostring(err))
  local ok, res = pcall(chunk)
  lib.assert_true(ok, "chunk raised: " .. tostring(res))
  return res
end

local function blocked(src)
  local chunk, err = sandbox.compile(src, "=(test)")
  lib.assert_true(chunk ~= nil, "compile failed: " .. tostring(err))
  local ok, res = pcall(chunk)
  lib.assert_false(ok, "expected sandbox block, got " .. tostring(res))
end

suite:test("os and io are not reachable", function()
  blocked("return os.getenv('HOME')")
  blocked("return os.execute('true')")
  blocked("return io.open('/etc/passwd')")
end)

suite:test("require, package, and load are not reachable", function()
  blocked("return require('path')")
  blocked("return package.path")
  blocked("return load('return 1')")
  blocked("return loadstring('return 1')")
  blocked("return dofile('/etc/passwd')")
  blocked("return loadfile('/etc/passwd')")
end)

suite:test("debug is not reachable", function()
  blocked("return debug.traceback")
  blocked("return debug.getinfo(1)")
end)

suite:test("global environment has no _G", function()
  -- _G is not defined in the sandbox env; it resolves to nil (no error,
  -- but unreachable).
  lib.assert_nil(run("return _G"))
  lib.assert_nil(run("return getfenv and getfenv() or nil"))
end)

suite:test("plain computation works", function()
  lib.assert_eq(run("return 1 + 2 * 3"), 7)
  lib.assert_eq(run("return string.rep('x', 3)"), "xxx")
  lib.assert_eq(run("return math.floor(3.9)"), 3)
  lib.assert_eq(run("return table.concat({'a','b'}, '-')"), "a-b")
end)

suite:test("returning tables with functions works (manifest shape)", function()
  local t = run("return { name='hello', deps={'libz'}, install=function() end }")
  lib.assert_eq(t.name, "hello")
  lib.assert_eq(t.deps[1], "libz")
  lib.assert_eq(type(t.install), "function")
end)

suite:test("returning a closure works", function()
  local f = run("return function(x) return x + 1 end")
  lib.assert_eq(type(f), "function")
  lib.assert_eq(f(1), 2)
end)

suite:test("compile rejects syntax errors", function()
  local chunk, err = sandbox.compile("return {")
  lib.assert_nil(chunk)
  lib.assert_true(err ~= nil)
end)

return suite
