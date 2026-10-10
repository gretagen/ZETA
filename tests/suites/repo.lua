-- repo.lua suite -- remote repository access: index fetching (including the
-- optional `origin` field), search, the url -> repository label mapper, and
-- the manifest-based origin fallback used by -Localize.

local lib = require("lib")
local repo = require("repo")
local config = require("config")
local path = require("path")
local suite = lib.new_suite("repo")

local SHA = string.rep("a", 64)

-- Point config at a fresh scratch root whose repo is `repo_dir`.
local function use_repo(repo_dir)
  local root = lib.tmpdir("repo-root")
  config.reset()
  config.setenv("ZETA_ROOT", root)
  config.setenv("ZETA_STATE", path.join(root, "var/db/zeta"))
  config.setenv("ZETA_CACHE", path.join(root, "var/cache/zeta"))
  config.setenv("ZETA_TMP", path.join(root, "var/tmp/zeta"))
  config.setenv("ZETA_REPO", repo_dir)
  return root
end

local function write(p, content)
  os.execute("mkdir -p " .. path.quote(path.dirname(p)))
  lib.write(p, content)
end

-- ---------------------------------------------------------------------------
-- origin_from_url
-- ---------------------------------------------------------------------------

suite:test("origin_from_url maps gretagen artifact repos", function()
  lib.assert_eq(repo.origin_from_url(
    "https://raw.githubusercontent.com/gretagen/zeta-constructs/refs/heads/main/packages/bash/bash-5.3.tar.gz"),
    "constructs")
  lib.assert_eq(repo.origin_from_url(
    "https://raw.githubusercontent.com/gretagen/zeta-providence/refs/heads/main/steam/steam.pkg.tar.zst"),
    "providence")
  lib.assert_eq(repo.origin_from_url(
    "https://raw.githubusercontent.com/gretagen/zeta-nemesis/refs/heads/main/foo/foo.pkg.tar.zst"),
    "nemesis")
end)

suite:test("origin_from_url handles releases and non-github hosts", function()
  lib.assert_eq(repo.origin_from_url(
    "https://github.com/gretagen/zeta-providence/releases/download/large-artifacts/nvidia-utils.tar.gz"),
    "providence")
  -- spectoria hosts a zeta-* path segment, not an org repo
  lib.assert_eq(repo.origin_from_url(
    "https://files.spectoria.dev/zeta-monsters/rust-1.98.0.tar.gz"),
    "monsters")
  -- a direct upstream GitHub release is not a gretagen artifact
  lib.assert_eq(repo.origin_from_url(
    "https://github.com/mstorsjo/llvm-mingw/releases/download/20260616/x.tar.xz"),
    "upstream")
end)

suite:test("origin_from_url labels gretagen repos that lack a zeta- prefix", function()
  lib.assert_eq(repo.origin_from_url(
    "https://raw.githubusercontent.com/gretagen/declarative-plugins/refs/heads/main/packages/nix-declarative-helper/nix-declarative-helper-1.3.tar.gz"),
    "declarative-plugins")
  lib.assert_eq(repo.origin_from_url(
    "https://github.com/gretagen/declarative-plugins/releases/download/v1/x.tar.gz"),
    "declarative-plugins")
  lib.assert_eq(repo.origin_from_url(
    "https://raw.githubusercontent.com/gretagen/some-new-repo/x.tar.gz"),
    "some-new-repo")
end)

suite:test("origin_from_url falls back for meta, local and unknown hosts", function()
  lib.assert_eq(repo.origin_from_url(nil), "meta")
  lib.assert_eq(repo.origin_from_url(""), "meta")
  lib.assert_eq(repo.origin_from_url("file:///tmp/pkg/hello.tar.gz"), "local")
  lib.assert_eq(repo.origin_from_url("/var/cache/local.tar.gz"), "local")
  lib.assert_eq(repo.origin_from_url("https://example.org/dl/x.tar.gz"), "example.org")
end)

-- ---------------------------------------------------------------------------
-- fetch_index + search
-- ---------------------------------------------------------------------------

