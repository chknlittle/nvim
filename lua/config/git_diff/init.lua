local M = {}

local uv = vim.loop
local util = require("config.git_diff.util")
local git = require("config.git_diff.git")
local tree = require("config.git_diff.tree")
local ui = require("config.git_diff.ui")
local watcher = require("config.git_diff.watcher")

local REFRESH_THROTTLE_MS = 500

--------------------------------------------------------------------------------
-- State (initialized per panel instance)
--------------------------------------------------------------------------------
local function create_state()
  return {
    panel_buf = nil,
    diff_buf = nil,
    tree_buf = nil,
    diff_win = nil,

    row_to_info = {},
    path_to_entry = {},
    collapsed_repos = {},
    current_line_mapping = {},

    resolved_path = nil,
    last_selected_mtime = 0,

    last_refresh = 0,
    last_repo_scan = 0,
    cached_repos = nil,

    project_root = vim.fn.getcwd(),

    watcher = nil,
  }
end

--------------------------------------------------------------------------------
-- Panel Refresh (Git Data + UI Update)
--------------------------------------------------------------------------------
local function refresh_panel(state)
  local now = uv.now()
  if now - state.last_refresh < REFRESH_THROTTLE_MS then return end
  state.last_refresh = now

  if not (vim.api.nvim_buf_is_valid(state.panel_buf) and vim.api.nvim_buf_is_loaded(state.panel_buf)) then
    return
  end

  local lines = {}
  state.row_to_info = {}
  state.path_to_entry = {}

  local repos = git.ensure_repos(state, false)
  table.sort(repos)
  local header_rows = {}

  for _, repo_root in ipairs(repos) do
    local repo_rel = util.rel_to(state.project_root, repo_root)
    if repo_rel == "." then repo_rel = "" end

    local repo_tree = {}

    -- Modified files
    local numstat = git.systemlist(repo_root, "diff HEAD --numstat -M")
    for _, line in ipairs(numstat) do
      local added, removed, file_str = line:match("([-%d]+)\t([-%d]+)\t(.-)$")
      if added and file_str then
        local pre, old_mid, new_mid, post = file_str:match("^(.-){(.-) %=> (.-)}(.-)$")
        local is_rename = pre ~= nil
        local old_rel, new_rel
        if is_rename then
          old_rel = (pre or "") .. (old_mid or "") .. (post or "")
          new_rel = (pre or "") .. (new_mid or "") .. (post or "")
        end
        local repo_rel_file = is_rename and new_rel or file_str
        local display = is_rename and (old_rel .. " => " .. new_rel) or nil

        local entry
        if added == "-" then
          entry = { type = "binary", is_untracked = false }
        else
          entry = { type = "file", added = tonumber(added), removed = tonumber(removed), is_untracked = false }
        end
        entry.display = display
        entry.repo_root = repo_root
        entry.repo_relpath = repo_rel_file
        entry.abs_path = util.path_join(repo_root, repo_rel_file)

        tree.insert(repo_tree, util.split_path_components(repo_rel_file), entry)
      end
    end

    -- Untracked files
    local untracked = git.systemlist(repo_root, "ls-files --others --exclude-standard")
    for _, f in ipairs(untracked) do
      if f ~= "" then
        local abs_path = util.path_join(repo_root, f)
        local st = uv.fs_stat(abs_path)
        if not st or st.type ~= "file" then
          goto continue
        end
        local entry

        local fh = io.open(abs_path, "r")
        if fh then
          local content = fh:read(512)
          fh:close()
          local is_binary = content and content:find("\0") ~= nil
          if is_binary then
            entry = { type = "binary", is_untracked = true }
          else
            local line_count = git.count_lines(abs_path)
            entry = { type = "file", added = line_count, removed = 0, is_untracked = true }
          end
        else
          entry = { type = "binary", is_untracked = true }
        end
        entry.repo_root = repo_root
        entry.repo_relpath = f
        entry.abs_path = abs_path

        tree.insert(repo_tree, util.split_path_components(f), entry)
      end
      ::continue::
    end

    if next(repo_tree) ~= nil then
      local header_label = (repo_rel ~= "" and repo_rel or ".")
      local is_collapsed = state.collapsed_repos[repo_root] == true
      local header_text = "repo: " .. header_label .. (is_collapsed and " (collapsed)" or "")
      table.insert(lines, header_text)
      table.insert(header_rows, #lines)
      state.row_to_info[#lines] = { kind = "repo_header", repo_key = repo_root }
      if not is_collapsed then
        tree.build_display_lines(repo_tree, "  ", repo_rel, "", lines, state)
      end
      table.insert(lines, "")
    end
  end

  if not vim.api.nvim_buf_is_valid(state.panel_buf) then return end
  vim.api.nvim_buf_set_lines(state.panel_buf, 0, -1, false, lines)

  for _, row in ipairs(header_rows) do
    vim.api.nvim_buf_add_highlight(state.panel_buf, ui.highlight_ns, "GitRepoHeader", row - 1, 0, -1)
  end
end

--------------------------------------------------------------------------------
-- Diff Loading
--------------------------------------------------------------------------------
local function update_diff_silent(state, path, entry)
  if not path or not entry then return end
  if not vim.api.nvim_buf_is_valid(state.diff_buf) then return end

  state.resolved_path = path

  local diff_output, override_ft = git.get_diff_content(state, path, entry)
  local _, _, line_mapping = ui.render_diff_buffer(state.diff_buf, diff_output, { filetype = override_ft, path = path })
  state.current_line_mapping = line_mapping or {}
end

local function load_diff_for_path(state, path, entry, tree_api)
  if not path or not entry then return end

  state.resolved_path = path

  if vim.api.nvim_win_is_valid(state.diff_win) then
    vim.api.nvim_set_current_win(state.diff_win)
  else
    vim.cmd("wincmd l")
  end

  if not vim.api.nvim_buf_is_valid(state.diff_buf) then
    vim.cmd("enew")
    state.diff_buf = vim.api.nvim_get_current_buf()
    vim.opt_local.buftype = "nofile"
    vim.opt_local.bufhidden = "hide"
    vim.opt_local.swapfile = false
    vim.opt_local.wrap = false
    vim.opt_local.signcolumn = "no"
  end

  if vim.api.nvim_get_current_buf() ~= state.diff_buf then
    vim.api.nvim_win_set_buf(0, state.diff_buf)
  end

  local diff_output, override_ft = git.get_diff_content(state, path, entry)
  local _, _, line_mapping = ui.render_diff_buffer(state.diff_buf, diff_output, { filetype = override_ft, path = path })
  state.current_line_mapping = line_mapping or {}

  if entry.abs_path and tree_api then
    local tree_win = vim.fn.bufwinid(state.tree_buf)
    if tree_win ~= -1 and vim.api.nvim_win_is_valid(tree_win) then
      local prev_win = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(tree_win)
      pcall(tree_api.tree.find_file, { path = entry.abs_path, focus = false, open = false })
      if vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(prev_win)
      end
    end
  end
end

local function pick_latest_changed_with_mtime(state)
  local best_path, best_m = nil, 0
  for p, _ in pairs(state.path_to_entry) do
    local mt = util.get_mtime(p)
    if mt > best_m then
      best_m = mt
      best_path = p
    end
  end
  return best_path, best_m
end

local function focus_row_for_path(state, path)
  if not path then return end
  local winid = vim.fn.bufwinid(state.panel_buf)
  if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
    for row, info in pairs(state.row_to_info) do
      if info.path == path then
        vim.api.nvim_win_set_cursor(winid, { row, 0 })
        break
      end
    end
  end
end

local function load_initial_diff(state, tree_api)
  local target_path, mt = pick_latest_changed_with_mtime(state)
  if target_path and state.path_to_entry[target_path] then
    load_diff_for_path(state, target_path, state.path_to_entry[target_path], tree_api)
    focus_row_for_path(state, target_path)
    state.last_selected_mtime = mt or 0
  else
    for i = 1, vim.api.nvim_buf_line_count(state.panel_buf) do
      local info = state.row_to_info[i]
      if info and info.entry then
        load_diff_for_path(state, info.path, info.entry, tree_api)
        focus_row_for_path(state, info.path)
        state.last_selected_mtime = util.get_mtime(info.path)
        return
      end
    end
    ui.render_diff_buffer(state.diff_buf, {}, {})
    state.resolved_path = nil
    state.last_selected_mtime = 0
  end
end

--------------------------------------------------------------------------------
-- File Change Handler
--------------------------------------------------------------------------------
local function on_file_change(state, tree_api)
  if not vim.api.nvim_buf_is_valid(state.panel_buf) then return end

  git.ensure_repos(state, false)
  refresh_panel(state)

  local p, mt = pick_latest_changed_with_mtime(state)
  if p and state.path_to_entry[p] then
    if mt > state.last_selected_mtime or p ~= state.resolved_path then
      update_diff_silent(state, p, state.path_to_entry[p])
      focus_row_for_path(state, p)
      state.last_selected_mtime = mt
    end
  else
    if vim.api.nvim_buf_is_valid(state.diff_buf) then
      ui.render_diff_buffer(state.diff_buf, {}, {})
      state.resolved_path = nil
      state.last_selected_mtime = 0
    end
  end
end

--------------------------------------------------------------------------------
-- Keymaps
--------------------------------------------------------------------------------
local function setup_keymaps(state, tree_api)
  local function load_file_diff(use_mouse_pos)
    if not (vim.api.nvim_buf_is_valid(state.panel_buf) and vim.api.nvim_buf_is_loaded(state.panel_buf)) then
      return
    end

    local row
    if use_mouse_pos then
      local mouse = vim.fn.getmousepos()
      if vim.api.nvim_win_get_buf(mouse.winid) == state.panel_buf then
        vim.api.nvim_set_current_win(mouse.winid)
        ui.safe_win_set_cursor(mouse.winid, mouse.line, mouse.column - 1)
      end
      row = mouse.line
    else
      local cursor = vim.api.nvim_win_get_cursor(0)
      row = cursor[1]
    end

    local info = state.row_to_info[row]
    if info and info.entry then
      load_diff_for_path(state, info.path, info.entry, tree_api)
    end
  end

  local function close_all()
    if vim.api.nvim_buf_is_valid(state.panel_buf) then vim.api.nvim_buf_delete(state.panel_buf, { force = true }) end
    if vim.api.nvim_buf_is_valid(state.diff_buf) then vim.api.nvim_buf_delete(state.diff_buf, { force = true }) end
    if vim.api.nvim_buf_is_valid(state.tree_buf) then vim.api.nvim_buf_delete(state.tree_buf, { force = true }) end
  end

  local function tree_open_node(use_mouse)
    if use_mouse then
      local mouse = vim.fn.getmousepos()
      if vim.api.nvim_win_get_buf(mouse.winid) == state.tree_buf then
        vim.api.nvim_set_current_win(mouse.winid)
        ui.safe_win_set_cursor(mouse.winid, mouse.line, mouse.column - 1)
      end
    end
    local node = tree_api.tree.get_node_under_cursor()
    if node then
      if node.type == "directory" then
        tree_api.node.open.edit(node)
      elseif node.type == "file" then
        vim.api.nvim_set_current_win(state.diff_win)
        vim.cmd("edit " .. vim.fn.fnameescape(node.absolute_path))
      end
    end
  end

  -- Panel keymaps
  vim.keymap.set("n", "<CR>", function() load_file_diff(false) end, { buffer = state.panel_buf, silent = true })
  vim.keymap.set("n", "<LeftMouse>", function() load_file_diff(true) end, { buffer = state.panel_buf, silent = true })
  vim.keymap.set("n", "<2-LeftMouse>", function()
    local mouse = vim.fn.getmousepos()
    if vim.api.nvim_win_get_buf(mouse.winid) == state.panel_buf then
      local line = mouse.line
      local info = state.row_to_info[line]
      if info and info.kind == "repo_header" and info.repo_key then
        state.collapsed_repos[info.repo_key] = not state.collapsed_repos[info.repo_key]
        refresh_panel(state)
        return
      end
    end
    load_file_diff(true)
  end, { buffer = state.panel_buf, silent = true })
  vim.keymap.set("n", "q", close_all, { buffer = state.panel_buf, silent = true })

  -- Diff buffer keymaps
  vim.keymap.set("n", "q", close_all, { buffer = state.diff_buf, silent = true })
  vim.keymap.set("n", "go", function()
    if state.resolved_path then
      local cursor_line = vim.fn.line(".")
      local file_line = state.current_line_mapping[cursor_line]
      local info = state.row_to_info[vim.fn.line(".")]
      local abs_path = info and info.entry and info.entry.abs_path or util.path_join(state.project_root, state.resolved_path)
      if abs_path and util.is_file(abs_path) then
        vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
        if file_line then
          vim.api.nvim_win_set_cursor(0, { file_line, 0 })
        end
      end
    end
  end, { buffer = state.diff_buf, silent = true })

  -- Tree keymaps
  vim.keymap.set("n", "<CR>", function() tree_open_node(false) end, { buffer = state.tree_buf, silent = true })
  vim.keymap.set("n", "<2-LeftMouse>", function() tree_open_node(true) end, { buffer = state.tree_buf, silent = true })
  vim.keymap.set("n", "q", close_all, { buffer = state.tree_buf, silent = true })
end

--------------------------------------------------------------------------------
-- Main Entry Point
--------------------------------------------------------------------------------
function M.open()
  local tree_api = require("nvim-tree.api")
  local state = create_state()

  -- Create panel window (left side, top)
  vim.cmd("leftabove 30vnew")
  vim.cmd("below split")
  tree_api.tree.close()
  tree_api.tree.open({ current_window = true })
  state.tree_buf = vim.api.nvim_get_current_buf()
 
  -- Move to panel window
  vim.cmd("wincmd k")
  state.panel_buf = vim.api.nvim_get_current_buf()
  local panel_win = vim.fn.bufwinid(state.panel_buf)
  local tree_win = vim.fn.bufwinid(state.tree_buf)

  -- Set window heights (70% panel, 30% tree)
  if panel_win ~= -1 and tree_win ~= -1 then
    local col_h = vim.api.nvim_win_get_height(panel_win) + vim.api.nvim_win_get_height(tree_win)
    local tree_h = math.max(1, math.floor(col_h * 0.30))
    local panel_h = math.max(1, col_h - tree_h)
    vim.api.nvim_win_set_height(panel_win, panel_h)
  end

  ui.setup_panel_buffer(state.panel_buf)
  ui.setup_highlights()

  -- Create diff window (right side)
  vim.cmd("wincmd l")
  vim.cmd("enew")
  state.diff_buf = vim.api.nvim_get_current_buf()
  state.diff_win = vim.api.nvim_get_current_win()
  ui.setup_diff_buffer()

  vim.api.nvim_set_option_value("winhighlight", "CursorLine:CursorLine", { scope = "local", win = state.diff_win })

  -- Initial data load
  refresh_panel(state)
  load_initial_diff(state, tree_api)

  -- Setup keymaps
  setup_keymaps(state, tree_api)

  -- Setup file watcher
  watcher.setup(state, function()
    on_file_change(state, tree_api)
  end)

  -- Cleanup autocmds
  local group = vim.api.nvim_create_augroup("GitDiffWatcher", { clear = true })
  local function add_cleanup_autocmd(buf)
    vim.api.nvim_create_autocmd("BufUnload", {
      group = group,
      buffer = buf,
      callback = function() watcher.cleanup(state) end,
    })
  end
  add_cleanup_autocmd(state.panel_buf)
  add_cleanup_autocmd(state.diff_buf)
  add_cleanup_autocmd(state.tree_buf)

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    buffer = state.diff_buf,
    callback = function()
      state.row_to_info = {}
      state.path_to_entry = {}
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = state.panel_buf,
    callback = function()
      if vim.api.nvim_buf_is_valid(state.diff_buf) then
        vim.api.nvim_buf_delete(state.diff_buf, { force = true })
      end
    end,
  })
end

return M
