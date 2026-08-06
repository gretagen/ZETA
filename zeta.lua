-- zeta.lua -- Zeta package manager entry point.
--
-- Modules live next to this script (installed layout: /usr/lib/zeta/lib).

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/lib/?.lua;" .. package.path

local cli = require("cli")
local log = require("log")
local config = require("config")
local actions = require("actions")

-- arg[0] is the script name; everything after it is user input.
local args = {}
for i = 1, #arg do args[i] = arg[i] end

local parsed, err = cli.parse(args)
if not parsed then
  log.error(tostring(err))
  io.write("Run 'zeta -Help' for usage.\n")
  os.exit(1)
end

-- Always print the resolved configuration so the user knows exactly where
-- Zeta will read from and write to (verbose by design).
local cfg = config.load(here)
log.info(("zeta (lua %s) root=%s repo=%s"):format(_VERSION, cfg.root, cfg.repo))

local dispatch = {
  provide = function(a, f) return actions.provide(a[1], f) end,
  reprovide = function(a, f) return actions.reprovide(a[1], f) end,
  localprovide = function(a, f) return actions.localprovide(a[1], f) end,
  remove = function(a, f) return actions.remove(a[1], f) end,
  list = function() return actions.list() end,
  localize = function(a) return actions.localize(a[1]) end,
  test = function(a, f) return actions.test(a[1], f) end,
  help = function() actions.help() return 0 end,
}

local ok, code = pcall(function()
  return dispatch[parsed.command](parsed.args, parsed.flags)
end)

if not ok then
  log.error(tostring(code))
  os.exit(1)
end
os.exit(code or 0)
