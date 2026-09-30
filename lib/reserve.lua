-- reserve.lua -- the isolated package store (/zeta/reserve).
--
-- Layout (mirrors /nix/store + a profile):
--   <reserve_dir>/<name>-<version>/   self-contained root: package + all deps
--   <reserve_dir>/profile/bin/        wrappers exposing the package's own
--                                     binaries under their original names
--
-- Profile entries are small shell wrappers, not bare symlinks: binaries in
-- the store must resolve their libraries inside the store, and the dynamic
-- linker otherwise consults only the host's ld.so.cache. The wrapper sets
-- LD_LIBRARY_PATH to the store's lib dirs, so from PATH the binary behaves
-- exactly like a nixpkgs package (same name, no prefix, no /usr/bin pollution).

local reserve = {}

local path = require("path")
local config = require("config")

-- Store path for a package version. Version is sanitized because it becomes
-- a directory name (manifest versions are trusted-ish but never worth
-- trusting with a path).
function reserve.store_path(name, version)
  local v = tostring(version or "0"):gsub("[^%w%.%+%-_]", "_")
  return path.join(config.get().reserve_dir, name .. "-" .. v)
end

-- Bin dirs relative to a store root whose entries are user-facing commands.
local BIN_DIRS = { "usr/bin", "bin", "usr/sbin", "sbin" }

local function is_bin_rel(rel)
  for _, d in ipairs(BIN_DIRS) do
    if rel:sub(1, #d + 1) == d .. "/" and not rel:sub(#d + 2):find("/") then
      return true
    end
  end
  return false
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
