local util = require('sift.util')

local M = {
  ref_prefix = 'refs/sift/',
}

local function missing_ref(stderr_text)
  local text = util.trim(stderr_text or '')

  return text:find('reference is missing', 1, true) ~= nil
    or text:find('cannot lock ref', 1, true) ~= nil
    or text:find('unable to resolve reference', 1, true) ~= nil
end

local function result_from_lines(code, stdout, stderr)
  return {
    code = code,
    stdout = stdout,
    stderr = stderr,
    stdout_text = table.concat(stdout, '\n'),
    stderr_text = table.concat(stderr, '\n'),
  }
end

function M.run(repo_root, args, opts, callback)
  if type(opts) == 'function' then
    callback = opts
    opts = {}
  end

  opts = opts or {}

  local stdout = {}
  local stderr = {}
  local cmd = { 'git' }

  vim.list_extend(cmd, args)

  local job_id, err = util.jobstart({
    cmd = cmd,
    cwd = repo_root,
    on_stdout_line = function(line)
      if line ~= '' or opts.keep_empty_stdout then
        table.insert(stdout, line)
      end
    end,
    on_stderr_line = function(line)
      if line ~= '' or opts.keep_empty_stderr then
        table.insert(stderr, line)
      end
    end,
    on_exit = function(code)
      callback(nil, result_from_lines(code, stdout, stderr))
    end,
  })

  if not job_id then
    util.schedule(callback, err)
  end
end

function M.find_toplevel(start_dir, callback)
  M.run(start_dir, { 'rev-parse', '--show-toplevel' }, function(err, result)
    if err then
      callback(err)
      return
    end

    if result.code ~= 0 then
      callback(util.trim(result.stderr_text) ~= '' and util.trim(result.stderr_text) or 'not inside a git repository')
      return
    end

    callback(nil, util.trim(result.stdout[1]))
  end)
end

function M.create_baseline(repo_root, session_id, callback)
  local ref_name = M.ref_prefix .. session_id

  M.run(repo_root, { 'stash', 'create' }, function(err, stash_result)
    if err then
      callback(err)
      return
    end

    if stash_result.code ~= 0 then
      callback(util.trim(stash_result.stderr_text) ~= '' and util.trim(stash_result.stderr_text) or 'git stash create failed')
      return
    end

    local commit = util.trim(stash_result.stdout[1])

    local function update_ref(resolved_commit)
      M.run(repo_root, { 'update-ref', ref_name, resolved_commit }, function(update_err, update_result)
        if update_err then
          callback(update_err)
          return
        end

        if update_result.code ~= 0 then
          callback(
            util.trim(update_result.stderr_text) ~= ''
                and util.trim(update_result.stderr_text)
              or 'git update-ref failed'
          )
          return
        end

        callback(nil, {
          ref = ref_name,
          commit = resolved_commit,
        })
      end)
    end

    if commit ~= '' then
      update_ref(commit)
      return
    end

    M.run(repo_root, { 'rev-parse', 'HEAD' }, function(head_err, head_result)
      if head_err then
        callback(head_err)
        return
      end

      if head_result.code ~= 0 then
        callback('unable to resolve a baseline commit; repository may not have a HEAD commit yet')
        return
      end

      update_ref(util.trim(head_result.stdout[1]))
    end)
  end)
end

function M.delete_ref(repo_root, ref_name, callback)
  M.run(repo_root, { 'rev-parse', '--verify', '--quiet', ref_name }, function(err, result)
    if err then
      callback(err)
      return
    end

    if result.code ~= 0 then
      callback(nil)
      return
    end

    M.run(repo_root, { 'update-ref', '-d', ref_name }, function(delete_err, delete_result)
      if delete_err then
        callback(delete_err)
        return
      end

      if delete_result.code ~= 0 and not missing_ref(delete_result.stderr_text) then
        callback(util.trim(delete_result.stderr_text) ~= '' and util.trim(delete_result.stderr_text) or 'git update-ref -d failed')
        return
      end

      callback(nil)
    end)
  end)
end

function M.diff_against(repo_root, base_ref, callback)
  M.run(repo_root, {
    'diff',
    '--no-color',
    '--no-ext-diff',
    '--find-renames',
    '--unified=3',
    base_ref,
    '--',
  }, function(err, result)
    if err then
      callback(err)
      return
    end

    if result.code ~= 0 then
      callback(util.trim(result.stderr_text) ~= '' and util.trim(result.stderr_text) or 'git diff failed')
      return
    end

    callback(nil, result.stdout)
  end)
end

function M.tracked_files(repo_root, callback)
  M.run(repo_root, { 'ls-files' }, function(err, result)
    if err then
      callback(err)
      return
    end

    if result.code ~= 0 then
      callback(util.trim(result.stderr_text) ~= '' and util.trim(result.stderr_text) or 'git ls-files failed')
      return
    end

    callback(nil, result.stdout)
  end)
end

function M.tracked_files_sync(repo_root)
  local output = vim.fn.system({
    'git',
    '-C',
    repo_root,
    'ls-files',
  })

  if vim.v.shell_error ~= 0 then
    return nil, util.trim(output) ~= '' and util.trim(output) or 'git ls-files failed'
  end

  if output == '' then
    return {}
  end

  return vim.split(output, '\n', { plain = true, trimempty = true })
end

function M.delete_ref_sync(repo_root, ref_name)
  vim.fn.system({
    'git',
    '-C',
    repo_root,
    'rev-parse',
    '--verify',
    '--quiet',
    ref_name,
  })

  if vim.v.shell_error ~= 0 then
    return nil
  end

  local output = vim.fn.system({
    'git',
    '-C',
    repo_root,
    'update-ref',
    '-d',
    ref_name,
  })

  if vim.v.shell_error ~= 0 and not missing_ref(output) then
    return util.trim(output) ~= '' and util.trim(output) or 'git update-ref -d failed'
  end

  return nil
end

function M.restore_files(repo_root, base_ref, files, callback)
  if not files or vim.tbl_isempty(files) then
    util.schedule(callback, nil)
    return
  end

  local args = {
    'restore',
    '--source=' .. base_ref,
    '--worktree',
    '--',
  }

  vim.list_extend(args, files)

  M.run(repo_root, args, function(err, result)
    if err then
      callback(err)
      return
    end

    if result.code ~= 0 then
      callback(util.trim(result.stderr_text) ~= '' and util.trim(result.stderr_text) or 'git restore failed')
      return
    end

    callback(nil)
  end)
end

return M
