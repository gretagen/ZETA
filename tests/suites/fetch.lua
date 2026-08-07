-- fetch.lua suite -- the github.com -> raw.githubusercontent.com rewrite and
-- local file resolution (file:// and plain paths, no network).

local lib = require("lib")
local fetch = require("fetch")
local path = require("path")
local suite = lib.new_suite("fetch")

suite:test("github.com manifest url is rewritten to raw", function()
  lib.assert_eq(
    fetch.raw_github("https://github.com/gretagen/zeta-packages/packages/hello/package.lua"),
    "https://raw.githubusercontent.com/gretagen/zeta-packages/refs/heads/main/packages/hello/package.lua")
end)

suite:test("github.com repo root is rewritten too", function()
  lib.assert_eq(
    fetch.raw_github("https://github.com/gretagen/zeta-packages"),
    "https://raw.githubusercontent.com/gretagen/zeta-packages/refs/heads/main")
end)

suite:test("http and www github.com variants are rewritten", function()
  lib.assert_eq(
    fetch.raw_github("http://github.com/a/b/packages/x/package.lua"),
    "https://raw.githubusercontent.com/a/b/refs/heads/main/packages/x/package.lua")
  lib.assert_eq(
    fetch.raw_github("https://www.github.com/a/b/c.tgz"),
    "https://raw.githubusercontent.com/a/b/refs/heads/main/c.tgz")
end)

suite:test("non-github and local urls are unchanged", function()
  local u = "https://example.com/packages/x/package.lua"
  lib.assert_eq(fetch.raw_github(u), u)
  local f = "file:///tmp/x.tgz"
  lib.assert_eq(fetch.raw_github(f), f)
  lib.assert_eq(fetch.raw_github("/tmp/x.tgz"), "/tmp/x.tgz")
  lib.assert_eq(fetch.raw_github("x-1.0.tar.gz"), "x-1.0.tar.gz")
end)

suite:test("fetch.get copies a local file, creating parents", function()
  local src = path.join(lib.tmpdir("fetch-src"), "a.txt")
  lib.write(src, "hello")
  local dst = path.join(lib.tmpdir("fetch-dst"), "sub", "a.txt")
  local got, err = fetch.get(src, dst)
  lib.assert_true(got ~= nil, tostring(err))
  lib.assert_eq(lib.read(dst), "hello")
end)

suite:test("fetch.get copies file:// urls", function()
  local src = path.join(lib.tmpdir("fetch-filesrc"), "b.txt")
  lib.write(src, "bytes")
  local dst = path.join(lib.tmpdir("fetch-filedst"), "b.txt")
  local got, err = fetch.get("file://" .. src, dst)
  lib.assert_true(got ~= nil, tostring(err))
  lib.assert_eq(lib.read(dst), "bytes")
end)

suite:test("fetch.read returns file contents", function()
  local src = path.join(lib.tmpdir("fetch-read"), "package.lua")
  lib.write(src, "return { name = 'x' }")
  local content, err = fetch.read("file://" .. src)
  lib.assert_true(content ~= nil, tostring(err))
  lib.assert_eq(content, "return { name = 'x' }")
end)

suite:test("fetch.read of a missing file errors", function()
  local content, err = fetch.read(path.join(lib.tmpdir("fetch-missing"), "nope.lua"))
  lib.assert_nil(content)
  lib.assert_true(err ~= nil)
end)

return suite
