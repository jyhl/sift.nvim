local git = require('sift.git')

local M = {}

local function buffer_repo_root()
  local ok, value = pcall(vim.api.nvim_buf_get_var, 0, 'sift_session_repo_root')

  if ok and type(value) == 'string' and value ~= '' then
    return value
  end

  return nil
end

local function current_start_dir()
  local panel_root = buffer_repo_root()

  if panel_root then
    return panel_root
  end

  local name = vim.api.nvim_buf_get_name(0)

  if name ~= '' then
    return vim.fs.dirname(name)
  end

  return vim.loop.cwd()
end

function M.current_root(callback)
  local start_dir = current_start_dir()

  git.find_toplevel(start_dir, function(err, root)
    if err then
      callback(err)
      return
    end

    callback(nil, root)
  end)
end

return M
