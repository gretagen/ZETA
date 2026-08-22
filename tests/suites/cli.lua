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
  for _, c in ipairs({ "-Provide", "-ReProvide", "-LocalProvide", "-Remove", "-Localize", "-Test", "-DryRun" }) do
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
  bad({ "-ReProvide" })
  bad({ "-LocalProvide" })
  bad({ "-Localize" })
  bad({ "-Test" })
  bad({ "-DryRun" })
end)

suite:test("too many arguments is rejected for single-argument commands", function()
  bad({ "-List", "extra" })
  bad({ "-Localize", "a", "b" })
  bad({ "-Test", "a", "b" })
  bad({ "-DryRun", "a", "b" })
end)

suite:test("install and remove commands accept multiple names", function()
  lib.assert_eq(parse({ "-Remove", "a", "b" }).args, { "a", "b" })
  lib.assert_eq(parse({ "-Provide", "a", "b", "c" }).args, { "a", "b", "c" })
  lib.assert_eq(parse({ "-ReProvide", "x", "y" }).args, { "x", "y" })
  lib.assert_eq(parse({ "-LocalProvide", "m", "n" }).args, { "m", "n" })
end)

suite:test("--with-deps is recorded", function()
  local p = parse({ "-Remove", "app", "--with-deps" })
  lib.assert_true(p.flags.with_deps)
  lib.assert_eq(p.command, "remove")
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
