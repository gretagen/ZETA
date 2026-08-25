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

local HELP = [[
Zeta -- Zerene OS package manager

Usage: zeta <command> [arguments] [flags]

Commands:
  -Provide <pkg>...       Install packages and their dependencies from the remote repository
  -ReProvide <pkg>...     Reinstall packages even if they are already installed
  -LocalProvide <pkg>...  Install packages from the local /packages tree
  -Elevate                Update all installed packages to their latest versions
  -Remove <pkg>...        Remove installed packages (see --with-deps)
  -List                   List installed packages and dependencies
  -Localize <query>       Search the remote repository index for <query>
  -Test <pkg>             Verify <pkg> offline WITHOUT installing it
  -Help                   Show this help

Flags:
  --pass                  Skip the Y/N confirmation prompt and proceed immediately
  --force                 Override file-conflict and reverse-dependency safety checks
  --with-deps             With -Remove, also remove dependencies that are no longer
                          required by any installed package (never removes packages
                          installed explicitly)

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
-- `suffix` defaults to "  Proceed? [y/N]"; dependency warnings carry their
-- own question text and pass " [y/N]".
local function confirm(msg, pass, suffix)
	suffix = suffix or "  Proceed? [Y/n]"
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
	return line == "" or line == "y" or line == "yes"
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

	for _, item in ipairs(plan) do
		print(("  will provide %s-%s"):format(item.name, item.manifest.version))
	end
	print("")

	if not confirm(("Install %d package(s)?"):format(#plan), flags.pass) then
		log.info("aborted by user")
		return 0
	end

	local installed = {}
	for _, item in ipairs(plan) do
		if db.is_installed(item.name) and not flags.force then
			log.warn(("%s already installed, skipping"):format(item.name))
		else
			local iok, ierr = pcall(builder.install, item.manifest, {
				force = flags.force,
				source = source,
				local_dir = item.manifest._local_dir,
				kind = plan_kind(item.name, name),
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
			log.warn(("%s-%s is already installed -- use -ReProvide to reinstall"):format(name, m and m.version or "?"))
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
			log.warn(("%s-%s is already installed -- use -ReProvide to reinstall"):format(name, m and m.version or "?"))
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
		log.info("no packages installed")
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

-- Unlink the owned files of an entry, skipping shared files, then prune
-- now-empty parents. `pkg_name` is used to check for other owners.
local function delete_files(files, pkg_name)
	local root = config.get().root
	local dirs = {}
	local seen = {}
	for _, rel in ipairs(files) do
		local others = db.other_owners(pkg_name, rel)
		if #others > 0 then
			log.detail(("  skipping %s (shared with %s)"):format(rel, table.concat(others, ", ")))
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

-- Remove one entry. Returns true, "removed"|"skip"|"abort" for handled
-- outcomes and nil, errmsg for hard failures. `via_cascade` marks entries
-- reached through --with-deps: those are never forced past remaining
-- dependents. `state` carries the shared removed/planned sets so names
-- touched earlier in the same invocation (explicitly or by the cascade) are
-- skipped rather than re-processed.
local function remove_one(name, via_cascade, flags, state)
	if state.removed[name] then
		if not via_cascade then
			log.info(("%s already removed, skipping"):format(name))
		end
		return true, "skip"
	end
	local kind = db.kind(name)
	if not kind then
		return nil, ("%s is not installed"):format(name)
	end

	-- Dependents still being removed in this same invocation do not block.
	local rd = {}
	for _, d in ipairs(db.reverse_dependents(name)) do
		if not state.planned[d] then
			rd[#rd + 1] = d
		end
	end

	if #rd > 0 and not flags.force then
		if via_cascade then
			log.info(("skipping %s: still depended on by %s"):format(name, table.concat(rd, ", ")))
			return true, "skip"
		end
		if kind == "package" then
			return nil,
				("cannot remove %s: still required by %s (use --force to override)"):format(
					name,
					table.concat(rd, ", ")
				)
		end
	end

	local proceed = flags.pass or flags.force
	if not proceed then
		if kind == "dependency" and #rd == 0 then
			proceed = true -- orphaned dependency: no confirmation needed
		elseif kind == "dependency" then
			local who = #rd == 1 and rd[1] or (#rd .. " packages")
			proceed = confirm(("%s is a dependency of %s, Proceed with removal?"):format(name, who), false, " [y/N]")
		else
			proceed = confirm(("Remove %s?"):format(name), false)
		end
	end
	if not proceed then
		log.info("aborted by user")
		return true, "abort"
	end

	local m = db.get(name)
	local files = db.files(name)
	log.step(("removing %s-%s (%d files)"):format(name, m and m.version or "?", #files))
	delete_files(files, name)
	db.remove(name)
	state.removed[name] = true
	-- Drop this entry from the dependents lists of everything it depended on.
	for _, d in ipairs(m and m.deps or {}) do
		db.remove_dependent(d, name)
	end
	log.ok(("removed %s"):format(name))

	if flags.with_deps then
		for _, d in ipairs(m and m.deps or {}) do
			-- Cascade only into dependency-kind entries; explicitly installed
			-- packages are never removed implicitly.
			if db.kind(d) == "dependency" then
				remove_one(d, true, flags, state)
			end
		end
	end
	return true, "removed"
end

function actions.remove(names, flags)
	local state = { removed = {}, planned = {} }
	for _, n in ipairs(names) do
		state.planned[n] = true
	end
	for _, raw in ipairs(names) do
		local name = path.sanitize_name(raw)
		if not name then
			log.error("invalid package name: " .. tostring(raw))
			return 1
		end
		local ok, err = remove_one(name, false, flags, state)
		if not ok then
			log.error(err)
			return 1
		end
	end
	return 0
end

function actions.elevate(flags)
	local installed = db.list_packages()
	if #installed == 0 then
		log.info("no packages installed")
		return 0
	end

	local upgrades = {}
	for _, name in ipairs(installed) do
		local cur = db.get(name)
		if cur then
			local ok, remote = pcall(repo.fetch_manifest, name)
			if ok and remote then
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
	end

	if #upgrades == 0 then
		log.info("all packages are up to date")
		return 0
	end

	print("")
	for _, u in ipairs(upgrades) do
		print(("  will upgrade %s %s -> %s"):format(u.name, u.from, u.to))
	end
	print("")

	if not confirm(("Upgrade %d package(s)?"):format(#upgrades), flags.pass) then
		log.info("aborted by user")
		return 0
	end

	for _, u in ipairs(upgrades) do
		local iok, ierr = pcall(builder.install, u.manifest, {
			force = true,
			source = "remote",
			kind = db.kind(u.name) or "package",
		})
		if not iok then
			log.error(tostring(ierr))
			return 1
		end
	end
	return 0
end

return actions
