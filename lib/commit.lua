-- commit.lua -- merge a staged install root into the filesystem.
--
-- The staged tree is walked (via `find -printf`, available on all mainstream
-- find implementations), every entry is validated (symlink safety, path
-- hygiene) BEFORE anything is copied, and only then are files copied into
-- ZETA_ROOT. Zeta installs whatever a package ships; init-system and
-- distro-identity paths are not special-cased.

local commit = {}

local path = require("path")
local config = require("config")
local log = require("log")
local spinner = require("spinner")

-- Walk a staged tree: returns entries { { rel, type, target } } where type is
-- "file", "dir" or "symlink". Uses find -printf ('%y|%l|%P') which gives
-- type, symlink target, and root-relative path on a single line.
local function walk_staging(staging)
  local f = path.popen("find " .. path.quote(staging)
    .. " -mindepth 1 -printf '%y|%l|%P\\n' 2>/dev/null")
  if not f then
    error(("could not scan staging directory %s"):format(staging), 0)
  end
  local out = {}
  for line in f:lines() do
    local typ, rest = line:match("^([%w])%|(.*)$")
      if typ then
        local link, rel = rest:match("^([^%|]*)%|(.*)$")
        if not link then link = "" end
        out[#out + 1] = {
          rel = rel,
          type = (typ == "d" and "dir" or (typ == "l" and "symlink" or "file")),
          target = (link ~= "" and link or nil),
        }
      end
  end
  f:close()
  return out
end

-- apply(staging, opts) -> owned entries (files + symlinks + dirs).
-- opts: whitelist (list of rel paths to commit), force, pkg_name.
function commit.apply(staging, opts)
  opts = opts or {}
  local entries = walk_staging(staging)

  if opts.whitelist then
    local wl = {}
    for _, w in ipairs(opts.whitelist) do wl[w] = true end
    local filtered = {}
    for _, e in ipairs(entries) do
      if e.type == "dir" or wl[e.rel] then filtered[#filtered + 1] = e end
    end
    entries = filtered
  end

  local root = config.get().root

  -- Owned entries are all concrete paths a package ships. Filter out directory
  -- entries that are prefixes of other entries: if a package owns usr/bin/hello,
  -- we don't record usr/ or usr/bin/ -- delete_files collects parents dynamically.
  -- This prevents removal from ever attempting to rmdir system directories.
  local non_dir = {}
  local dir_set = {}
  for _, e in ipairs(entries) do
    if e.type == "dir" then
      dir_set[e.rel] = true
    else
      non_dir[#non_dir + 1] = e
    end
  end
  -- Keep only directories that are NOT prefixes of any file/symlink entry.
  local owned = {}
  for _, e in ipairs(entries) do
    if e.type ~= "dir" then
      owned[#owned + 1] = e
    else
      local dominated = false
      for _, nd in ipairs(non_dir) do
        if nd.rel:sub(1, #e.rel + 1) == e.rel .. "/" then
          dominated = true
          break
        end
      end
      if not dominated then
        owned[#owned + 1] = e
      end
    end
  end

  -- Commit non-symlinks before symlinks: a library symlink (libfoo.so.1 ->
  -- libfoo.so.1.2.3) must never point at a file that has not been installed
  -- yet. During an upgrade the target filename may be new, so flipping the
  -- link first leaves a window where every binary that loads the library
  -- fails to exec (e.g. bash dies when libncursesw.so.6 dangles). Stable,
  -- so the walk order is preserved within each group.
  local non_sym, sym = {}, {}
  for _, e in ipairs(owned) do
    if e.type == "symlink" then sym[#sym + 1] = e else non_sym[#non_sym + 1] = e end
  end
  owned = non_sym
  for _, e in ipairs(sym) do owned[#owned + 1] = e end

  -- When the target path is a symlink (e.g. /sbin -> usr/sbin from the
  -- filesystem package), create the real directory the link points at
  -- instead: mkdir -p refuses to follow a dangling symlink. Targets are
  -- relative by construction (symlink_escapes rejects absolute ones), so
  -- resolving against the parent is safe.
  local function ensure_dir(d)
    local target = path.readlink(d)
    if target then
      d = path.join(path.dirname(d), target)
    end
    if not path.mkdir_p(d) then
      error(("failed to create directory %q"):format(d), 0)
    end
  end

  -- Copy phase. Non-verbose TTY mode shows a live updating progress line
  -- that overwrites itself in place. Verbose mode shows detailed per-file
  -- messages. Non-TTY mode skips per-file output entirely.
  local verbose = config.get().verbose
  local use_tty = spinner.enabled()
  local total = #owned
  local done = 0
  local file_count, sym_count, dir_count = 0, 0, 0

  for _, e in ipairs(owned) do
    local dest = path.join(root, e.rel)
    local src = path.join(staging, e.rel)
    if e.type == "dir" then
      ensure_dir(dest)
      dir_count = dir_count + 1
    else
      ensure_dir(path.dirname(dest))
      if e.type == "symlink" then
        if not path.run("ln -sfn " .. path.quote(e.target) .. " " .. path.quote(dest)) then
          error(("failed to create symlink %q"):format(dest), 0)
        end
        sym_count = sym_count + 1
      else
        local tmp = dest .. ".zeta-tmp-" .. tostring(math.random(100000, 999999))
        if not path.run("cp -a " .. path.quote(src) .. " " .. path.quote(tmp)) then
          os.remove(tmp)
          error(("failed to install %q"):format(e.rel), 0)
        end
        if not path.run("mv -f " .. path.quote(tmp) .. " " .. path.quote(dest)) then
          os.remove(tmp)
          error(("failed to install %q"):format(e.rel), 0)
        end
        file_count = file_count + 1
      end
    end

    -- Live progress line (TTY only, non-verbose).
    if use_tty and not verbose then
      done = done + 1
      io.write(("\r\27[K  [ provided %d | %d entries ] %s"):format(done, total, e.rel))
      io.flush()
    end

    -- Verbose: detailed per-file output.
    if verbose then
      if e.type == "dir" then
        log.detail(("  mkdir %s"):format(dest))
      elseif e.type == "symlink" then
        log.detail(("  link %s -> %s"):format(dest, e.target))
      else
        log.detail(("  install %s -> %s"):format(src, dest))
      end
    end
  end

  -- Clear the progress line.
  if use_tty and not verbose then
    io.write("\r\27[K")
    io.flush()
  end

  -- Per-type summary.
  if file_count > 0 then
    log.info(("- committed %d files to %s"):format(file_count, root))
  end
  if sym_count > 0 then
    log.info(("- committed %d symlinks to %s"):format(sym_count, root))
  end
  if dir_count > 0 then
    log.info(("- committed %d dirs to %s"):format(dir_count, root))
  end

  -- Auto-compile GSettings schemas if any were installed.
  local schemas_dir = root .. "/usr/share/glib-2.0/schemas"
  local has_schema = false
  for _, e in ipairs(owned) do
    if e.rel:match("^usr/share/glib%-2%.0/schemas/.+%.gschema%.xml$") then
      has_schema = true
      break
    end
  end
  if has_schema then
    local compile = "glib-compile-schemas " .. path.quote(schemas_dir)
    log.step("compiling GSettings schemas")
    if path.run(compile) then
      log.ok("gschemas.compiled generated")
    else
      log.warn("glib-compile-schemas failed (non-fatal)")
    end
  end

  return owned
end

return commit
