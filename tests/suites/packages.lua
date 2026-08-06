-- packages.lua suite -- validates the metadata of every sample package:
-- manifest fields, and that each declared sha256 really matches the payload
-- file sitting next to it.

local lib = require("lib")
local manifest = require("manifest")
local sha256 = require("sha256")
local path = require("path")
local suite = lib.new_suite("packages")

local PKG = path.join(lib.root, "packages")

local SAMPLES = {
  hello = { version = "1.0", mode = "archive", strip = 1 },
  libz = { version = "1.3.1", mode = "archive", strip = 1 },
  libffi = { version = "3.4.6", mode = "build" },
  glib = { version = "2.88.1", mode = "archive", strip = 1, no_payload = true },
}

suite:test("every sample loads and declares its directory name", function()
  for name in pairs(SAMPLES) do
    local m, err = manifest.load(path.join(PKG, name, "package.lua"))
    lib.assert_true(m ~= nil, name .. ": " .. tostring(err))
    lib.assert_eq(m.name, name)
    lib.assert_eq(m.version, SAMPLES[name].version)
  end
end)

suite:test("every sample has exactly one install strategy", function()
  for name in pairs(SAMPLES) do
    local m = assert(manifest.load(path.join(PKG, name, "package.lua")))
    local count = (m.archive and 1 or 0) + (m.install and 1 or 0) + (m.build and 1 or 0)
    lib.assert_eq(count, 1, name)
    lib.assert_true(m.url ~= nil, name .. " must declare a url")
  end
end)

suite:test("archive samples strip one top-level component", function()
  for name, info in pairs(SAMPLES) do
    if info.mode == "archive" then
      local m = assert(manifest.load(path.join(PKG, name, "package.lua")))
      lib.assert_eq(m.archive.strip, info.strip)
    end
  end
end)

suite:test("declared sha256 is 64 lowercase hex", function()
  for name in pairs(SAMPLES) do
    local m = assert(manifest.load(path.join(PKG, name, "package.lua")))
    lib.assert_true(m.sha256:match("^%x+$") ~= nil, name)
    lib.assert_eq(#m.sha256, 64, name)
    lib.assert_eq(m.sha256, m.sha256:lower(), name .. " must be lowercase")
  end
end)

suite:test("glib deps parse to constrained names", function()
  local m = assert(manifest.load(path.join(PKG, "glib", "package.lua")))
  lib.assert_eq(#m.deps, 2)
  lib.assert_eq(m.deps[1].name, "libffi")
  lib.assert_eq(m.deps[1].op, ">=")
  lib.assert_eq(m.deps[1].version, "3.4")
  lib.assert_eq(m.deps[2].name, "pcre2")
  lib.assert_eq(m.deps[2].version, "10.42")
end)

suite:test("no sample depends on itself", function()
  for name in pairs(SAMPLES) do
    local m = assert(manifest.load(path.join(PKG, name, "package.lua")))
    for _, d in ipairs(m.deps) do
      lib.assert_true(d.name ~= name, name)
    end
  end
end)

suite:test("payload sha256 matches the manifest (pure-Lua)", function()
  for name, info in pairs(SAMPLES) do
    if not info.no_payload then -- glib has no local payload
      local m = assert(manifest.load(path.join(PKG, name, "package.lua")))
      local tarball = path.join(PKG, name, m.url)
      lib.assert_true(lib.exists(tarball), name .. ": payload " .. m.url .. " missing")
      lib.assert_eq(sha256.file(tarball), m.sha256, name .. " payload checksum mismatch")
    end
  end
end)

suite:test("hello archive really strips to usr/bin/hello", function()
  local m = assert(manifest.load(path.join(PKG, "hello", "package.lua")))
  local archive = require("archive")
  local dir = lib.tmpdir("pkg-hello")
  local entries = archive.extract(path.join(PKG, "hello", m.url), dir, { strip = m.archive.strip })
  lib.assert_true(entries ~= nil, "extract failed")
  lib.assert_true(lib.exists(path.join(dir, "usr/bin/hello")))
end)

suite:test("libz payload carries its symlinks", function()
  local m = assert(manifest.load(path.join(PKG, "libz", "package.lua")))
  local archive = require("archive")
  local entries = archive.entries(path.join(PKG, "libz", m.url))
  local symlinks = {}
  for _, e in ipairs(entries) do
    if e.type == "symlink" then symlinks[e.path] = e.target end
  end
  lib.assert_eq(symlinks["libz/usr/lib/libz.so"], "libz.so.1")
  lib.assert_eq(symlinks["libz/usr/lib/libz.so.1"], "libz.so.1.3.1")
end)

suite:test("check_name agrees with the directory name", function()
  for name in pairs(SAMPLES) do
    local m = assert(manifest.load(path.join(PKG, name, "package.lua")))
    lib.assert_true(manifest.check_name(m, name))
  end
end)

return suite
