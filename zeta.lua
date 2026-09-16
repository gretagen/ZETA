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

math.randomseed(os.time())
local greetings = {
  transcend = {
    "Let's not go outdated.",
    "Gotta keep up with the future.",
    "Gotta live with the times.",
    "Let's not stay in the past.",
    "Let's see what's new.",
    "Elevate to heaven.",
    "Aim for transcendence.",
    "We will go beyond.",
    "Life is full of changes.",
    "Have you checked the news?",
    "In my restless dreams, I see package updates.",
    "Nothing ever doesn't change.",
    "Maybe someday we'll have more maintenance for those..",
    "ZETA package updates? what a funny joke.",
    "A rare occurence is when ZETA has package updates.",
    "A reminder to frequently create generations in case something breaks",
  },
  remove = {
    "We sometimes don't need things anymore.",
    "Think before removing.",
    "With time, comes obsolescence.",
    "Sometimes we need to clean up.",
    "Let's not break anything this time...",
    "Sometimes letting go does more good than bad.",
    "Storage is not a privilege everyone has.",
    "We have to get rid of useless things.",
    "We (probably) don't need those anymore",
    "Let's see if the system breaks after the removal of the requested package",
    "Everything that lives is designed to end.",
    "Nothing built can last forever.",
    "You only lose what you cling to.",
    "Recycling bin: destination unknown.",
    "Crossing fingers that nothing else depends on this...",
    "If anything breaks, let's hope a generation will save you.",
    "To delete is to make room for the new.",
    "A reminder to frequently create generations in case something breaks.",
    "Dividing packages by 0",
  },
  forget = {
    "Wiping cache",
    "Looks like it's sweeping time!",
    "Gotta sweep sweep sweep!",
    "Like a memory, you forget.",
    "It's just a burning memory.",
    "Every legend, no matter how great, fades with time",
  },
  default = {
    "We all have to try new things.",
    "If it's not there just subspace-merge",
    "Starting up ZETA for you",
    "We'll get it all someday",
    "Any delivery service wouldn't ship that fast",
    "Fast and noisy, like a wind turbine.",
    "Loading Zenith Energy Turbine Archive",
    "Providing packages since 2026",
    "Lua's a good language for a package manager I promise",
    "Bloating your system again?",
    "Please pray the network gods for a stable connection",
    "Unpacking boxes you'll probably forget about in six months",
    "Let's hope this installs on the first try",
    "From the void of the repository, creation takes shape.",
    "Brace for impact for potential dependency hell",
    "Hope you have enough disk space for this.",
    "Because your machine clearly needs more stuff in it.",
    "Let's hope this won't conflict with anything.",
    "A reminder to frequently create generations in case something breaks.",
  },
}
local list = greetings[parsed.command] or greetings.default
log.banner(list[math.random(#list)])

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
