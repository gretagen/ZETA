-- archive.lua -- tar inspection and safe extraction.
--
-- Extraction is a two-phase process: list the archive and validate every
-- member (no absolute paths, no ".." escapes, symlink targets that stay
-- inside the root) BEFORE extracting anything. A hostile or malformed archive
-- is therefore rejected without touching the filesystem. Symlink detection
-- relies on the `name -> target` form printed by tar for symbolic links.

local archive = {}

local path = require("path")
local log = require("log")

local function rel_of(member)
  local rel = member:gsub("^%./+", "")
  rel = rel:gsub("/+$", "")
  return rel
end

-- Classify the members of a tar archive.
-- Returns entries = { { path=rel, type="file"|"dir"|"symlink", target=.. } }.
--
-- Plain `tar -tf` prints names only (no link targets), so symlink safety
-- could not be checked from it. We therefore run TWO passes and walk them in
-- lockstep (both list members in archive order): `tar -tf` for the clean
-- member names, `tar -tvf` for the file type (verbose mode's leading char)
-- and, for symlinks, the `name -> target` marker.
function archive.entries(archive_file)
  local nf = io.popen("tar -tf " .. path.quote(archive_file) .. " 2>/dev/null")
  if not nf then return nil, "could not run tar" end
  local names = {}
  for line in nf:lines() do
    local name = line
    local is_dir = name:sub(-1) == "/"
    if is_dir then name = name:sub(1, -2) end
    names[#names + 1] = { name = name, dir = is_dir }
  end
  nf:close()

  local vf = io.popen("tar -tvf " .. path.quote(archive_file) .. " 2>/dev/null")
  local entries = {}
  local i = 0
  if vf then
    for line in vf:lines() do
      i = i + 1
      local info = names[i]
      if info then
        local typc = line:sub(1, 1)
        local target
        local typ
        if typc == "l" then
          typ = "symlink"
          target = line:match(" -> (%S+)$") or ""
        elseif typc == "d" then
          typ = "dir"
        else
          typ = "file"
        end
        local rel = rel_of(info.name)
        if rel ~= "" then
          entries[#entries + 1] = { path = rel, type = typ, target = target }
        end
      end
    end
    vf:close()
  end
  return entries
end

-- Validate that no member escapes the extraction root. Returns true or nil, err.
function archive.validate(entries)
  for _, e in ipairs(entries) do
    if e.path == "" or e.path:match("^/") or not path.relative_inside(e.path) then
      return nil, ("archive member %q escapes the root"):format(e.path)
    end
    if e.type == "symlink" and path.symlink_escapes(e.path, e.target) then
      return nil, ("symlink %q -> %q escapes the root"):format(e.path, e.target)
    end
  end
  return true
end

-- Extract `archive_file` into `dest`. Returns the validated entries, or
-- nil, err if validation or extraction fails.
function archive.extract(archive_file, dest, opts)
  opts = opts or {}
  local entries, err = archive.entries(archive_file)
  if not entries then return nil, err end
  local ok, verr = archive.validate(entries)
  if not ok then return nil, verr end
  local strip = opts.strip or 0
  local cmd = "tar -xvf " .. path.quote(archive_file)
    .. " -C " .. path.quote(dest) .. " --no-same-owner"
  if strip > 0 then
    cmd = cmd .. " --strip-components=" .. tostring(strip)
  end
  log.detail(("archive: extracting %s into %s%s"):format(
    path.basename(archive_file), dest,
    strip > 0 and (" (strip " .. strip .. ")") or ""))
  if not path.run(cmd) then
    return nil, ("failed to extract %s"):format(archive_file)
  end
  return entries
end

return archive
