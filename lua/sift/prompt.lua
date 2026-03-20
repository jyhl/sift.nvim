local fs = require('sift.fs')
local git = require('sift.git')

local M = {}

local function unique(values)
  local seen = {}
  local ordered = {}

  for _, value in ipairs(values or {}) do
    if value ~= '' and not seen[value] then
      seen[value] = true
      table.insert(ordered, value)
    end
  end

  return ordered
end

local function tracked_files(session)
  if session.tracked_files_loaded then
    return session.tracked_files or {}, nil
  end

  local files, err = git.tracked_files_sync(session.repo_root)

  if not files then
    return nil, err
  end

  session.tracked_files = files
  session.tracked_files_loaded = true

  return files, nil
end

local function basename_matches(path, query)
  return vim.startswith(vim.fs.basename(path), query)
end

local function path_matches(path, query)
  return vim.startswith(path, query)
end

local function sorted_paths(paths)
  table.sort(paths, function(left, right)
    local left_name = vim.fs.basename(left)
    local right_name = vim.fs.basename(right)

    if left_name ~= right_name then
      return left_name < right_name
    end

    return left < right
  end)

  return paths
end

function M.extract_references(text)
  local refs = {}

  for ref in tostring(text or ''):gmatch('@([^%s]+)') do
    table.insert(refs, ref)
  end

  return unique(refs)
end

function M.complete_paths(session, query)
  local files, err = tracked_files(session)

  if not files then
    return nil, err
  end

  if query == nil then
    query = ''
  end

  local matches = {}

  for _, path in ipairs(files) do
    local include = false

    if query == '' then
      include = true
    elseif query:find('/', 1, true) then
      include = path_matches(path, query)
    else
      include = basename_matches(path, query) or path_matches(path, query)
    end

    if include then
      table.insert(matches, path)
    end
  end

  return sorted_paths(matches), nil
end

function M.resolve_reference(session, ref)
  local files, err = tracked_files(session)

  if not files then
    return nil, err
  end

  local exact = {}
  local basename_exact = {}
  local prefix = {}

  for _, path in ipairs(files) do
    if path == ref then
      table.insert(exact, path)
    end

    if vim.fs.basename(path) == ref then
      table.insert(basename_exact, path)
    end

    if ref ~= '' then
      local include = ref:find('/', 1, true) and path_matches(path, ref)
        or basename_matches(path, ref)
        or path_matches(path, ref)

      if include then
        table.insert(prefix, path)
      end
    end
  end

  if #exact == 1 then
    return exact[1], nil
  end

  if #basename_exact == 1 then
    return basename_exact[1], nil
  end

  if #prefix == 1 then
    return prefix[1], nil
  end

  if #exact > 1 or #basename_exact > 1 or #prefix > 1 then
    local candidates = #exact > 1 and exact or (#basename_exact > 1 and basename_exact or prefix)
    return nil, string.format('file reference @%s is ambiguous: %s', ref, table.concat(sorted_paths(candidates), ', '))
  end

  return nil, string.format('file reference @%s did not match a tracked file', ref)
end

function M.reference_fragment(line, col)
  local prefix = tostring(line or ''):sub(1, col)
  local fragment = prefix:match('@([^%s@]*)$')

  if not fragment then
    return nil
  end

  return {
    fragment = fragment,
    startcol = #prefix - #fragment,
  }
end

function M.expand(session, text)
  local refs = M.extract_references(text)

  if vim.tbl_isempty(refs) then
    return text, {}, nil
  end

  local resolved = {}

  for _, ref in ipairs(refs) do
    local path, err = M.resolve_reference(session, ref)

    if not path then
      return nil, nil, err
    end

    table.insert(resolved, path)
  end

  resolved = unique(resolved)

  local lines = {
    tostring(text or ''),
    '',
    'Referenced project files:',
  }

  for _, path in ipairs(resolved) do
    local absolute_path = fs.normalize(session.repo_root .. '/' .. path)
    local ok, file_lines = pcall(vim.fn.readfile, absolute_path)

    if not ok then
      return nil, nil, string.format('failed to read referenced file %s', path)
    end

    table.insert(lines, string.format('--- FILE: %s ---', path))
    vim.list_extend(lines, file_lines)
    table.insert(lines, string.format('--- END FILE: %s ---', path))
    table.insert(lines, '')
  end

  return table.concat(lines, '\n'), resolved, nil
end

return M
