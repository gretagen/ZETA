-- cli.lua -- argument parsing for Zeta.
--
-- Command tokens start with a single dash and match the documented forms
-- (-Provide, -LocalProvide, -ReProvide, -Solve, -Remove, -List, -Localize,
-- -Help). Match is case-insensitive so -provide and -PROVIDE also work. Flags
-- start with a double dash (--pass, --force, --with-deps, --detail,
-- --silence, --jobs, --help).
-- Install/remove commands accept one or more package names.

local cli = {}

local log = require("log")

-- Commands Zeta understands. Anything that mutates the system (or the download
-- cache) must also be listed in the privilege gate in bin/zeta, which blocks it
-- for non-root users.
local COMMANDS = {
  provide = true,
  reprovide = true,
  localprovide = true,
  solve = true,
  transcend = true,
  remove = true,
  list = true,
  localize = true,
  test = true,
  forget = true,
  help = true,
}

-- Number of positional arguments each command requires exactly.
local ARITY = {
  localize = 1,
  test = 1,
  list = 0,
  transcend = 0,
  forget = 0,
  help = 0,
}

-- Commands that accept one or more positional arguments.
local MIN_ARGS = {
  provide = 1,
  reprovide = 1,
  localprovide = 1,
  solve = 1,
  remove = 1,
}

-- Returns { command = <string>, args = {..}, flags = { pass, force, with_deps, detail, silence, no_quote, isolate, jobs, dir, files_path, version } }.
-- Returns nil, errmsg on any parse problem.
function cli.parse(args)
  local cmd
  local pos = {}
  local flags = { pass = false, force = false, with_deps = false, detail = false, silence = false, no_quote = false, isolate = false, jobs = nil }

  local i = 1
  while i <= #args do
    local a = args[i]
    if a:match("^%-%-") then
      local key, val = a:match("^%-%-([^=]+)=?(.*)")
      if key == "pass" then
        flags.pass = true
      elseif key == "force" then
        flags.force = true
      elseif key == "with-deps" then
        flags.with_deps = true
      elseif key == "detail" then
        flags.detail = true
      elseif key == "silence" then
        flags.silence = true
        -- Wire immediately at parse time so every entry point (zeta.lua,
        -- bin/zeta, installed launchers) honors --silence without needing the
        -- entry script itself to call log.set_file_silent().
        log.set_file_silent(true)
      elseif key == "no-quote" then
        flags.no_quote = true
      elseif key == "isolate" then
        flags.isolate = true
      elseif key == "jobs" then
        -- Accepts --jobs=N and --jobs N alike.
        if val == "" then
          i = i + 1
          val = args[i] or ""
        end
        local n = tonumber(val)
        if not n or n < 1 or n ~= math.floor(n) then
          return nil, ("--jobs expects a positive integer, got %q"):format(val)
        end
        flags.jobs = n
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
        return nil, ("unknown command."):format(a)
      end
    elseif not cmd then
      return nil, ("expected a command first, got %q"):format(a)
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end

  if not cmd then
    return nil, "no command specified."
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
