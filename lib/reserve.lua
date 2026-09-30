-- reserve.lua -- the isolated package store (/zeta/reserve).
--
-- Layout (mirrors /nix/store + a profile, exposed FHS-style):
--   <reserve_dir>/<name>-<version>/   self-contained root: package + all deps
--   <reserve_dir>/profile/bin/        wrappers exposing the package's own
--                                     binaries under their original names
--   <root>/usr/bin/<name> ->          symlinks into profile/bin so isolated
--   <root>/usr/sbin/<name>            packages run from the default PATH
--
-- Profile entries are small shell wrappers, not bare symlinks: binaries in
-- the store must resolve their libraries inside the store, and the dynamic
-- linker otherwise consults only the host's ld.so.cache. The wrapper sets
-- LD_LIBRARY_PATH to the store's lib dirs, so from PATH the binary behaves
-- exactly like a nixpkgs package (same name, no prefix).

local reserve = {}

local path = require("path")
local config = require("config")
local log = require("log")

-- Store path for a package version. Version is sanitized because it becomes
-- a directory name (manifest versions are trusted-ish but never worth
-- trusting with a path).
function reserve.store_path(name, version)
  local v = tostring(version or "0"):gsub("[^%w%.%+%-_]", "_")
  return path.join(config.get().reserve_dir, name .. "-" .. v)
end

-- Bin dirs relative to a store root whose entries are user-facing commands.
local BIN_DIRS = { "usr/bin", "bin", "usr/sbin", "sbin" }

