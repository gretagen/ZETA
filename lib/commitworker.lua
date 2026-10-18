-- commitworker.lua -- one-shot commit worker for the parallel commit pool.
--
--   lua commitworker.lua <ticket.lua>
--
-- The ticket is a Lua file returning { name, version, staging, root, force,
-- whitelist, report, status, progress }. The worker runs the file-placement
-- half of commit.apply and writes its results where the parent picks them up:
--
--   progress   the running entry count, restamped after every commit
--   report     one "<type>|<rel>" line per owned entry (only on success)
--   status     exit code on the first line, error message below (always)
--
-- The parent draws all output -- one aggregate header and counter for the
-- whole batch -- so this worker prints nothing. System-wide side effects
-- (ldconfig, GSettings schema compilation) are deferred to the parent as
-- well: two workers running them at once would collide on /etc/ld.so.cache~
-- and gschemas.compiled.
--
-- This is internal plumbing: it is dispatched by builder.commit_all and is
-- not a user-facing command.

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local function die(msg)
  io.stderr:write("commitworker: " .. tostring(msg) .. "\n")
  os.exit(1)
end

local ticket_path = arg[1]
if not ticket_path then die("usage: commitworker.lua <ticket.lua>") end

local ok_load, t = pcall(dofile, ticket_path)
if not ok_load or type(t) ~= "table" then
  die("could not load ticket " .. ticket_path)
end

local commit = require("commit")

-- Always leave a status file behind so the parent can never wait forever,
-- even when something above exploded before the real work started.
local function finish(code, msg)
  local f = io.open(t.status, "w")
  if f then
    f:write(tostring(code), "\n")
    if msg then f:write(msg, "\n") end
    f:close()
  end
  os.exit(code)
end

local TYPE_TAG = { file = "f", symlink = "l", dir = "d" }

local ok, err = pcall(function()
  local owned = commit.apply(t.staging, {
    whitelist = t.whitelist,
    force = t.force,
    pkg_name = t.name,
    root = t.root,
    defer_system = true,
    on_progress = function(done)
      local f = io.open(t.progress, "w")
      if f then
        f:write(tostring(done))
        f:close()
      end
    end,
  })
  local f = io.open(t.report, "w")
  if not f then error(("could not write report %s"):format(t.report), 0) end
  for _, e in ipairs(owned) do
    f:write(TYPE_TAG[e.type] or "f", "|", e.rel, "\n")
  end
  f:close()
end)

if not ok then
  -- The parent wraps this into "install of X failed: ...".
  finish(1, tostring(err))
end
finish(0)
