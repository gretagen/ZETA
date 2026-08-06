-- deps.lua -- recursive dependency resolution.
--
-- Resolution walks the manifest's `deps` graph depth-first and returns a
-- topologically ordered list (dependencies before dependents, target last)
-- of manifests to install. Cycles are detected via an in-progress stack and
-- abort with the full chain. Manifests are fetched once and memoized, and
-- installed dependencies that satisfy their constraint are skipped (verbose
-- note printed) rather than re-resolved.

local deps = {}

local log = require("log")
local vercmp = require("vercmp")

-- resolve(target, ctx) -> ordered list of { name, manifest } or throws.
-- ctx must provide:
--   fetch_manifest(name)   -> manifest table | nil, err
--   installed_version(name)-> version string | nil
function deps.resolve(target, ctx)
  local order = {}
  local cache = {}
  local in_progress = {}
  local done = {}

  local function fetch(name)
    local m = cache[name]
    if not m then
      local res, err = ctx.fetch_manifest(name)
      if not res then
        error(("cannot resolve dependency %q: %s"):format(name, tostring(err)), 0)
      end
      cache[name] = res
      return res
    end
    return m
  end

  local function walk(name, chain)
    if in_progress[name] then
      chain[#chain + 1] = name
      error(("dependency cycle detected: %s"):format(table.concat(chain, " -> ")), 0)
    end
    if done[name] then return end

    local m = fetch(name)
    in_progress[name] = true
    chain[#chain + 1] = name

    for _, dep in ipairs(m.deps or {}) do
      local inst = ctx.installed_version and ctx.installed_version(dep.name)
      if inst then
        if vercmp.satisfies(inst, dep) then
          log.detail(("dependency %s satisfied by installed %s-%s"):format(
            dep.name, dep.name, inst))
        else
          -- An installed-but-too-old dependency cannot be fixed by a fresh
          -- install of the same version, so we refuse loudly rather than
          -- produce a subtly broken system.
          error(("installed %s-%s does not satisfy dependency %s%s%s (use -ReProvide %s)"):format(
            dep.name, inst, dep.name, dep.op or "", dep.version or "", dep.name), 0)
        end
      else
        walk(dep.name, chain)
      end
    end

    chain[#chain] = nil
    in_progress[name] = nil
    done[name] = true
    order[#order + 1] = { name = name, manifest = m }
  end

  walk(target, {})
  return order
end

return deps
