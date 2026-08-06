-- cli.lua -- argument parsing for Zeta.
--
-- Command tokens start with a single dash and match the documented forms
-- (-Provide, -LocalProvide, -Remove, -List, -Localize, -Help, -ReProvide).
-- Matching is case-insensitive so -provide and -PROVIDE also work. Flags
-- start with a double dash (--pass, --force, --help).

local cli = {}

local COMMANDS = {
  provide = true,
  reprovide = true,
  localprovide = true,
  remove = true,
  list = true,
  localize = true,
  test = true,
  help = true,
}

-- Number of positional arguments each command requires.
local ARITY = {
  provide = 1,
  reprovide = 1,
  localprovide = 1,
  remove = 1,
  localize = 1,
  test = 1,
  list = 0,
  help = 0,
}

-- Returns { command = <string>, args = {..}, flags = { pass, force } }.
-- Returns nil, errmsg on any parse problem.
function cli.parse(args)
  local cmd
  local pos = {}
  local flags = { pass = false, force = false }

  for _, a in ipairs(args) do
    if a:match("^%-%-") then
      local f = a:sub(3)
      if f == "pass" then
        flags.pass = true
      elseif f == "force" then
        flags.force = true
      elseif f == "help" then
        cmd = "help"
      else
        return nil, "unknown flag: " .. a
      end
    elseif a:match("^%-") and not cmd then
      local c = a:gsub("^%-+", ""):lower()
      if c == "h" then c = "help" end
      if COMMANDS[c] then
        cmd = c
      else
        return nil, ("unknown command: %s (run 'zeta -Help')"):format(a)
      end
    elseif not cmd then
      return nil, ("expected a command first, got %q"):format(a)
    else
      pos[#pos + 1] = a
    end
  end

  if not cmd then
    return nil, "no command given (run 'zeta -Help')"
  end

  local want = ARITY[cmd]
  if #pos ~= want then
    return nil, ("command -%s expects %d argument(s), got %d"):format(
      cmd:gsub("^.", string.upper), want, #pos)
  end

  return { command = cmd, args = pos, flags = flags }
end

return cli
