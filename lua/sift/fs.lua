local M = {}

function M.exists(path)
  return vim.loop.fs_stat(path) ~= nil
end

function M.is_dir(path)
  local stat = vim.loop.fs_stat(path)
  return stat ~= nil and stat.type == 'directory'
end

function M.normalize(path)
  return vim.fs.normalize(path)
end

function M.realpath(path)
  return vim.loop.fs_realpath(path) or M.normalize(path)
end

return M