-- Classify a store rel path as "bin" or "sbin" (FHS placement), or nil when
-- the entry is not a top-level command.
local function bin_class(rel)
  for _, d in ipairs(BIN_DIRS) do
    if rel:sub(1, #d + 1) == d .. "/" and not rel:sub(#d + 2):find("/") then
      return (d == "usr/sbin" or d == "sbin") and "sbin" or "bin"
    end
  end
  return nil
end

local function is_bin_rel(rel)
  return bin_class(rel) ~= nil
end

local function wrapper_body(store, rel)
  -- Cover every lib dir shape used by glibc-style layouts (/lib, /usr/lib
  -- and their lib64 usr-merge variants) so the store is self-contained even
  -- when the host ld.so.cache would otherwise supply the libraries.
  local lib_dirs = {}
  for _, d in ipairs({ "usr/lib", "lib", "usr/lib64", "lib64" }) do
    lib_dirs[#lib_dirs + 1] = store .. "/" .. d
  end
  return "#!/bin/sh\n"
    .. "export LD_LIBRARY_PATH=\"" .. table.concat(lib_dirs, ":")
    .. "${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"\n"
    .. "exec " .. path.quote(path.join(store, rel)) .. " \"$@\"\n"
end

-- Create profile wrappers for every binary the package itself owns. `files`
-- is the package's own owned-rel list (dependencies' binaries stay hidden —
-- they exist only for the store's internals, like nixpkgs).
-- Returns the list of wrapper paths created.
function reserve.link_profile(store, files)
  local bin_dir = path.join(config.get().reserve_dir, "profile/bin")
  path.mkdir_p(bin_dir)
  local created = {}
  for _, rel in ipairs(files) do
    if is_bin_rel(rel) then
      local name = rel:match("([^/]+)$")
      local wrap = path.join(bin_dir, name)
      local f = io.open(wrap, "w")
      if f then
        f:write(wrapper_body(store, rel))
        f:close()
        path.run("chmod +x " .. path.quote(wrap))
        created[#created + 1] = wrap
      end
    end
  end
  return created
end

-- Remove every profile wrapper that points into `store`. Returns the number
-- of wrappers removed.
function reserve.unlink_profile(store)
  local bin_dir = path.join(config.get().reserve_dir, "profile/bin")
  local f = path.popen("ls -1 " .. path.quote(bin_dir) .. " 2>/dev/null")
  if not f then return 0 end
  local removed = 0
  for line in f:lines() do
    if line ~= "" then
      local wrap = path.join(bin_dir, line)
      local h = io.open(wrap, "rb")
      if h then
        local body = h:read("*a") or ""
        h:close()
        if body:find("exec " .. store, 1, true) or body:find("\"" .. store, 1, true) then
          os.remove(wrap)
          removed = removed + 1
        end
      end
    end
  end
  f:close()
  return removed
end

-- FHS system links: /usr/bin/<name> and /usr/sbin/<name> pointing at the
-- profile wrappers, so isolated packages are runnable from the default PATH
-- with no environment changes. A link target must be the wrapper (never the
-- store binary directly) so LD_LIBRARY_PATH gets set.
-- Conflict policy: a free name is linked; an existing reserve-owned link is
-- replaced (last isolated install wins); anything else (a real file from a
-- normal install, a foreign symlink) is left untouched with a warning -- the
-- system copy is never shadowed silently.
-- Returns { linked = n, skipped = n }.
function reserve.link_system(store, files)
  local cfg = config.get()
  local reserve_prefix = cfg.reserve_dir .. "/"
  local result = { linked = 0, skipped = 0 }
  local seen = {}
  for _, rel in ipairs(files) do
    local class = bin_class(rel)
    if class then
      local name = rel:match("([^/]+)$")
      local sys_dir = path.join(cfg.root, class == "sbin" and "usr/sbin" or "usr/bin")
      local link = path.join(sys_dir, name)
      if not seen[link] then
        seen[link] = true
        local wrap = path.join(cfg.reserve_dir, "profile/bin", name)
        local target = path.readlink(link)
        if target == nil and not path.exists(link) then
          path.mkdir_p(sys_dir)
          path.run("rm -f " .. path.quote(link))
          if path.run("ln -sfn " .. path.quote(wrap) .. " " .. path.quote(link)) then
            result.linked = result.linked + 1
          else
            result.skipped = result.skipped + 1
          end
        elseif target and target:sub(1, #reserve_prefix) == reserve_prefix then
          -- Another isolated store owns this name; replacing it is fine.
          path.run("rm -f " .. path.quote(link))
          if path.run("ln -sfn " .. path.quote(wrap) .. " " .. path.quote(link)) then
            result.linked = result.linked + 1
            log.detail(("replaced isolated link %s"):format(link))
          else
            result.skipped = result.skipped + 1
          end
        else
          result.skipped = result.skipped + 1
          log.warn(("%s exists -- isolated %s not linked by name (reachable at %s)"):format(
            link, name, wrap))
        end
      end
    end
  end
  return result
end

-- Remove system links that belong to `store`. Attribution runs through the
-- wrapper: a link in /usr/bin points into profile/bin, and the wrapper body
-- names the store it execs -- so only this store's links are removed and
-- another store's links (or a system binary that reclaimed the name) survive.
-- Must run BEFORE unlink_profile, while the wrappers still exist.
-- Returns the number of links removed.
function reserve.unlink_system(store)
  local cfg = config.get()
  local profile_prefix = path.join(cfg.reserve_dir, "profile/bin") .. "/"
  local removed = 0
  for _, sys_dir in ipairs({ path.join(cfg.root, "usr/bin"), path.join(cfg.root, "usr/sbin") }) do
    local f = path.popen("ls -1 " .. path.quote(sys_dir) .. " 2>/dev/null")
    if f then
      for line in f:lines() do
        if line ~= "" then
          local link = path.join(sys_dir, line)
          local target = path.readlink(link)
          if target and target:sub(1, #profile_prefix) == profile_prefix then
            local h = io.open(target, "rb")
            if h then
              local body = h:read("*a") or ""
              h:close()
              if body:find("exec " .. store, 1, true) or body:find("\"" .. store, 1, true) then
                os.remove(link)
                removed = removed + 1
              end
            end
          end
        end
      end
      f:close()
    end
  end
  return removed
end

-- Wipe an entire store. Guard: the path must live under reserve_dir, so a
-- corrupted or malicious reserve_root in the database can never rm -rf
-- something outside the store.
function reserve.remove_store(store)
  local base = config.get().reserve_dir
  if store == nil or store == "" or store == "/" then return false, "invalid store path" end
  if store:sub(1, #base + 1) ~= base .. "/" then
    return false, ("store path %q is outside %q"):format(store, base)
  end
  path.run("rm -rf " .. path.quote(store))
  return true
end

return reserve
