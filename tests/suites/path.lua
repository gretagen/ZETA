-- path.lua suite -- path helpers and name/escape validation.

local lib = require("lib")
local path = require("path")
local suite = lib.new_suite("path")

suite:test("join normalizes separators", function()
  lib.assert_eq(path.join("a", "b"), "a/b")
  lib.assert_eq(path.join("a/", "/b"), "a/b")
  lib.assert_eq(path.join("", "b"), "b")
  lib.assert_eq(path.join("a", ""), "a")
  lib.assert_eq(path.join("a", "b", "c"), "a/b/c")
end)

suite:test("join keeps absolute first component", function()
  lib.assert_eq(path.join("/a", "b"), "/a/b")
  lib.assert_eq(path.join("/", "a"), "/a")
  lib.assert_eq(path.join("/a", "/b"), "/a/b")
end)

suite:test("is_abs and basename and dirname", function()
  lib.assert_true(path.is_abs("/usr/bin/hello"))
  lib.assert_false(path.is_abs("usr/bin/hello"))
  lib.assert_eq(path.basename("/usr/bin/hello"), "hello")
  lib.assert_eq(path.dirname("/usr/bin/hello"), "/usr/bin")
  lib.assert_eq(path.dirname("hello"), ".")
end)

suite:test("quote leaves safe values bare", function()
  lib.assert_eq(path.quote("usr/bin/hello"), "usr/bin/hello")
  lib.assert_eq(path.quote("a b"), "'a b'")
  lib.assert_eq(path.quote(""), "''")
  lib.assert_eq(path.quote("o'brien"), "'o'\\''brien'")
end)

suite:test("relative_inside rejects .. escapes", function()
  lib.assert_true(path.relative_inside("usr/bin/hello"))
  lib.assert_true(path.relative_inside("usr/bin/../lib/x"))
  lib.assert_false(path.relative_inside("../escape"))
  lib.assert_false(path.relative_inside("a/../../escape"))
end)

suite:test("symlink_escapes rejects absolute and escaping targets", function()
  lib.assert_true(path.symlink_escapes("usr/lib/x", "/etc/passwd"))
  lib.assert_true(path.symlink_escapes("usr/lib/x", "../../../etc/passwd"))
  lib.assert_false(path.symlink_escapes("usr/lib/x", "libz.so.1"))
  lib.assert_false(path.symlink_escapes("usr/lib/x", "sub/../other"))
  lib.assert_false(path.symlink_escapes("usr/lib/x", ""))
end)

suite:test("sanitize_name accepts package names", function()
  for _, ok in ipairs({ "hello", "libz", "libffi", "pcre2-10.42", "a_b.c+d", "A-B_C.d+e" }) do
    lib.assert_eq(path.sanitize_name(ok), ok)
  end
end)

suite:test("sanitize_name rejects traversal and odd names", function()
  lib.assert_nil(path.sanitize_name("../evil"))
  lib.assert_nil(path.sanitize_name("a/b"))
  lib.assert_nil(path.sanitize_name(".hidden"))
  lib.assert_nil(path.sanitize_name(""))
  lib.assert_nil(path.sanitize_name("sp ace"))
  lib.assert_nil(path.sanitize_name(nil))
  lib.assert_nil(path.sanitize_name("pkg$evil"))
end)

suite:test("mkdir_p creates nested directories", function()
  local dir = lib.tmpdir("path-mkdir")
  local target = dir .. "/a/b/c"
  lib.assert_true(path.mkdir_p(target))
  lib.assert_true(lib.exists(target))
end)

return suite
