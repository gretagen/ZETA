-- checksum.lua suite -- sha256 verification through the native-tool path and
-- the forced pure-Lua path.

local lib = require("lib")
local checksum = require("checksum")
local path = require("path")
local suite = lib.new_suite("checksum")

local PAYLOAD = path.join(lib.root, "packages", "hello", "hello-1.0.tar.gz")
local GOOD = "731887527d1a72c57d1e64bad85cc341a4285354e773b2cd277420b744df2943"

suite:test("native tool verifies a real payload", function()
  local ok, got = checksum.verify(PAYLOAD, GOOD)
  lib.assert_true(ok, "verification failed")
  lib.assert_eq(got, GOOD)
end)

suite:test("pure-Lua path verifies the same payload", function()
  local ok, got = checksum.verify(PAYLOAD, GOOD, { pure = true })
  lib.assert_true(ok, "pure-Lua verification failed")
  lib.assert_eq(got, GOOD)
end)

suite:test("mismatched digest is reported", function()
  local ok, err = checksum.verify(PAYLOAD, string.rep("0", 64))
  lib.assert_nil(ok)
  lib.assert_contains(err, "sha256 mismatch")
end)

suite:test("missing file is reported", function()
  local ok, err = checksum.verify(path.join(lib.tmp_root, "nope.tar.gz"), GOOD)
  lib.assert_nil(ok)
end)

suite:test("expected digest is lowercased before comparison", function()
  local ok = checksum.verify(PAYLOAD, GOOD:upper())
  lib.assert_true(ok, "uppercase expected digest should verify")
end)

return suite
