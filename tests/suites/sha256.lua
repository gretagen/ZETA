-- sha256.lua suite -- pure-Lua SHA-256 against FIPS 180-4 vectors plus the
-- streaming context and file API. Always exercises the pure-Lua implementation.

local lib = require("lib")
local sha256 = require("sha256")
local path = require("path")
local suite = lib.new_suite("sha256")

suite:test("NIST vector: empty string", function()
  lib.assert_eq(sha256.sum(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
end)

suite:test("NIST vector: abc", function()
  lib.assert_eq(sha256.sum("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
end)

suite:test("NIST vector: quick brown fox", function()
  lib.assert_eq(
    sha256.sum("The quick brown fox jumps over the lazy dog"),
    "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
end)

suite:test("NIST vector: multi-block", function()
  lib.assert_eq(
    sha256.sum("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
end)

-- Embedded digest (cross-checked against sha256sum) for 32 KiB of 'a',
-- which forces the streaming path across many 512-bit blocks.
suite:test("streaming cross-check: 32 KiB of a", function()
  lib.assert_eq(
    sha256.sum(string.rep("a", 32768)),
    "b217b65e6f205f41b3fb8ef90cf7c44da93f630ca03965273485bbb21a5cccf5")
end)

suite:test("streaming context with split updates", function()
  local ctx = sha256.new()
  ctx:update("abc")
  ctx:update("d")
  ctx:update("bcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
  lib.assert_eq(
    ctx:hexdigest(),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
end)

suite:test("file digest", function()
  local dir = lib.tmpdir("sha-file")
  local p = path.join(dir, "data.bin")
  lib.write(p, "The quick brown fox jumps over the lazy dog")
  lib.assert_eq(
    sha256.file(p),
    "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
end)

suite:test("file digest over a large file matches native tool", function()
  local dir = lib.tmpdir("sha-large")
  local p = path.join(dir, "big.bin")
  lib.write(p, string.rep("0123456789abcdef", 4096))
  local f = io.popen("sha256sum " .. path.quote(p))
  local line = f:read("*l")
  f:close()
  local expected = line and line:match("^(%x+)")
  lib.assert_true(expected ~= nil, "no sha256sum output")
  lib.assert_eq(sha256.file(p), expected)
end)

return suite
