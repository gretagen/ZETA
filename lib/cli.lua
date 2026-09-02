-- cli.lua -- argument parsing for Zeta.
--
-- Command tokens start with a single dash and match the documented forms
-- (-Provide, -LocalProvide, -Remove, -List, -Localize, -Help, -ReProvide).
-- Match is case-insensitive so -provide and -PROVIDE also work. Flags
-- start with a double dash (--pass, --force, --with-deps, --help).
-- Install/remove commands accept one or more package names.

local cli = {}

local COMMANDS = {
  provide = true,
  reprovide = true,
  localprovide = true,
  elevate = true,
  remove = true,
  list = true,
  localize = true,
  test = true,
  adopt = true,
  help = true,
}

-- Number of positional arguments each command requires exactly.
local ARITY = {
  localize = 1,
  test = 1,
  adopt = 1,
  list = 0,
  elevate = 0,
  help = 0,
}

-- Commands that accept one or more positional arguments.
local MIN_ARGS = {
  provide = 1,
  reprovide = 1,
  localprovide = 1,
  remove = 1,
  adopt = 1,
}

-- Returns { command = <string>, args = {..}, flags = { pass, force, with_deps, dir, files_path, version } }.
-- Returns nil, errmsg on any parse problem.
function cli.parse(args)
  local cmd
  local pos = {}
  local flags = { pass = false, force = false, with_deps = false }

  for _, a in ipairs(args) do
    if a:match("^%-%-") then
      local key, val = a:match("^%-%-([^=]+)=?(.*)")
      if key == "pass" then
        flags.pass = true
      elseif key == "force" then
        flags.force = true
      elseif key == "with-deps" then
        flags.with_deps = true
      elseif key == "help" then
        cmd = "help"
      elseif key == "dir" then
        flags.dir = val ~= "" and val or nil
      elseif key == "files" then
        flags.files_path = val ~= "" and val or nil
      elseif key == "version" then
        flags.version = val ~= "" and val or nil
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
  if want ~= nil and #pos ~= want then
    return nil, ("command -%s expects %d argument(s), got %d"):format(
      cmd:gsub("^.", string.upper), want, #pos)
  end
  local min = MIN_ARGS[cmd]
  if min and #pos < min then
    return nil, ("command -%s expects at least %d argument(s), got %d"):format(
      cmd:gsub("^.", string.upper), min, #pos)
  end

  return { command = cmd, args = pos, flags = flags }
end

return cli
