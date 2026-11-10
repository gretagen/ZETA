-- zeta.lua -- Zeta package manager entry point.
--
-- Modules live next to this script (installed layout: /usr/lib/zeta/lib).

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/lib/?.lua;" .. package.path

local cli = require("cli")
local log = require("log")
local path = require("path")
local config = require("config")
local actions = require("actions")
local quotes = require("quotes")
local spinner = require("spinner")
local profile = require("profile")

-- Own the terminal. A live spinner row is drawn with \r and no trailing
-- newline, so output that lands on it glues to it ("Resolving dependencies /
-- .   dependency ..."). Suspend the row before every write and re-arm after;
-- the background loop redraws itself on its next tick.
--
-- spinner captured io.write when it was loaded above, so its own row writes
-- bypass this wrapper and cannot re-enter it. stderr is left alone: the
-- spinner is always stopped before any warn/error path runs.
local _print, _write = print, io.write

print = function(...)
  spinner.suspend()
  local r = _print(...)
  spinner.resume()
  return r
end

io.write = function(...)
  spinner.suspend()
  local r = _write(...)
  spinner.resume()
  return r
end

-- arg[0] is the script name; everything after it is user input.
local args = {}
for i = 1, #arg do args[i] = arg[i] end

local parsed, err = cli.parse(args)
if not parsed then
  log.error(tostring(err))
  io.write("run 'zeta -Help' for usage.\n")
  os.exit(1)
end

-- Always print the resolved configuration so the user knows exactly where
-- Zeta will read from and write to (verbose by design). --silence is wired
-- inside cli.parse (lib/cli.lua) so every entry point honors it.
local cfg = config.load(here)

local show_quotes = not parsed.flags.no_quote and cfg.quotes ~= false
-- Let runtime quotes (slow downloads) honor --no-quote and the config too.
quotes.set_enabled(show_quotes)
if show_quotes then
  log.banner(quotes.pick(quotes.for_command(parsed.command, parsed.flags.isolate)))
else
  log.banner("Initializing ZETA...")
end

local dispatch = {
  provide = function(a, f) return actions.provide(a, f) end,
  reprovide = function(a, f) return actions.reprovide(a, f) end,
  localprovide = function(a, f) return actions.localprovide(a, f) end,
  solve = function(a, f) return actions.solve(a, f) end,
  transcend = function(a, f) return actions.transcend(f) end,
  delete = function(a, f) return actions.delete(a, f) end,
  list = function() return actions.list() end,
  localize = function(a) return actions.localize(a[1]) end,
  test = function(a, f) return actions.test(a[1], f) end,
  forget = function(a, f) return actions.forget(f.pass) end,
  help = function() actions.help() return 0 end,
}

local ok, code = pcall(function()
  return dispatch[parsed.command](parsed.args, parsed.flags)
end)

-- One-line phase-timing receipt for the install pipeline (lib/profile.lua).
-- Only -Provide and -Transcend report; a failed run and commands that never
-- mark phases print nothing (profile.report() returns nil when unmarked).
local TIMED_COMMANDS = { provide = true, transcend = true }
if ok and (code == nil or code == 0) and TIMED_COMMANDS[parsed.command] then
  local report = profile.report()
  if report then log.info("timings: " .. report) end
end

-- Kill orphaned background processes (spinner, download scripts) on exit.
path.run_cleanup()

if not ok then
  log.error(tostring(code))
  os.exit(1)
end
os.exit(code or 0)
