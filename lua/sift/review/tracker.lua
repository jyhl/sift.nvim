local M = {}

local fs = require('sift.fs')
local hunk_util = require('sift.diff.hunk')

local function absolute_path(repo_root, relative_path)
  return fs.normalize(repo_root .. '/' .. relative_path)
end

local function ensure_acceptance(session)
  session.accepted = session.accepted or {
    hunks = {},
    by_file = {},
  }

  return session.accepted
end

function M.current_relative_path(session, bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)

  if name == '' then
    return nil
  end

  local normalized = fs.realpath(name)
  local prefix = fs.realpath(session.repo_root) .. '/'

  if not vim.startswith(normalized, prefix) then
    return nil
  end

  return normalized:sub(#prefix + 1)
end

function M.hunk_signature(hunk)
  local parts = {
    hunk.path or '',
    hunk.header or '',
  }

  vim.list_extend(parts, hunk.lines or {})

  return table.concat(parts, '\n\0')
end

local function mark_accepted(session, hunk)
  local accepted = ensure_acceptance(session)
  local signature = hunk.signature or M.hunk_signature(hunk)
  local file_signatures = accepted.by_file[hunk.path] or {}

  accepted.hunks[signature] = true
  file_signatures[signature] = true
  accepted.by_file[hunk.path] = file_signatures
end

local function new_review()
  return {
    files = {},
    file_list = {},
    hunks = {},
    hunk_list = {},
    counts = {
      files = 0,
      hunks = 0,
    },
  }
end

function M.replace(session, files)
  local review = new_review()
  local accepted = ensure_acceptance(session)

  session.review_source = vim.deepcopy(files or {})

  for _, file in ipairs(session.review_source) do
    file.absolute_path = absolute_path(session.repo_root, file.path)

    if vim.loop.fs_stat(file.absolute_path) then
      local pending_file = nil

      for _, hunk in ipairs(file.hunks) do
        hunk.path = file.path
        hunk.absolute_path = file.absolute_path
        hunk.file = file
        hunk.signature = M.hunk_signature(hunk)

        if not accepted.hunks[hunk.signature] then
          if not pending_file then
            pending_file = vim.deepcopy(file)
            pending_file.hunks = {}
            review.files[file.path] = pending_file
            table.insert(review.file_list, pending_file)
          end

          hunk.id = string.format('%s:%d:%s', file.path, hunk.index, hunk.header)
          hunk.file = pending_file
          table.insert(pending_file.hunks, hunk)
          review.hunks[hunk.id] = hunk
          table.insert(review.hunk_list, hunk)
        end
      end
    end
  end

  table.sort(review.file_list, function(left, right)
    return left.path < right.path
  end)

  table.sort(review.hunk_list, hunk_util.compare)

  review.counts.files = #review.file_list
  review.counts.hunks = #review.hunk_list
  session.review = review

  return review
end

function M.rebuild(session)
  return M.replace(session, session.review_source or {})
end

function M.get(session)
  return session.review or M.replace(session, {})
end

function M.file_hunks(session, relative_path)
  local review = M.get(session)
  local file = review.files[relative_path]
  return file and file.hunks or {}
end

function M.find_at(session, relative_path, lnum)
  if not relative_path then
    return nil
  end

  for _, hunk in ipairs(M.file_hunks(session, relative_path)) do
    if hunk_util.contains_line(hunk, lnum) then
      return hunk
    end
  end

  return nil
end

function M.current_hunk(session, bufnr, lnum)
  return M.find_at(session, M.current_relative_path(session, bufnr), lnum)
end

function M.accept_hunk(session, hunk)
  if not hunk then
    return M.get(session)
  end

  mark_accepted(session, hunk)
  return M.rebuild(session)
end

function M.accept_file(session, relative_path)
  for _, hunk in ipairs(M.file_hunks(session, relative_path)) do
    mark_accepted(session, hunk)
  end

  return M.rebuild(session)
end

function M.accept_all(session)
  for _, hunk in ipairs(M.get(session).hunk_list) do
    mark_accepted(session, hunk)
  end

  return M.rebuild(session)
end

function M.pending_file_paths(session)
  local paths = {}

  for _, file in ipairs(M.get(session).file_list) do
    table.insert(paths, file.path)
  end

  return paths
end

function M.clear_file_acceptance(session, relative_path)
  local accepted = ensure_acceptance(session)
  local file_signatures = accepted.by_file[relative_path] or {}

  for signature in pairs(file_signatures) do
    accepted.hunks[signature] = nil
  end

  accepted.by_file[relative_path] = nil
end

function M.clear_all_acceptance(session)
  session.accepted = {
    hunks = {},
    by_file = {},
  }
end

function M.navigate(session, direction, bufnr, lnum)
  local review = M.get(session)

  if review.counts.hunks == 0 then
    return nil
  end

  local current_path = M.current_relative_path(session, bufnr)
  local wrap = vim.o.wrapscan

  if direction == 'next' then
    for _, hunk in ipairs(review.hunk_list) do
      if not current_path then
        return hunk
      end

      if hunk.path > current_path then
        return hunk
      end

      if hunk.path == current_path and hunk_util.anchor(hunk) > lnum then
        return hunk
      end
    end

    return wrap and review.hunk_list[1] or nil
  end

  for index = #review.hunk_list, 1, -1 do
    local hunk = review.hunk_list[index]

    if not current_path then
      return hunk
    end

    if hunk.path < current_path then
      return hunk
    end

    if hunk.path == current_path and hunk_util.finish(hunk) < lnum then
      return hunk
    end
  end

  return wrap and review.hunk_list[#review.hunk_list] or nil
end

return M