suite:test("fetch_index parses the optional origin field", function()
  local dir = lib.tmpdir("repo-idx")
  use_repo(dir)
  write(path.join(dir, "packages/index.lua"), [[
return {
  { name = "alpha", version = "1.0", summary = "a", origin = "providence" },
  { name = "beta", version = "2.0", summary = "b" },
}
]])
  local list, err = repo.fetch_index()
  lib.assert_true(list, err)
  lib.assert_eq(list[1].name, "alpha")
  lib.assert_eq(list[1].origin, "providence")
  lib.assert_eq(list[2].name, "beta")
  lib.assert_nil(list[2].origin, "missing origin stays nil")
end)

suite:test("search carries origin into matches", function()
  local dir = lib.tmpdir("repo-idx2")
  use_repo(dir)
  write(path.join(dir, "packages/index.lua"), [[
return {
  { name = "alpha", version = "1.0", summary = "needs nothing", origin = "deliverance" },
  { name = "beta", version = "2.0", summary = "alpha helper" },
}
]])
  local matches, err = repo.search("alpha")
  lib.assert_true(matches, err)
  lib.assert_eq(#matches, 2)
  lib.assert_eq(matches[1].name, "alpha")
  lib.assert_eq(matches[1].origin, "deliverance")
  lib.assert_eq(matches[2].name, "beta")
  lib.assert_nil(matches[2].origin)
end)

-- ---------------------------------------------------------------------------
-- origins (manifest fallback)
-- ---------------------------------------------------------------------------

suite:test("origins derives labels from each manifest url", function()
  local dir = lib.tmpdir("repo-origins")
  use_repo(dir)
  write(path.join(dir, "packages/alpha/package.lua"), ([[
return { name = "alpha", version = "1.0", summary = "a",
  url = "https://raw.githubusercontent.com/gretagen/zeta-providence/refs/heads/main/alpha/a.tar.gz",
  sha256 = "%s", deps = {}, archive = { strip = 1 } }
]]):format(SHA))
  write(path.join(dir, "packages/beta/package.lua"), ([[
return { name = "beta", version = "1.0", summary = "b",
  url = "https://files.spectoria.dev/zeta-monsters/beta.tar.gz",
  sha256 = "%s", deps = {}, archive = { strip = 1 } }
]]):format(SHA))
  write(path.join(dir, "packages/delta/package.lua"), ([[
return { name = "delta", version = "1.0", summary = "d",
  url = "https://raw.githubusercontent.com/gretagen/declarative-plugins/refs/heads/main/packages/delta/delta.tar.gz",
  sha256 = "%s", deps = {}, archive = { strip = 1 } }
]]):format(SHA))
  -- metapackage: no url
  write(path.join(dir, "packages/meta1/package.lua"),
    [[return { name = "meta1", version = "1.0", summary = "m", install = function() end }]])

  local map = repo.origins({ "alpha", "beta", "delta", "meta1", "missing" })
  lib.assert_eq(map.alpha, "providence")
  lib.assert_eq(map.beta, "monsters")
  lib.assert_eq(map.delta, "declarative-plugins")
  lib.assert_eq(map.meta1, "meta")
  lib.assert_eq(map.missing, "unknown", "unfetchable manifest falls back to unknown")
end)

suite:test("origins ignores invalid names and dedupes", function()
  local dir = lib.tmpdir("repo-origins2")
  use_repo(dir)
  write(path.join(dir, "packages/alpha/package.lua"), ([[
return { name = "alpha", version = "1.0", summary = "a",
  url = "https://raw.githubusercontent.com/gretagen/zeta-nemesis/x.tar.zst",
  sha256 = "%s", deps = {}, archive = { strip = 1 } }
]]):format(SHA))
  local map = repo.origins({ "alpha", "alpha", "../evil", "" })
  lib.assert_eq(map.alpha, "nemesis")
  lib.assert_nil(map["../evil"], "invalid names are dropped")
end)


-- ---------------------------------------------------------------------------
-- multi-repository resolution
-- ---------------------------------------------------------------------------
-- Build a repository tree: <root>/packages/<name>/package.lua (+ index.lua).
local function make_repo(prefix, pkgs, index)
  local root = lib.tmpdir(prefix)
  for name, manifest in pairs(pkgs) do
    local dir = path.join(root, "packages", name)
    os.execute("mkdir -p " .. path.quote(dir))
    lib.write(path.join(dir, "package.lua"), manifest)
  end
  if index then
    lib.write(path.join(root, "packages", "index.lua"), index)
  end
  return root
end

local function entry(name, version, summary)
  return ("return { name=%q, version=%q, url=\"https://example.invalid/%s-%s.tar.gz\", "
    .. "sha256=\"%s\", deps={}, archive={strip=1} }\n")
    :format(name, version, name, version, string.rep("0", 64))
end

-- REPO1 is consulted first and shadows REPO2 on the shared name.
local REPO1 = make_repo("repo-one", {
  alpha = entry("alpha", "1.0"),
  shared = entry("shared", "1.0"),
}, "return { {name='alpha',version='1.0',summary='from repo 1'}, "
  .. "{name='shared',version='1.0',summary='from repo 1'} }\n")

local REPO2 = make_repo("repo-two", {
  beta = entry("beta", "2.0"),
  shared = entry("shared", "9.9"),
}, "return { {name='beta',version='2.0',summary='from repo 2'}, "
  .. "{name='shared',version='9.9',summary='from repo 2'} }\n")

-- Point the client at the two repositories and reset cached config.
local function use_repos(...)
  config.reset()
  config.setenv("ZETA_ROOT", lib.tmpdir("repo-root"))
  config.setenv("ZETA_STATE", lib.tmpdir("repo-state"))
  config.setenv("ZETA_CACHE", lib.tmpdir("repo-cache"))
  config.setenv("ZETA_TMP", lib.tmpdir("repo-tmp"))
  local repos = {}
  for _, r in ipairs({ ... }) do repos[#repos + 1] = r end
  config.setenv("ZETA_REPOS", table.concat(repos, " "))
  return repos
end

suite:test("fetch_manifest finds a package in the first repository", function()
  use_repos(REPO1, REPO2)
  local m = repo.fetch_manifest("alpha")
  lib.assert_true(m ~= nil)
  lib.assert_eq(m.version, "1.0")
end)

suite:test("fetch_manifest falls through to a later repository", function()
  use_repos(REPO1, REPO2)
  local m = repo.fetch_manifest("beta")
  lib.assert_true(m ~= nil, "beta should resolve from the second repository")
  lib.assert_eq(m.version, "2.0")
end)

suite:test("an earlier repository shadows a later one", function()
  use_repos(REPO1, REPO2)
  local m = repo.fetch_manifest("shared")
  lib.assert_eq(m.version, "1.0")
end)

suite:test("fetch_manifest reports when no repository has the package", function()
  use_repos(REPO1, REPO2)
  local m, err = repo.fetch_manifest("ghost")
  lib.assert_nil(m)
  lib.assert_contains(err, "configured repositories")
end)

suite:test("fetch_index merges the indexes of every repository", function()
  use_repos(REPO1, REPO2)
  local list = repo.fetch_index()
  lib.assert_true(list ~= nil)
  local versions = {}
  for _, e in ipairs(list) do versions[e.name] = e.version end
  lib.assert_eq(versions.alpha, "1.0")
  lib.assert_eq(versions.beta, "2.0")
end)

suite:test("fetch_index keeps the first repository's entry for a shared name", function()
  use_repos(REPO1, REPO2)
  local list = repo.fetch_index()
  local found
  for _, e in ipairs(list) do
    if e.name == "shared" then found = e break end
  end
  lib.assert_true(found ~= nil, "shared missing from merged index")
  lib.assert_eq(found.version, "1.0")
  lib.assert_eq(found.summary, "from repo 1")
end)

suite:test("search spans every repository", function()
  use_repos(REPO1, REPO2)
  local matches = repo.search("beta")
  lib.assert_eq(#matches, 1)
  lib.assert_eq(matches[1].name, "beta")
end)

suite:test("a single ZETA_REPO still resolves (back-compat)", function()
  config.reset()
  config.setenv("ZETA_ROOT", lib.tmpdir("repo-root"))
  config.setenv("ZETA_STATE", lib.tmpdir("repo-state"))
  config.setenv("ZETA_CACHE", lib.tmpdir("repo-cache"))
  config.setenv("ZETA_TMP", lib.tmpdir("repo-tmp"))
  config.setenv("ZETA_REPO", REPO2)
  local m = repo.fetch_manifest("beta")
  lib.assert_true(m ~= nil)
  lib.assert_eq(m.version, "2.0")
  local missing = repo.fetch_manifest("alpha")
  lib.assert_nil(missing)
end)

return suite
