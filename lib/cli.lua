-- cli.lua -- argument parsing for Zeta.
--
-- Command tokens start with a single dash and match the documented forms
-- (-Provide, -LocalProvide, -ReProvide, -Solve, -Delete, -List, -Localize,
-- -Help). Match is case-insensitive so -provide and -PROVIDE also work. Flags
-- start with a double dash (--pass, --force, --detail,
-- --silence, --jobs, --help).
-- Install/delete commands accept one or more construct names.

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
  delete = true,
  list = true,
  localize = true,
  test = true,
  forget = true,
  help = true,
}

-- Number of positional arguments each command requires exactly. -List is not there,
-- as it takes one registery name and validates it seperately.
local ARITY = {
  localize = 1,
  test = 1,
  list = 1,
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
  delete = 1,
}

-- -List registries: canonical name = accepted aliases. parse() rewrites
-- args[1] to the canonical name, and actions.list() dispatches on exactly
-- those four -- keep both sides in sync.
local LIST_CANON = {
  all = "all",
  constructs = "constructs",
  packages = "constructs",
  depends = "depends",
  deps = "depends",
  dependencies = "depends",
  isolated = "wisolated",
  reserve = "isolated",
}
local LIST_NAMES = "constructs, depends, isolated, all"

-- Returns { command = <string>, args = {..}, flags = { pass, force, detail, silence, no_quote, isolate, jobs, dir, files_path, version } }.
-- Returns nil, errmsg on any parse problem.
function cli.parse(args)
  local cmd
  local pos = {}
  local flags = { pass = false, force = false, detail = false, silence = false, no_quote = false, isolate = false, jobs = nil }

  local i = 1
  while i <= #args do
    local a = args[i]
    if a:match("^%-%-") then
      local key, val = a:match("^%-%-([^=]+)=?(.*)")
      if key == "pass" then
        flags.pass = true
      elseif key == "force" then
        flags.force = true
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
          return nil, ("--jobs expects a positive integer, got nothing or something that made no sense"):format(val)
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
        return nil, ("the command %q is a part of your delusion"):format(a)
      end
    elseif not cmd then
      return nil, ("expected a command first, got %q instead"):format(a)
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end

  if not cmd then
    return nil, "no command specified."
  end

  -- The -List always names a registery
  -- This change is pretty sudden from the past versions, which is why instead of a generic error,
  -- it gets it's own error message.
  -- Reason why -list can not be ran by itself anymore is to make zeta output's more precise when listing.
  -- Anyway, the name is validated right here, so the failure goes through zeta.lua's parse-error path
  if cmd == "list" then
    if #pos == 0 then
      return nil, "To list means to specify a registry."
    elseif #pos > 1 then
      return nil, ("-List takes exactly one registry, sorry! (%s)."):format(LIST_NAMES)
    end
    local canon = LIST_CANON[pos[1]:lower()]
    if not canon then
      return nil, ("The registry %q is part of your delusion"):format(pos[1], LIST_NAMES)
    end
    pos[1] = canon
  end

  local want = ARITY[cmd]
  if want ~= nil and #pos ~= want then
    return nil, ("command -%s expects %d argument(s), not nothing."):format(
      cmd:gsub("^.", string.upper), want, #pos)
  end
  local min = MIN_ARGS[cmd]
  if min and #pos < min then
    return nil, ("command -%s expects at least %d argument(s), not nothing."):format(
      cmd:gsub("^.", string.upper), min, #pos)
  end

  return { command = cmd, args = pos, flags = flags }
end

return cli
