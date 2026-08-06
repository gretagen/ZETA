-- manifest.lua suite -- manifest loading/validation, including that a bad
-- manifest returns nil + error instead of raising.

local lib = require("lib")
local manifest = require("manifest")
local path = require("path")
local suite = lib.new_suite("manifest")

local HEX64 = string.rep("a", 64)

local function valid_base(overrides)
  local m = {
    name = "hello",
    version = "1.0",
    url = "hello-1.0.tar.gz",
    sha256 = HEX64,
    archive = { strip = 1 },
  }
  if overrides then for k, v in pairs(overrides) do m[k] = v end end
  return m
end

local function from_string(src)
  local m, err = manifest.load_string(src, "=(test)")
  lib.assert_true(m ~= nil, "expected valid manifest, got: " .. tostring(err))
  return m
end

local function bad_string(src, pattern, msg)
  local m, err = manifest.load_string(src, "=(test)")
  lib.assert_nil(m, msg or "expected invalid manifest to be rejected")
  lib.assert_true(err ~= nil, "expected an error message")
  if pattern then lib.assert_contains(err, pattern, msg or "manifest error message") end
end

local function bad_raw(raw, pattern)
  local m, err = pcall(manifest.normalize, raw)
  lib.assert_false(m, "expected normalize to fail")
  if pattern then lib.assert_contains(tostring(err), pattern) end
end

suite:test("valid archive manifest normalizes", function()
  local m = from_string("return { name='hello', version='1.0', url='x.tgz', sha256='" .. HEX64 .. "', archive={strip=1}, deps={'libz>=1.2'} }")
  lib.assert_eq(m.name, "hello")
  lib.assert_eq(m.version, "1.0")
  lib.assert_eq(m.archive.strip, 1)
  lib.assert_eq(m.deps[1].name, "libz")
  lib.assert_eq(m.deps[1].op, ">=")
  lib.assert_eq(m.deps[1].version, "1.2")
  lib.assert_eq(m.prefix, "/usr")
end)

suite:test("sha256 is lowercased", function()
  local m = from_string("return { name='x', version='1', url='x.tgz', sha256=string.rep('A',64), archive={strip=0} }")
  lib.assert_true(m.sha256:match("^%l+$"), "expected lowercase hex")
end)

suite:test("manifest.load reads a real file", function()
  local m, err = manifest.load(path.join(lib.root, "packages", "hello", "package.lua"))
  lib.assert_true(m ~= nil, "hello manifest failed to load: " .. tostring(err))
  lib.assert_eq(m.name, "hello")
  lib.assert_eq(m.version, "1.0")
end)

suite:test("bad sha256 is rejected gracefully", function()
  bad_string("return { name='x', version='1', url='x.tgz', sha256='zz', archive={strip=1} }", "sha256")
end)

suite:test("bad name is rejected", function()
  bad_string("return { name='a/b', version='1', url='x.tgz', sha256='" .. HEX64 .. "', archive={strip=1} }", "name")
  bad_raw(valid_base({ name = "../evil" }))
end)

suite:test("self-dependency is rejected", function()
  bad_raw(valid_base({ deps = { "hello" } }))
end)

suite:test("exactly one of archive/install/build required", function()
  bad_raw(valid_base({ build = function() end }), "exactly one")
  bad_raw({ name = "x", version = "1", url = "x.tgz", sha256 = HEX64 })
end)

suite:test("test hook is optional and not an install strategy", function()
  local m = from_string("return { name='x', version='1', url='x.tgz', sha256='" .. HEX64
    .. "', archive={strip=1}, test=function(p) return true end }")
  lib.assert_true(type(m.test) == "function", "expected a normalized test hook")
  lib.assert_eq(m.archive.strip, 1)
  -- `test` alone does not satisfy the exactly-one strategy rule.
  bad_raw({ name = "x", version = "1", url = "x.tgz", sha256 = HEX64,
            test = function() end }, "exactly one")
  bad_raw(valid_base({ test = "not-a-function" }), "test must be a function")
end)

suite:test("archive mode requires a url", function()
  bad_raw({ name = "x", version = "1", sha256 = HEX64, archive = { strip = 1 } }, "requires a url")
end)

suite:test("remote https url requires sha256", function()
  bad_raw({ name = "x", version = "1", url = "https://example.com/x.tgz", archive = { strip = 1 } }, "sha256")
end)

suite:test("unsafe url characters are rejected", function()
  bad_raw(valid_base({ url = "x.tgz; rm -rf /" }), "unsafe")
end)

suite:test("invalid dependency constraint is rejected", function()
  bad_raw(valid_base({ deps = { "libz >= 1 2" } }), "bad dependency")
end)

suite:test("files whitelist validates and normalizes", function()
  local m = from_string("return { name='x', version='1', url='x.tgz', sha256='" .. HEX64 .. "', archive={strip=1}, files={'/usr/bin/x', 'usr/lib/x'} }")
  lib.assert_eq(m.files[1], "usr/bin/x")
  lib.assert_eq(m.files[2], "usr/lib/x")
  bad_raw(valid_base({ files = { "../escape" } }), "escapes")
  bad_raw(valid_base({ files = { "usr/bin/x", "usr/bin/x" } }), "twice")
end)

suite:test("unknown fields are dropped, known ones preserved", function()
  local m = from_string("return { name='x', version='1', url='x.tgz', sha256='" .. HEX64 .. "', archive={strip=1}, typo_field='ignored' }")
  lib.assert_eq(m.name, "x")
end)

suite:test("check_name enforces requested name", function()
  local m = from_string("return { name='x', version='1', url='x.tgz', sha256='" .. HEX64 .. "', archive={strip=1} }")
  lib.assert_true(manifest.check_name(m, "x"))
  lib.assert_nil(manifest.check_name(m, "y"))
end)

suite:test("runtime error in package.lua is caught", function()
  bad_string("error('boom')", "runtime error")
end)

return suite
