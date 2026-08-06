-- run.lua -- Zeta test runner.
--
--   lua tests/run.lua            run every suite under the current interpreter
--   lua tests/run.lua sha256     run only the named suite(s)
--
-- Each suite lives in tests/suites/<name>.lua and is a lib.new_suite object.
-- Every test runs inside a pcall; a raised error (assertion failure) is
-- reported as FAIL and the remaining tests keep running. Exit status is 0 only
-- when every test passes, so the suite doubles as a CI gate.

local script_dir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
if script_dir:sub(1, 1) ~= "/" then script_dir = (os.getenv("PWD") or ".") .. "/" .. script_dir end
package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path
local repo_root = script_dir:gsub("[/\\]tests$", "")
if repo_root == script_dir then repo_root = script_dir:match("^(.*)[/\\][^/\\]*$") or "/" end
package.path = package.path .. ";" .. repo_root .. "/lib/?.lua;" .. repo_root .. "/lib/?/init.lua"

local lib = require("lib")

local ALL_SUITES = {
  "vercmp", "sha256", "path", "cli", "sandbox", "manifest",
  "config", "deps", "fetch", "spinner", "archive", "checksum", "packages", "db", "commit", "e2e",
}

local wanted = {}
for i = 1, #arg do wanted[arg[i]] = true end
if #arg == 0 then for _, s in ipairs(ALL_SUITES) do wanted[s] = true end end

local passed, failed = 0, 0
local failures = {}

for _, name in ipairs(ALL_SUITES) do
  if wanted[name] then
    local ok, suite = pcall(require, "suites." .. name)
    if not ok then
      failed = failed + 1
      failures[#failures + 1] = ("suite %s failed to load: %s"):format(name, tostring(suite))
      print(("FAIL suite %-10s (load error: %s)"):format(name, tostring(suite)))
    else
      for _, t in ipairs(suite.tests) do
        local t0 = os.clock()
        local tok, terr = pcall(t.fn)
        local dt = os.clock() - t0
        if tok then
          passed = passed + 1
          print(("PASS %-10s %-42s %6.2fs"):format(name, t.name, dt))
        else
          failed = failed + 1
          failures[#failures + 1] = ("%s.%s: %s"):format(name, t.name, tostring(terr))
          print(("FAIL %-10s %-42s %s"):format(name, t.name, tostring(terr)))
        end
      end
    end
  end
end

print("")
print(("suite: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  print("")
  for _, f in ipairs(failures) do
    print("  " .. f)
  end
end

lib.cleanup()
os.exit(failed == 0 and 0 or 1)
