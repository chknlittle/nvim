local M = {}

local uv = vim.loop
local util = require("config.git_diff.util")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
M.MAX_SCAN_DEPTH = vim.g.git_multi_repo_max_depth or 3
M.REPO_RESCAN_INTERVAL_MS = vim.g.git_multi_repo_scan_interval_ms or 10000

local IGNORE_DIRS = {
  [".git"] = true,
  ["node_modules"] = true,
  [".venv"] = true,
  ["venv"] = true,
  [".direnv"] = true,
  [".next"] = true,
  [".cache"] = true,
  ["dist"] = true,
  ["build"] = true,
  ["target"] = true,
  ["out"] = true,
  [".turbo"] = true,
  [".yarn"] = true,
  [".pnpm-store"] = true,
  ["__pycache__"] = true,
}

--------------------------------------------------------------------------------
-- Git Command Execution
--------------------------------------------------------------------------------
function M.systemlist(repo_root, subcmd)
  local cmd = string.format("git -C %s --no-optional-locks %s", vim.fn.shellescape(repo_root), subcmd)
  return vim.fn.systemlist(cmd)
end

--------------------------------------------------------------------------------
-- Repo Discovery
--------------------------------------------------------------------------------
function M.discover_repos(root, max_depth)
  local repos = {}
  local seen = {}

  local function scan(dir, depth)
    if depth > max_depth then return end
    if seen[dir] then return end
    seen[dir] = true

    local is_repo = util.is_git_repo(dir)
    if is_repo then
      table.insert(repos, dir)
      if depth > 0 then return end
    end

    local req = uv.fs_scandir(dir)
    if not req then return end
    while true do
      local name, typ = uv.fs_scandir_next(req)
      if not name then break end
      if typ == "directory" and not IGNORE_DIRS[name] then
        scan(util.path_join(dir, name), depth + 1)
      end
    end
  end

  scan(root, 0)
  return repos
end

function M.ensure_repos(state, force)
  local now = uv.now()
  if force or not state.cached_repos or now - state.last_repo_scan > M.REPO_RESCAN_INTERVAL_MS then
    state.cached_repos = M.discover_repos(state.project_root, M.MAX_SCAN_DEPTH)
    state.last_repo_scan = now
  end
  return state.cached_repos or {}
end

--------------------------------------------------------------------------------
-- Diff Content Generation
--------------------------------------------------------------------------------
function M.get_diff_content(state, path, entry)
  local diff_output = {}
  local override_ft = util.resolve_filetype(path)

  if entry.type == "binary" then
    table.insert(diff_output, "Binary file differs")
  elseif entry.is_untracked then
    local file_lines = vim.fn.readfile(entry.abs_path)
    table.insert(diff_output, "diff --git a/" .. entry.repo_relpath .. " b/" .. entry.repo_relpath)
    table.insert(diff_output, "new file mode 100644")
    table.insert(diff_output, "--- /dev/null")
    table.insert(diff_output, "+++ b/" .. entry.repo_relpath)
    table.insert(diff_output, "@@ -0,0 +1," .. #file_lines .. " @@")
    for _, fline in ipairs(file_lines) do
      table.insert(diff_output, "+" .. fline)
    end
  else
    diff_output = M.systemlist(entry.repo_root, "diff HEAD -- " .. vim.fn.shellescape(entry.repo_relpath))
  end

  return diff_output, override_ft
end

--------------------------------------------------------------------------------
-- Status Helpers
--------------------------------------------------------------------------------
function M.get_all_repos_status(state)
  local repos = M.ensure_repos(state, false)
  local combined = {}
  for _, repo_root in ipairs(repos) do
    local cmd = string.format(
      "git -C %s --no-optional-locks status --porcelain 2>/dev/null",
      vim.fn.shellescape(repo_root)
    )
    local output = vim.fn.system(cmd)
    table.insert(combined, repo_root .. ":" .. output)
  end
  return table.concat(combined, "\n")
end

--- Count lines in a file using pure Lua (no shell-out).
function M.count_lines(path)
  local st = uv.fs_stat(path)
  if not st or st.type ~= "file" then return 0 end

  local fh = io.open(path, "r")
  if not fh then return 0 end

  local count = 0
  for _ in fh:lines() do
    count = count + 1
  end
  fh:close()

  return count
end

return M
