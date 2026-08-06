-- vercmp.lua suite -- rpm-style version comparison and dependency constraints.

local lib = require("lib")
local vercmp = require("vercmp")
local suite = lib.new_suite("vercmp")

suite:test("equal versions", function()
  lib.assert_eq(vercmp.compare("1.0", "1.0"), 0)
  lib.assert_eq(vercmp.compare("1.0.0", "1.0.0"), 0)
  lib.assert_eq(vercmp.compare("2.3.4", "2.3.4"), 0)
end)

suite:test("numeric ordering", function()
  lib.assert_true(vercmp.compare("1.10", "1.9") > 0)
  lib.assert_true(vercmp.compare("2.0", "1.99") > 0)
  lib.assert_true(vercmp.compare("1.0", "0.99") > 0)
  lib.assert_true(vercmp.compare("1.1", "1.10") < 0)
end)

suite:test("extra segments win (rpm-style)", function()
  lib.assert_true(vercmp.compare("1.0.0", "1.0") > 0)
  lib.assert_true(vercmp.compare("1.0rc1", "1.0") > 0)
  lib.assert_true(vercmp.compare("1.0a", "1.0") > 0)
end)

suite:test("letter segments compare lexically", function()
  lib.assert_true(vercmp.compare("1.0beta", "1.0alpha") > 0)
  lib.assert_true(vercmp.compare("1.0alpha", "1.0beta") < 0)
end)

suite:test("whitespace is ignored", function()
  lib.assert_eq(vercmp.compare(" 1.0 ", "1.0"), 0)
end)

suite:test("leading zeros are ignored", function()
  lib.assert_eq(vercmp.compare("01.05", "1.5"), 0)
  lib.assert_true(vercmp.compare("1.000", "1.0") >= 0)
end)

suite:test("parse_dep plain name", function()
  local d = vercmp.parse_dep("libffi")
  lib.assert_eq(d.name, "libffi")
  lib.assert_nil(d.op)
  lib.assert_nil(d.version)
end)

suite:test("parse_dep constrained", function()
  for _, spec in ipairs({ "pcre2>=10.42", "pcre2 >= 10.42", "glib<=2.8" }) do
    local d = vercmp.parse_dep(spec)
    lib.assert_true(d ~= nil, "parse failed for " .. spec)
    lib.assert_true(d.op ~= nil, "op missing for " .. spec)
    lib.assert_true(d.version ~= nil, "version missing for " .. spec)
  end
  local d = vercmp.parse_dep("pcre2>=10.42")
  lib.assert_eq(d.name, "pcre2")
  lib.assert_eq(d.op, ">=")
  lib.assert_eq(d.version, "10.42")
end)

suite:test("single equals becomes == (perl-style)", function()
  lib.assert_eq(vercmp.parse_dep("x=1.0").op, "==")
end)

suite:test("parse_dep rejects garbage", function()
  lib.assert_nil(vercmp.parse_dep("!!!"))
  lib.assert_nil(vercmp.parse_dep("foo bar baz"))
  lib.assert_nil(vercmp.parse_dep(""))
end)

suite:test("satisfies: all operators", function()
  lib.assert_true(vercmp.satisfies("10.42", { op = ">=", version = "10.42" }))
  lib.assert_true(vercmp.satisfies("10.43", { op = ">=", version = "10.42" }))
  lib.assert_false(vercmp.satisfies("10.2", { op = ">=", version = "10.42" }))
  lib.assert_true(vercmp.satisfies("10.41", { op = "<=", version = "10.42" }))
  lib.assert_true(vercmp.satisfies("10.42", { op = "==", version = "10.42" }))
  lib.assert_false(vercmp.satisfies("10.43", { op = "==", version = "10.42" }))
  lib.assert_true(vercmp.satisfies("10.43", { op = "~=", version = "10.42" }))
  lib.assert_true(vercmp.satisfies("10.43", { op = ">", version = "10.42" }))
  lib.assert_true(vercmp.satisfies("10.41", { op = "<", version = "10.42" }))
  lib.assert_true(vercmp.satisfies("anything", { op = nil }))
end)

return suite
