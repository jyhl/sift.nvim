local git = require('sift.git')
local fs = require('sift.fs')
local tracker = require('sift.review.tracker')

local M = {}

local function relative_path(session, bufnr)
  return tracker.current_relative_path(session, bufnr)
end

local function write_buffer(bufnr)
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd('silent noautocmd write')
  end)

  if not ok then
    return nil, err
  end

  return true
end

local function reload_matching_buffers(session, target_paths)
  local wanted = {}

  for _, path in ipairs(target_paths or {}) do
    wanted[path] = true
  end

  local prefix = fs.realpath(session.repo_root) .. '/'

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)

      if name ~= '' and vim.startswith(fs.realpath(name), prefix) then
        local relpath = fs.realpath(name):sub(#prefix + 1)

        if wanted[relpath] then
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd('silent edit!')
          end)
        end
      end
    end
  end
end

function M.hunk(session, bufnr, lnum)
  local hunk = tracker.current_hunk(session, bufnr, lnum)

  if not hunk then
    return nil, 'no pending hunk under cursor'
  end

  if vim.api.nvim_buf_get_name(bufnr) == '' then
    return nil, 'current buffer is not a tracked file'
  end

  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
    return nil, 'current buffer is not writable'
  end

  local start_idx = math.max(hunk.added.start - 1, 0)
  local end_idx = start_idx + hunk.added.count
  local original_lines = vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)
  local baseline_lines = {}

  for _, line in ipairs(hunk.lines or {}) do
    if not vim.startswith(line, '+') then
      table.insert(baseline_lines, line:sub(2))
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, start_idx, end_idx, false, baseline_lines)
  local ok, write_err = write_buffer(bufnr)

  if not ok then
    vim.api.nvim_buf_set_lines(bufnr, start_idx, start_idx + #baseline_lines, false, original_lines)
    return nil, write_err
  end

  return hunk
end

function M.file(session, relative_path, callback)
  tracker.clear_file_acceptance(session, relative_path)

  git.restore_files(session.repo_root, session.baseline_ref, { relative_path }, function(err)
    if err then
      callback(err)
      return
    end

    reload_matching_buffers(session, { relative_path })
    callback(nil)
  end)
end

function M.all(session, callback)
  local paths = tracker.pending_file_paths(session)

  if vim.tbl_isempty(paths) then
    callback(nil, {})
    return
  end

  for _, path in ipairs(paths) do
    tracker.clear_file_acceptance(session, path)
  end

  git.restore_files(session.repo_root, session.baseline_ref, paths, function(err)
    if err then
      callback(err)
      return
    end

    reload_matching_buffers(session, paths)
    callback(nil, paths)
  end)
end

function M.current_file(session, bufnr)
  local path = relative_path(session, bufnr)

  if not path then
    return nil, 'current buffer is not part of the active sift session'
  end

  return path
end

return M
