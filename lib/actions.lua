-- actions.lua -- command handlers. Thin wiring between the CLI, dependency
-- resolution, the builder, and the database. All confirmation prompts honor
-- the --pass flag (skip Y/N and proceed immediately).
--
-- Install/remove commands accept one or more package names and operate on
-- each one in turn, stopping at the first hard failure. Installed state is
-- split into explicit "packages" and auto-installed "dependencies"; -Remove
-- warns about dependents and --with-deps cascades into orphaned
-- dependencies.

local actions = {}

local config = require("config")
local log = require("log")
local path = require("path")
local db = require("db")
local repo = require("repo")
local deps = require("deps")
local builder = require("builder")
local manifest = require("manifest")
local vercmp = require("vercmp")
local hooks = require("hooks")
local fetch = require("fetch")
local spinner = require("spinner")

local HELP = [[
Zeta -- Haliade OS package manager

Usage: zeta <command> [arguments] [flags]

Commands:
  -Provide <pkg>...       Install packages and their dependencies from the remote repository
  -ReProvide <pkg>...     Reinstall packages even if they are already installed
  -LocalProvide <pkg>...  Install packages from the local /packages tree
  -Transcend              Update all installed packages to their latest versions
  -Remove <pkg>...        Remove installed packages (see --with-deps)
  -List                   List installed packages and dependencies
  -Localize <query>       Search the remote repository index for <query>
  -Test <pkg>             Verify <pkg> offline WITHOUT installing it
  -Forget                 Remove all cached packages
  -Help                   Show this help

Flags:
  --pass                  Skip the Y/N confirmation prompt and proceed immediately
  --force                 Override reverse-dependency and already-installed safety checks
                          (removal still asks for confirmation)
  --with-deps             With -Remove, also remove dependencies that are no longer
                          required by any installed package (never removes packages
                          installed explicitly)
  --detail                With -Remove, list every file that would be deleted
  --silence               Suppress per-file 'provided' output and tar extraction
                           listings (faster on slow terminals)
  --no-quote              Disable random startup quotes

Configuration:
  /etc/zeta/configuration.lua   System-wide configuration (Lua table)
  Precedence: env vars > config file > defaults

  Example /etc/zeta/configuration.lua:
    return {
      repo = "https://github.com/gretagen/zeta-packages",
      root = "/",
      verbose = false,
      quotes = false,
    }

Installed state is tracked in two registries under /var/db/zeta:
  packages/<name>      every package you installed explicitly
  dependencies/<name>  packages pulled in automatically as dependencies

Environment:
  ZETA_ROOT            Filesystem root packages are installed into   (default: /)
  ZETA_REPO            Remote repository base URL (github.com served via    (default: https://github.com/gretagen/zeta-packages)
                       raw.githubusercontent.com)
  ZETA_LOCAL_PACKAGES  Local /packages tree                          (default: /usr/share/packages)
  ZETA_CACHE           Download cache                                (default: $ZETA_ROOT/var/cache/zeta)
  ZETA_STATE           Package database                              (default: $ZETA_ROOT/var/db/zeta)
  ZETA_VERBOSE         Verbose output (1 or true to enable)          (default: false)

Package format (one package.lua per package, returning a table):
  return {
    name="glib", version="2.88.1", url="https://.../glib-2.88.1.tar.xz",
    sha256="...", deps={"libffi","pcre2"},
    archive={ strip=1 },          -- binary install: fetch, unpack, install
    -- or: install=function(p) ... end,   or: build=function(p) ... end
    test=function(p) ... end,     -- optional verification hook for -Test
  }

-Test runs the package's full pipeline (fetch, checksum, unpack/build) into a
scratch directory and then runs its `test` hook when declared; without a hook
it passes on payload integrity plus a non-empty staging tree. It is strictly
offline and never installs anything or touches the package database.
]]

function actions.help()
	io.write(HELP)
end

-- Y/N confirmation. --pass skips it. Returns true to proceed.
-- When `default_no` is true, an empty line cancels (default: " [y/N]").
-- Otherwise an empty line proceeds (default: " [Y/n]").
local function confirm(msg, pass, suffix, default_no)
  suffix = suffix or (default_no and "  Proceed? [y/N]" or "  Proceed? [Y/n]")
  if pass then
    return true
  end
  io.write(msg .. suffix .. " ")
  io.flush()
  local line = io.read("*l")
  if not line then
    return false
  end
  line = line:lower()
  if line == "" then return not default_no end
  return line == "y" or line == "yes"
end

-- The database kind for a plan item: the explicit target becomes a package
-- unless it already lives as a dependency (a -ReProvide of a dependency stays
-- a dependency); every other item becomes a dependency unless it is already
-- an explicitly installed package (never demoted).
local function plan_kind(item, target)
	local cur = db.kind(item)
	if item == target then
		return (cur == "dependency") and "dependency" or "package"
	end
	return (cur == "package") and "package" or "dependency"
end

-- Shared install flow for -Provide / -LocalProvide / -ReProvide.
function actions._install(name, flags, opts)
	local source = opts.source
	local base = config.get().local_packages

	local fetch_manifest
	if source == "local" then
		-- Local packages resolve from the local tree; deps missing there fall
		-- back to the remote repository, so mixed trees keep working.
		fetch_manifest = function(n)
			local m, err = manifest.load(path.join(base, n, "package.lua"))
			if m then
				local ok, cerr = manifest.check_name(m, n)
				if not ok then
					return nil, cerr
				end
				m._local_dir = path.join(base, n)
				return m
			end
			log.detail(("local package %q not found, falling back to remote"):format(n))
			return repo.fetch_manifest(n)
		end
	else
		fetch_manifest = function(n)
			return repo.fetch_manifest(n)
		end
	end

	-- Prefetch all manifests in parallel (breadth-first discovery).
	-- This replaces sequential per-package fetching with a single batch
	-- download, significantly speeding up dependency resolution.
	local manifest_cache = {}
	local seen = { [name] = true }
	local queue = { name }
	local cfg = config.get()

	while #queue > 0 do
		local batch = {}
		for _, n in ipairs(queue) do
			if not manifest_cache[n] and not db.is_installed(n) then
				batch[#batch + 1] = n
			end
		end
		queue = {}

		if #batch > 0 then
			local items = {}
			for _, n in ipairs(batch) do
				items[#items + 1] = {
					url = repo.manifest_url(n),
					dest = path.join(cfg.tmp_dir, "prefetch-" .. n .. "-" .. tostring(math.random(10000, 99999)) .. ".lua"),
					_name = n,
				}
			end

	local results = fetch.get_parallel(items)
			for i, result in ipairs(results) do
				local n = batch[i]
				if result.dest then
					local f = io.open(result.dest, "rb")
					if f then
						local src = f:read("*a")
						f:close()
						os.remove(result.dest)
						local m, merr = manifest.load_string(src, repo.manifest_url(n))
						if m then
							local ok, cerr = manifest.check_name(m, n)
							if ok then
								manifest_cache[n] = m
								for _, dep in ipairs(m.deps or {}) do
									if not seen[dep.name] then
										seen[dep.name] = true
										queue[#queue + 1] = dep.name
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Wrap fetch_manifest with the prefetch cache.
	local function cached_fetch_manifest(n)
		if manifest_cache[n] then return manifest_cache[n] end
		return fetch_manifest(n)
	end

	os.execute("sleep 1")
	spinner.start("Resolving dependencies")
	local ok, plan = pcall(deps.resolve, name, {
		fetch_manifest = cached_fetch_manifest,
		installed_version = function(n)
			local m = db.get(n)
			return m and m.version or nil
		end,
	})
	spinner.stop()
	if not ok then
		log.error(tostring(plan))
		return 1
	end
	if #plan == 0 then
		return 0
	end

	-- Identify which repo the target package belongs to by inspecting the
	-- manifest URL. The repo name lives in the path between the host and the
	-- packages/ prefix: .../zeta-<kind>/.../<name>/package.lua
	local target_item = plan[#plan]
	if target_item and target_item.manifest.url then
		local repo_name = target_item.manifest.url:match("zeta%-([^/]+)")
		if repo_name then
			log.step("Core package found at: zeta-" .. repo_name)
		end
	end

	for _, item in ipairs(plan) do
		print(("  will provide %s-%s"):format(item.name, item.manifest.version))
	end
	print("")

	if not confirm(("Install %d package(s)?"):format(#plan), flags.pass) then
		log.info("aborted by user")
		return 0
	end

	local installed = {}
	local pre_fetched = {}

	-- Phase 1: Resolve and download all payloads in parallel.
	local fetch_items = {}
	for _, item in ipairs(plan) do
		if not (db.is_installed(item.name) and not flags.force) then
			local info, err = builder.fetch_payload(item.manifest, {
				local_dir = item.manifest._local_dir,
			})
			if info then
				if info.cached then
					pre_fetched[item.name] = info.cached
				elseif info.url then
					fetch_items[#fetch_items + 1] = {
						url = info.url,
						dest = info.dest,
						label = item.manifest.name .. "-" .. item.manifest.version,
						_name = item.name,
					}
				end
			elseif err then
				log.warn(("could not resolve payload for %s: %s"):format(item.name, tostring(err)))
			end
		end
	end

	if #fetch_items > 0 then
		local results = fetch.get_parallel(fetch_items)
		for i, result in ipairs(results) do
			local item_name = fetch_items[i]._name
			if result.err then
				log.error(("download failed for %s: %s"):format(item_name, result.err))
				return 1
			elseif result.dest then
				pre_fetched[item_name] = result.dest
			end
		end
	end

	-- Phase 2: Build, commit, and record each package sequentially.
	for _, item in ipairs(plan) do
		if db.is_installed(item.name) and not flags.force then
			log.warn(("%s already provided, skipping"):format(item.name))
		else
			local iok, ierr = pcall(builder.install, item.manifest, {
				force = flags.force,
				source = source,
				local_dir = item.manifest._local_dir,
				kind = plan_kind(item.name, name),
				pre_fetched = pre_fetched[item.name],
			})
			if not iok then
				log.error(tostring(ierr))
				return 1
			end
			installed[item.name] = true
		end
	end

	-- Post-transaction hooks (deps already present on disk at this point).
	if next(installed) then
		local hfail = pcall(hooks.run_installed, installed)
		if not hfail then
			log.error("hook runner failed")
		end
	end
	return 0
end

function actions.provide(names, flags)
	for _, raw in ipairs(names) do
		local name = path.sanitize_name(raw)
		if not name then
			log.error("invalid package name: " .. tostring(raw))
			return 1
		end
		if not flags.force and db.is_installed(name) then
			local m = db.get(name)
			log.warn(("%s-%s has already been provided -- use -ReProvide instead"):format(name, m and m.version or "?"))
		else
			local ok = actions._install(name, flags, { source = "remote" })
			if ok ~= 0 then
				return ok
			end
		end
	end
	return 0
end

function actions.reprovide(names, flags)
	for _, raw in ipairs(names) do
		local name = path.sanitize_name(raw)
		if not name then
			log.error("invalid package name: " .. tostring(raw))
			return 1
		end
		local ok = actions._install(name, { pass = flags.pass, force = true }, { source = "remote" })
		if ok ~= 0 then
			return ok
		end
	end
	return 0
end

function actions.localprovide(names, flags)
	for _, raw in ipairs(names) do
		local name = path.sanitize_name(raw)
		if not name then
			log.error("invalid package name: " .. tostring(raw))
			return 1
		end
		if not flags.force and db.is_installed(name) then
			local m = db.get(name)
			log.warn(("%s-%s has already been provided, use -ReProvide instead."):format(name, m and m.version or "?"))
		else
			local ok = actions._install(name, flags, { source = "local" })
			if ok ~= 0 then
				return ok
			end
		end
	end
	return 0
end

local function print_section(title, names)
	print(title)
	print(("%-20s %-16s %s"):format("PACKAGE", "VERSION", "DEPS"))
	print(string.rep("-", 60))
	for _, n in ipairs(names) do
		local m = db.get(n)
		local deps_str = (m and m.deps and #m.deps > 0) and table.concat(m.deps, " ") or "-"
		print(("%-20s %-16s %s"):format(n, m and m.version or "?", deps_str))
	end
end

function actions.list()
	local packages = db.list_packages()
	local dependencies = db.list_dependencies()
	if #packages == 0 and #dependencies == 0 then
		log.info("no packages provided")
		return 0
	end
	if #packages > 0 then
		print_section(("PACKAGES (%d)"):format(#packages), packages)
		if #dependencies > 0 then
			print("")
		end
	end
	if #dependencies > 0 then
		print_section(("DEPENDENCIES (%d)"):format(#dependencies), dependencies)
	end
	return 0
end

function actions.localize(query)
	local matches, err = repo.search(query)
	if not matches then
		log.error(tostring(err))
		return 1
	end
	if #matches == 0 then
		log.info(("no packages match %q"):format(query))
		return 0
	end
	print(("%-20s %-16s %s"):format("PACKAGE", "VERSION", "SUMMARY"))
	print(string.rep("-", 70))
	for _, m in ipairs(matches) do
		print(("%-20s %-16s %s"):format(m.name, m.version or "?", m.summary or ""))
	end
	return 0
end

-- -Test <pkg>: strictly offline validation. Resolution is local-tree only
-- (no remote fallback) and any manifest whose payload is a remote url is
-- refused. Nothing is installed, committed, or recorded -- build + test run
-- against a scratch tree that is discarded afterwards.
function actions.test(name, flags)
	name = path.sanitize_name(name)
	if not name then
		log.error("invalid package name")
		return 1
	end
	local base = config.get().local_packages

	local fetch_manifest = function(n)
		local dir = path.join(base, n)
		local m, err = manifest.load(path.join(dir, "package.lua"))
		if not m then
			return nil, ("package %q not found in local tree %s (offline test, no remote fallback)"):format(n, base)
		end
		local ok, cerr = manifest.check_name(m, n)
		if not ok then
			return nil, cerr
		end
		if m.url and m.url:match("^https?://") then
			return nil, ("offline test refused: %s-%s has a remote url %s"):format(m.name, m.version, m.url)
		end
		m._local_dir = dir
		return m
	end

	local ok, plan = pcall(deps.resolve, name, {
		fetch_manifest = fetch_manifest,
		installed_version = function(n)
			local m = db.get(n)
			return m and m.version or nil
		end,
	})
	if not ok then
		log.error(tostring(plan))
		return 1
	end
	if #plan == 0 then
		return 0
	end

	print("")
	for _, item in ipairs(plan) do
		print(("  will test %s-%s"):format(item.name, item.manifest.version))
	end
	print("")

	for _, item in ipairs(plan) do
		local tok, terr = pcall(builder.test, item.manifest, {
			local_dir = item.manifest._local_dir,
		})
		if not tok then
			log.error(tostring(terr))
			return 1
		end
	end
	return 0
end

-- Unlink the owned files of an entry, skipping unsafe paths and shared
-- files, then prune now-empty parents. `pkg_name` is used to check
-- other owners.
local function delete_files(files, pkg_name)
  local root = config.get().root
  local dirs = {}
  local seen = {}
  for _, rel in ipairs(files) do
    if rel == "" or rel == "." or rel:match("^/") or rel:match("^%.%.")
       or rel:match("%.%.%/") then
      log.warn(("  skipping unsafe path %q"):format(rel))
    elseif #db.other_owners(pkg_name, rel) > 0 then
      log.detail(("  skipping %s (shared with %s)"):format(rel,
        table.concat(db.other_owners(pkg_name, rel), ", ")))
    else
      local p = path.join(root, rel)
      os.remove(p)
      log.detail(("  removed %s"):format(rel))
      local d = path.dirname(p)
      while d ~= "/" and d ~= "." and not seen[d] do
        seen[d] = true
        dirs[#dirs + 1] = d
        d = path.dirname(d)
      end
    end
  end
  table.sort(dirs, function(a, b)
    return #a > #b
  end)
  for _, d in ipairs(dirs) do
    os.remove(d) -- rmdir; silently fails when non-empty
  end
end

-- Helper: return reverse dependents of `name` that are NOT in `planned`.
local function remaining_dependents(name, planned)
  local out = {}
  for _, d in ipairs(db.reverse_dependents(name)) do
    if not planned[d] then
      out[#out + 1] = d
    end
  end
  return out
end

-- Determine the transitive set of dependency-kind entries that would
-- become orphaned if everything in `planned` were removed.  `seed` gives the
-- starting removal order (the explicit targets, dependents first).  Returns
-- two values: the full removal order (seed then cascaded deps) and a table
-- of { dep = rd_list } for deps that were skipped because they are still
-- required by something outside the plan.
local function resolve_cascade(planned, seed)
  local order = {}
  for _, n in ipairs(seed) do
    order[#order + 1] = n
  end
  local skip = {}
  local i = 1
  while i <= #order do
    local n = order[i]
    local m = db.get(n)
    for _, dep in ipairs(m and m.deps or {}) do
      if db.kind(dep) == "dependency" and not planned[dep] then
        local rd = remaining_dependents(dep, planned)
        if #rd == 0 then
          planned[dep] = true
          order[#order + 1] = dep
        else
          skip[dep] = rd
        end
      end
    end
    i = i + 1
  end
  return order, skip
end

function actions.remove(names, flags)
  -- 1) Sanitize and validate all names up-front.
  local targets = {}
  for _, raw in ipairs(names) do
    local name = path.sanitize_name(raw)
    if not name then
      log.error("package is invalid : " .. tostring(raw))
      return 1
    end
    targets[#targets + 1] = name
  end
  for _, n in ipairs(targets) do
    if not db.kind(n) then
      log.error(("%s has not been provided."):format(n))
      return 1
    end
  end

  -- 2) Build planned set from explicit targets.
  local planned = {}
  for _, n in ipairs(targets) do
    planned[n] = true
  end

  -- 3) Hard reverse-dependency check for every explicit target.
  if not flags.force then
    for _, n in ipairs(targets) do
      local rd = remaining_dependents(n, planned)
      if #rd > 0 then
        log.error(("Unable to remove %s as it is still required by %s if you are sure about this, use --force flag"):format(
          n, table.concat(rd, ", ")))
        return 1
      end
    end
  end

  -- 4) Cascade into orphaned dependencies if --with-deps.
  local removal_order = targets
  local skipped = {}
  if flags.with_deps then
    removal_order, skipped = resolve_cascade(planned, targets)
  end

  -- 5) Build the full removal plan.
  local plan = {}
  for _, n in ipairs(removal_order) do
    local m = db.get(n)
    local files = db.files(n)
    local shared = 0
    for _, rel in ipairs(files) do
      if #db.other_owners(n, rel) > 0 then
        shared = shared + 1
      end
    end
    plan[#plan + 1] = {
      name = n,
      version = m and m.version or "?",
      kind = db.kind(n),
      files = files,
      shared = shared,
      dependents = remaining_dependents(n, planned),
    }
  end

  if #plan == 0 then
    return 0
  end

  -- 6) Print the plan (mirrors -Provide).
  print("")
  for _, e in ipairs(plan) do
    local count = #e.files == 1 and "1 file" or (#e.files .. " files")
    local note = count
    if e.shared > 0 then
      note = note .. (", %d shared kept"):format(e.shared)
    end
    print(("  will remove %s-%s (%s)"):format(e.name, e.version, note))
    if flags.detail then
      for _, rel in ipairs(e.files) do
        print(("      %s"):format(rel))
      end
    end
    if #e.dependents > 0 then
      print(("    !! removing %s breaks: %s"):format(
        e.name, table.concat(e.dependents, ", ")))
    end
  end
  for dep, rd in pairs(skipped) do
    print(("  keep %s (still required by %s)"):format(
      dep, table.concat(rd, ", ")))
  end
  print("")

  -- 7) Single confirmation, default NO.
  local noun = #plan == 1 and "1 package" or (#plan .. " packages")
  if not confirm(("Remove %s?"):format(noun), flags.pass, " [y/N]", true) then
    log.info("aborted by user")
    return 0
  end

  -- 8) Execute removals.
  for _, e in ipairs(plan) do
    local m = db.get(e.name)
    log.step(("removing %s-%s (%d files)"):format(e.name, e.version, #e.files))
    delete_files(e.files, e.name)
    db.remove(e.name)
    for _, d in ipairs(m and m.deps or {}) do
      db.remove_dependent(d, e.name)
    end
    log.ok(("removed %s"):format(e.name))
  end
  return 0
end

function actions.transcend(flags)
	local installed = db.list()
	if #installed == 0 then
		log.info("no packages provided")
		return 0
	end

	local cfg = config.get()

	-- Phase 1: Fetch all manifests in parallel to check for upgrades.
	local items = {}
	local installed_info = {}
	for _, name in ipairs(installed) do
		local cur = db.get(name)
		if cur then
			installed_info[name] = cur
			items[#items + 1] = {
				url = repo.manifest_url(name),
				dest = path.join(cfg.tmp_dir, "transcend-" .. name .. "-" .. tostring(math.random(10000, 99999)) .. ".lua"),
				_name = name,
			}
		end
	end

	if #items == 0 then
		log.info("no packages provided")
		return 0
	end

	local results = fetch.get_parallel(items, { label = "checking for packages to transcend" })
	local manifest_cache = {}
	for i, result in ipairs(results) do
		local name = items[i]._name
		if result.dest then
			local f = io.open(result.dest, "rb")
			if f then
				local src = f:read("*a")
				f:close()
				os.remove(result.dest)
				local m, merr = manifest.load_string(src, repo.manifest_url(name))
				if m then
					local ok, cerr = manifest.check_name(m, name)
					if ok then
						manifest_cache[name] = m
					end
				end
			end
		end
	end

	-- Compare versions to find upgrades.
	local upgrades = {}
	for _, name in ipairs(installed) do
		local cur = installed_info[name]
		local remote = manifest_cache[name]
		if cur and remote then
			local cmp = vercmp.compare(cur.version, remote.version)
			if cmp < 0 then
				upgrades[#upgrades + 1] = {
					name = name,
					from = cur.version,
					to = remote.version,
					manifest = remote,
				}
			end
		end
	end

	if #upgrades == 0 then
		log.info("all packages are up to date")
		return 0
	end

	print("")
	for _, u in ipairs(upgrades) do
		print(("  will transcend %s %s -> %s"):format(u.name, u.from, u.to))
	end
	print("")

	if not confirm(("Transcend %d package(s)?"):format(#upgrades), flags.pass) then
		log.info("aborted by user")
		return 0
	end

	-- Phase 2: Pre-fetch all payloads in parallel.
	local pre_fetched = {}
	local fetch_items = {}
	for _, u in ipairs(upgrades) do
		local info, err = builder.fetch_payload(u.manifest, { force = true, source = "remote" })
		if info then
			if info.cached then
				pre_fetched[u.name] = info.cached
			elseif info.url then
				fetch_items[#fetch_items + 1] = {
					url = info.url,
					dest = info.dest,
					label = u.manifest.name .. "-" .. u.manifest.version,
					_name = u.name,
				}
			end
		elseif err then
			log.warn(("could not resolve payload for %s: %s"):format(u.name, tostring(err)))
		end
	end

	if #fetch_items > 0 then
		local dl_results = fetch.get_parallel(fetch_items)
		for i, result in ipairs(dl_results) do
			local item_name = fetch_items[i]._name
			if result.err then
				log.error(("download failed for %s: %s"):format(item_name, result.err))
				return 1
			elseif result.dest then
				pre_fetched[item_name] = result.dest
			end
		end
	end

	-- Phase 3: Build, commit, and record each package sequentially.
	for _, u in ipairs(upgrades) do
		local iok, ierr = pcall(builder.install, u.manifest, {
			force = true,
			source = "remote",
			kind = db.kind(u.name) or "package",
			pre_fetched = pre_fetched[u.name],
		})
		if not iok then
			log.error(tostring(ierr))
			return 1
		end
	end
	return 0
end

function actions.forget(pass)
	local cfg = config.get()
	if not confirm("Remove all cached packages?", pass, " [y/N]", true) then
		log.info("aborted by user")
		return 0
	end
	path.run("rm -rf " .. path.quote(cfg.cache_dir) .. "/*")
	log.info("cache has been cleared")
	return 0
end

return actions
