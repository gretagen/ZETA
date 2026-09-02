-- adopt.lua -- register existing rootfs files into the package database.
--
-- Usage: zeta -Adopt <name> [--dir <rel_dir>] [--files <file_list>] [--version <ver>]
--
-- This does NOT copy any files. It creates a database entry so zeta knows
-- who owns those files. This prevents future -Provide installs from silently
-- overwriting them.
--
-- Examples:
--   zeta -Adopt glibc --dir lib64 --version 2.44
--   zeta -Adopt bash --files /tmp/bash-files.txt --version 5.3

local adopt = {}

local config = require("config")
local db = require("db")
local path = require("path")
local log = require("log")

-- Scan a directory recursively, returning relative file paths.
local function scan_dir(root, dir)
  local files = {}
  local full = path.join(root, dir)
  local f = io.popen("find " .. path.quote(full) .. " -type f -printf '%P\\n' 2>/dev/null")
  if f then
    for line in f:lines() do
      if line ~= "" then
        files[#files + 1] = path.join(dir, line)
      end
    end
    f:close()
  end
  -- Also find symlinks
  local s = io.popen("find " .. path.quote(full) .. " -type l -printf '%P\\n' 2>/dev/null")
  if s then
    for line in s:lines() do
      if line ~= "" then
        files[#files + 1] = path.join(dir, line)
      end
    end
    s:close()
  end
  table.sort(files)
  return files
end

-- Read a file list from a newline-separated file.
local function read_list(filepath)
  local files = {}
  local f = io.open(filepath, "rb")
  if not f then
    return nil, ("cannot open file list %s"):format(filepath)
  end
  for line in f:lines() do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:match("^#") then
      files[#files + 1] = line
    end
  end
  f:close()
  return files
end

-- Register a package with existing files.
-- opts: { version, dir, files_path, force, summary }
function adopt.register(name, opts)
  opts = opts or {}
  local root = config.get().root
  local files = {}

  if opts.dir then
    -- Scan directory
    local dir = opts.dir:gsub("^/+", "")
    log.step(("scanning %s/%s"):format(root, dir))
    files = scan_dir(root, dir)
    log.detail(("found %d files in %s"):format(#files, dir))
  elseif opts.files_path then
    -- Read from file list
    local err
    files, err = read_list(opts.files_path)
    if not files then
      error(tostring(err), 0)
    end
    log.detail(("read %d files from %s"):format(#files, opts.files_path))
  else
    error("adopt requires --dir or --files", 0)
  end

  if #files == 0 then
    log.warn(("no files found for %s"):format(name))
    return
  end

  -- Check for ownership conflicts
  local conflicts = {}
  for _, rel in ipairs(files) do
    local owners = db.other_owners(name, rel)
    if #owners > 0 then
      conflicts[#conflicts + 1] = { file = rel, owners = owners }
    end
  end

  if #conflicts > 0 and not opts.force then
    log.warn(("file ownership conflicts (use --force to override):"))
    for _, c in ipairs(conflicts) do
      log.warn(("  %s owned by %s"):format(c.file, table.concat(c.owners, ", ")))
    end
    error(("cannot adopt %d files already owned by other packages"):format(#conflicts), 0)
  end

  if #conflicts > 0 then
    log.warn(("overriding ownership for %d files"):format(#conflicts))
  end

  -- Build manifest for db.record
  local manifest = {
    name = name,
    version = opts.version or "0.0.0",
    summary = opts.summary or ("Adopted package %s"):format(name),
    url = nil,
    sha256 = nil,
    arch = nil,
    prefix = "/usr",
    deps = {},
    source = "adopt",
  }

  db.record(name, manifest, files, { kind = "package" })
  log.ok(("adopted %s with %d files"):format(name, #files))
end

return adopt
