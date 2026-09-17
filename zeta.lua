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
if show_quotes then
  local list = quotes[parsed.command] or quotes.default
  log.banner(list[math.random(#list)])
else
  log.banner("Initializing ZETA...")
end

local dispatch = {
  provide = function(a, f) return actions.provide(a, f) end,
  reprovide = function(a, f) return actions.reprovide(a, f) end,
  localprovide = function(a, f) return actions.localprovide(a, f) end,
  transcend = function(a, f) return actions.transcend(f) end,
  remove = function(a, f) return actions.remove(a, f) end,
  list = function() return actions.list() end,
  localize = function(a) return actions.localize(a[1]) end,
  test = function(a, f) return actions.test(a[1], f) end,
  forget = function(a, f) return actions.forget(f.pass) end,
  help = function() actions.help() return 0 end,
}

local ok, code = pcall(function()
  return dispatch[parsed.command](parsed.args, parsed.flags)
end)

-- Kill orphaned background processes (spinner, download scripts) on exit.
path.run_cleanup()

if not ok then
  log.error(tostring(code))
  os.exit(1)
end
os.exit(code or 0)
