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

-- Build a minimal .deb: an ar(1) container with debian-binary, an empty
-- control.tar.gz, and the given data.tar payload.
local function ar_header(name, size)
  local name16 = name .. "/" .. string.rep(" ", 15 - #name)
  return name16                                          -- 16: name + "/"
    .. string.rep("0", 12)                               -- 12: mtime
    .. "0     "                                          --  6: owner
    .. "0     "                                          --  6: group
    .. "0100644 "                                        --  8: mode
    .. ("%10d"):format(size)                             -- 10: size
    .. "`\n"                                             --  2: magic
end

local function build_deb(data_tar_path)
  local dir = lib.tmpdir("deb-build")
  local members = {
    { name = "debian-binary", data = "2.0\n" },
    { name = "control.tar.gz", data = "" },
    { name = "data.tar.gz", data = lib.read(data_tar_path) or "" },
  }
  local out = "!<arch>\n"
  for _, m in ipairs(members) do
    out = out .. ar_header(m.name, #m.data) .. m.data
    if #m.data % 2 == 1 then out = out .. "\n" end
  end
  local deb = path.join(dir, "pkg.deb")
  lib.write(deb, out)
  return deb
end

suite:test("extracts a .deb's data.tar payload", function()
  local dir = lib.tmpdir("deb-extract")
  local pkg = path.join(dir, "tree")
  os.execute("mkdir -p " .. path.quote(path.join(pkg, "usr/bin")))
  lib.write(path.join(pkg, "usr/bin/hello"), "#!/bin/sh\necho hi\n")
  local data_tar = path.join(dir, "data.tar.gz")
  os.execute("tar -czf " .. path.quote(data_tar) .. " -C " .. path.quote(pkg) .. " usr 2>/dev/null")

  local dest = lib.tmpdir("deb-stage")
  local entries, err = archive.extract(build_deb(data_tar), dest, { tmp_dir = dir })
  lib.assert_true(entries ~= nil, tostring(err))
  lib.assert_eq(lib.read(path.join(dest, "usr/bin/hello")), "#!/bin/sh\necho hi\n")
end)

suite:test("rejects a .deb whose data.tar escapes the root", function()
  local dir = lib.tmpdir("deb-evil")
  local deb = build_deb(craft_tar("../../escape", "boom"))
  local dest = lib.tmpdir("deb-evil-stage")
  local entries, err = archive.extract(deb, dest, { tmp_dir = dir })
  lib.assert_nil(entries)
  lib.assert_contains(err, "escapes")
end)

suite:test("rejects a payload that is not an ar archive", function()
  local dir = lib.tmpdir("deb-notar")
  local fake = path.join(dir, "fake.deb")
  lib.write(fake, "this is not a deb\n")
  local dest = lib.tmpdir("deb-notar-stage")
  local entries, err = archive.extract(fake, dest, { tmp_dir = dir })
  lib.assert_nil(entries)
  lib.assert_contains(err, "not a Debian package")
end)

-- Regression: deb-aware strip detection
suite:test("deb with ./ prefix + strip=1 strips correctly", function()
  local dir = lib.tmpdir("deb-dot-strip")
  local pkg = path.join(dir, "tree")
  os.execute("mkdir -p " .. path.quote(path.join(pkg, "usr/bin")))
  lib.write(path.join(pkg, "usr/bin/hello"), "#!/bin/sh\necho hi\n")
  local data_tar = path.join(dir, "data.tar.gz")
  os.execute("tar -czf " .. path.quote(data_tar) .. " -C " .. path.quote(pkg) .. " usr 2>/dev/null")

  local dest = lib.tmpdir("deb-dot-strip-stage")
  local entries, err = archive.extract(build_deb(data_tar), dest, { strip = 1, tmp_dir = dir })
  lib.assert_true(entries ~= nil, tostring(err))
  lib.assert_true(lib.exists(path.join(dest, "usr/bin/hello")))
end)

suite:test("deb without ./ prefix + strip=1 disables strip", function()
  local dir = lib.tmpdir("deb-nodot-strip")
  local pkg = path.join(dir, "tree")
  os.execute("mkdir -p " .. path.quote(path.join(pkg, "usr/bin")))
  lib.write(path.join(pkg, "usr/bin/hello"), "#!/bin/sh\necho hi\n")
  local data_tar = path.join(dir, "data.tar.gz")
  os.execute("tar -czf " .. path.quote(data_tar) .. " -C " .. path.quote(pkg) .. " usr 2>/dev/null")

  local dest = lib.tmpdir("deb-nodot-strip-stage")
  local entries, err = archive.extract(build_deb(data_tar), dest, { strip = 1, tmp_dir = dir })
  lib.assert_true(entries ~= nil, tostring(err))
  lib.assert_true(lib.exists(path.join(dest, "usr/bin/hello")))
end)

suite:test("native tar.gz with top-level dir + strip=1 still strips", function()
  local dir = lib.tmpdir("native-strip-regression")
  local pkg = path.join(dir, "pkg-1.0")
  os.execute("mkdir -p " .. path.quote(path.join(pkg, "usr/bin")))
  lib.write(path.join(pkg, "usr/bin/foo"), "#!/bin/sh\necho foo\n")
  local tarball = path.join(dir, "pkg-1.0.tar.gz")
  os.execute("tar -czf " .. path.quote(tarball) .. " -C " .. path.quote(dir) .. " pkg-1.0 2>/dev/null")

  local dest = lib.tmpdir("native-strip-stage")
  local entries, err = archive.extract(tarball, dest, { strip = 1 })
  lib.assert_true(entries ~= nil, tostring(err))
  lib.assert_true(lib.exists(path.join(dest, "usr/bin/foo")))
  lib.assert_false(lib.exists(path.join(dest, "pkg-1.0")))
end)

return suite
