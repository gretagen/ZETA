-- cli.lua suite -- command line parsing.

local lib = require("lib")
local cli = require("cli")
local suite = lib.new_suite("cli")

local function parse(args)
  local p, err = cli.parse(args)
  lib.assert_true(p ~= nil, "parse failed for " .. table.concat(args, " ") .. ": " .. tostring(err))
  return p
end

local function bad(args)
  local p, err = cli.parse(args)
  lib.assert_nil(p, "expected parse failure for " .. table.concat(args, " "))
  lib.assert_true(err ~= nil, "expected an error message")
end

suite:test("every documented command parses", function()
  for _, c in ipairs({ "-Provide", "-ReProvide", "-LocalProvide", "-Remove", "-Localize", "-Test" }) do
    local p = parse({ c, "pkg" })
    lib.assert_eq(p.args[1], "pkg")
  end
  lib.assert_eq(parse({ "-List" }).command, "list")
  lib.assert_eq(parse({ "-Help" }).command, "help")
end)

suite:test("commands are case-insensitive", function()
  lib.assert_eq(parse({ "-provide", "x" }).command, "provide")
  lib.assert_eq(parse({ "-PROVIDE", "x" }).command, "provide")
  lib.assert_eq(parse({ "-l" .. "ist" }).command, "list")
end)

suite:test("-h is an alias for help", function()
  lib.assert_eq(parse({ "-h" }).command, "help")
  lib.assert_eq(parse({ "--help" }).command, "help")
end)

suite:test("flags are recorded", function()
  local p = parse({ "-Provide", "hello", "--pass", "--force" })
  lib.assert_true(p.flags.pass)
  lib.assert_true(p.flags.force)
end)

suite:test("flags can appear before the command", function()
  local p = parse({ "--pass", "-Provide", "hello" })
  lib.assert_true(p.flags.pass)
  lib.assert_eq(p.command, "provide")
end)

suite:test("missing argument is rejected", function()
  bad({ "-Remove" })
  bad({ "-Provide" })
  bad({ "-Localize" })
  bad({ "-Test" })
end)

suite:test("too many arguments is rejected", function()
  bad({ "-Remove", "a", "b" })
  bad({ "-List", "extra" })
end)

suite:test("unknown command is rejected", function()
  bad({ "-Nope" })
  bad({ "-Providex" })
end)

suite:test("unknown flag is rejected", function()
  bad({ "-Provide", "x", "--nope" })
end)

suite:test("a bare token before the command is rejected", function()
  bad({ "hello" })
end)

suite:test("no command is rejected", function()
  bad({})
end)

return suite
