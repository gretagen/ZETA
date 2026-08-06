-- archive.lua suite -- safe tar inspection and extraction. Covers member
-- classification (incl. symlink detection), the three attack classes Zeta
-- must reject before extraction, and real strip-based installs.

local lib = require("lib")
local archive = require("archive")
local path = require("path")
local suite = lib.new_suite("archive")

local PKG = path.join(lib.root, "packages")

suite:test("classifies files, dirs, and symlinks", function()
  local entries, err = archive.entries(path.join(PKG, "libz", "libz-1.3.1.tar.gz"))
  lib.assert_true(entries ~= nil, tostring(err))
  local bypath = {}
  for _, e in ipairs(entries) do bypath[e.path] = e end
  lib.assert_eq(bypath["libz/usr/lib/libz.so.1.3.1"].type, "file")
  lib.assert_eq(bypath["libz/usr/lib"].type, "dir")
  lib.assert_eq(bypath["libz/usr/lib/libz.so"].type, "symlink")
  lib.assert_eq(bypath["libz/usr/lib/libz.so"].target, "libz.so.1")
  lib.assert_eq(bypath["libz/usr/lib/libz.so.1"].target, "libz.so.1.3.1")
end)

suite:test("validates a clean archive", function()
  local entries, err = archive.entries(path.join(PKG, "hello", "hello-1.0.tar.gz"))
  lib.assert_true(entries ~= nil, tostring(err))
  lib.assert_eq(archive.validate(entries), true)
end)

suite:test("extracts with strip into a staging dir", function()
  local dir = lib.tmpdir("arch-extract")
  local entries, err = archive.extract(path.join(PKG, "hello", "hello-1.0.tar.gz"), dir, { strip = 1 })
  lib.assert_true(entries ~= nil, tostring(err))
  lib.assert_true(lib.exists(path.join(dir, "usr/bin/hello")))
  lib.assert_false(lib.exists(path.join(dir, "hello")))
end)

suite:test("extract preserves symlinks on disk", function()
  local dir = lib.tmpdir("arch-symlink")
  archive.extract(path.join(PKG, "libz", "libz-1.3.1.tar.gz"), dir, { strip = 1 })
  lib.assert_true(lib.is_symlink(path.join(dir, "usr/lib/libz.so")))
  lib.assert_true(lib.is_symlink(path.join(dir, "usr/lib/libz.so.1")))
  lib.assert_false(lib.is_symlink(path.join(dir, "usr/lib/libz.so.1.3.1")))
end)

local function craft_tar(member_name, content)
  local dir = lib.tmpdir("arch-craft")
  local file = path.join(dir, "member")
  lib.write(file, content)
  local out = path.join(dir, "out.tar.gz")
  os.execute("tar -czf " .. path.quote(out) .. " -C " .. path.quote(dir)
    .. " --transform 's|member|" .. member_name .. "|' member 2>/dev/null")
  return out
end

suite:test("rejects escaping symlink", function()
  local dir = lib.tmpdir("arch-evil-sym")
  local target = path.join(dir, "base")
  os.execute("mkdir -p " .. path.quote(target .. "/s"))
  lib.write(path.join(target, "s/x"), "x")
  os.execute("ln -s ../../../../etc/passwd " .. path.quote(target .. "/s/evil"))
  local out = path.join(dir, "evil.tar.gz")
  os.execute("tar -czf " .. path.quote(out) .. " -C " .. path.quote(target) .. " s 2>/dev/null")
  local entries = archive.entries(out)
  local ok, err = archive.validate(entries)
  lib.assert_nil(ok)
  lib.assert_contains(err, "escapes")
end)

suite:test("rejects .. member", function()
  local entries = archive.entries(craft_tar("../../escape", "boom"))
  lib.assert_true(entries ~= nil, "craft failed")
  local ok, err = archive.validate(entries)
  lib.assert_nil(ok)
  lib.assert_contains(err, "escapes")
end)

suite:test("rejects absolute member", function()
  local entries = archive.entries(craft_tar("/etc/escape", "boom"))
  lib.assert_true(entries ~= nil, "craft failed")
  local ok, err = archive.validate(entries)
  lib.assert_nil(ok)
  lib.assert_contains(err, "escapes")
end)

return suite
