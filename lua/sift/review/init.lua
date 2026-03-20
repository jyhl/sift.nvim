local M = {}

local accept = require('sift.review.accept')
local diff = require('sift.diff')
local fs = require('sift.fs')
local git = require('sift.git')
local hunk_util = require('sift.diff.hunk')
local log = require('sift.log')
local reject = require('sift.review.reject')
local state = require('sift.state')
local tracker = require('sift.review.tracker')
local ui_inline = require('sift.ui.inline')
local ui_panel = require('sift.ui.panel')
local ui_signs = require('sift.ui.signs')

local augroup = vim.api.nvim_create_augroup('SiftReview', { clear = true })
local setup_done = false
local warned_missing_gitsigns = false
local gitsigns_base_var = 'sift_gitsigns_base'
local clear_buffer

local function gitsigns()
  local ok, module = pcall(require, 'gitsigns')

  if ok then
    return module
  end

  if not warned_missing_gitsigns then
    warned_missing_gitsigns = true
    log.warn('gitsigns.nvim is not available; sift will keep plugin-owned review state but preview integration is disabled')
  end

  return nil
end

local function relative_path_for(session, bufnr)
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

local function open_buffers_for_repo(session)
  local buffers = {}
  local prefix = fs.realpath(session.repo_root) .. '/'

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)

      if name ~= '' and vim.startswith(fs.realpath(name), prefix) then
        table.insert(buffers, bufnr)
      end
    end
  end

  return buffers
end

local function session_for_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)

  if name == '' then
    return nil
  end

  local normalized = fs.realpath(name)

  for _, session in pairs(state.all_sessions()) do
    local prefix = fs.realpath(session.repo_root) .. '/'

    if vim.startswith(normalized, prefix) then
      return session
    end
  end

  return nil
end

local function apply_gitsigns_base(session, bufnr, base, callback)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    if callback then
      callback('invalid buffer')
    end

    return
  end

  local ok, current = pcall(vim.api.nvim_buf_get_var, bufnr, gitsigns_base_var)

  if ok and current == base then
    if callback then
      callback(nil)
    end

    return
  end

  local gs = gitsigns()

  if not gs then
    if callback then
      callback(nil)
    end

    return
  end

  if type(gs.change_base) ~= 'function' then
    if callback then
      callback(nil)
    end

    return
  end

  vim.api.nvim_buf_call(bufnr, function()
    gs.change_base(base, false, function(err)
      if err then
        log.debug(string.format('gitsigns change_base failed for %s: %s', vim.api.nvim_buf_get_name(bufnr), err))
      else
        if base == nil then
          pcall(vim.api.nvim_buf_del_var, bufnr, gitsigns_base_var)
        else
          pcall(vim.api.nvim_buf_set_var, bufnr, gitsigns_base_var, base)
        end
      end

      if callback then
        callback(err)
      end
    end)
  end)
end

local function render_buffer(session, bufnr)
  local relative_path = relative_path_for(session, bufnr)

  if not relative_path then
    clear_buffer(bufnr)
    return
  end

  local hunks = tracker.file_hunks(session, relative_path)
  ui_inline.render(bufnr, hunks)
  ui_signs.render(bufnr, hunks)
  apply_gitsigns_base(session, bufnr, session.baseline_ref)
end

local function render_all(session)
  for _, bufnr in ipairs(open_buffers_for_repo(session)) do
    render_buffer(session, bufnr)
  end
end

clear_buffer = function(bufnr)
  ui_inline.clear(bufnr)
  ui_signs.clear(bufnr)
  pcall(vim.api.nvim_buf_del_var, bufnr, gitsigns_base_var)
end

local function on_review_changed(session, message)
  local review = tracker.get(session)

  render_all(session)

  if message then
    ui_panel.append_entry(
      session,
      'system',
      string.format('%s (%d files, %d hunks pending)', message, review.counts.files, review.counts.hunks)
    )
  end

  return review
end

local function jump_to_hunk(session, hunk)
  if not hunk then
    local err = 'no pending hunks'
    log.info(err)
    return nil, err
  end

  local ok, edit_err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(hunk.absolute_path))

  if not ok then
    return nil, edit_err
  end

  vim.api.nvim_win_set_cursor(0, { hunk_util.anchor(hunk), 0 })
  vim.cmd('silent! foldopen!')
  render_buffer(session, vim.api.nvim_get_current_buf())
  apply_gitsigns_base(session, vim.api.nvim_get_current_buf(), session.baseline_ref, function()
    local gs = gitsigns()
    if gs and type(gs.preview_hunk_inline) == 'function' then
      gs.preview_hunk_inline()
    end
  end)

  return hunk
end

local function open_file(session, relative_path)
  local file = tracker.get(session).files[relative_path]

  if not file then
    return nil, 'no pending review file at cursor'
  end

  local ok, edit_err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(file.absolute_path))

  if not ok then
    return nil, edit_err
  end

  render_buffer(session, vim.api.nvim_get_current_buf())
  apply_gitsigns_base(session, vim.api.nvim_get_current_buf(), session.baseline_ref)

  return file
end

function M.setup()
  if setup_done then
    return
  end

  setup_done = true

  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter', 'BufReadPost' }, {
    group = augroup,
    callback = function(args)
      local session = session_for_buffer(args.buf)
      if not session then
        return
      end

      render_buffer(session, args.buf)
    end,
  })
end

function M.refresh(session, callback)
  git.diff_against(session.repo_root, session.baseline_ref, function(err, lines)
    if err then
      ui_panel.append_entry(session, 'error', err)

      if callback then
        callback(err)
      end

      return
    end

    local files = diff.parse(lines)
    local review = tracker.replace(session, files)
    render_all(session)

    ui_panel.append_entry(
      session,
      'system',
      string.format('review refresh: %d files, %d pending hunks', review.counts.files, review.counts.hunks)
    )

    if callback then
      callback(nil, review)
    end
  end)
end

function M.clear(session)
  tracker.clear_all_acceptance(session)

  for _, bufnr in ipairs(open_buffers_for_repo(session)) do
    clear_buffer(bufnr)
    apply_gitsigns_base(session, bufnr, nil)
  end

  session.review = tracker.replace(session, {})
end

function M.next_hunk(session)
  local target = tracker.navigate(session, 'next', vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
  local _, err = jump_to_hunk(session, target)

  if err then
    log.warn(err)
  end
end

function M.prev_hunk(session)
  local target = tracker.navigate(session, 'prev', vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
  local _, err = jump_to_hunk(session, target)

  if err then
    log.warn(err)
  end
end

function M.open_file(session, relative_path)
  return open_file(session, relative_path)
end

function M.jump_to_hunk(session, hunk)
  return jump_to_hunk(session, hunk)
end

function M.jump_to_hunk_id(session, hunk_id)
  local hunk = tracker.get(session).hunks[hunk_id]

  if not hunk then
    return nil, 'no pending hunk at cursor'
  end

  return jump_to_hunk(session, hunk)
end

function M.accept_hunk(session)
  local hunk = tracker.current_hunk(session, vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])

  if not hunk then
    return nil, 'no pending hunk under cursor'
  end

  accept.hunk(session, hunk)
  return on_review_changed(session, 'accepted hunk')
end

function M.reject_hunk(session, callback)
  local bufnr = vim.api.nvim_get_current_buf()
  local hunk, err = reject.hunk(session, bufnr, vim.api.nvim_win_get_cursor(0)[1])

  if not hunk then
    if callback then
      callback(err)
    end

    return
  end

  M.refresh(session, function(refresh_err, review)
    if callback then
      callback(refresh_err, review)
    end
  end)
end

function M.accept_file(session)
  local path, err = reject.current_file(session, vim.api.nvim_get_current_buf())

  if not path then
    return nil, err
  end

  accept.file(session, path)
  return on_review_changed(session, 'accepted file: ' .. path)
end

function M.reject_file(session, callback)
  local path, err = reject.current_file(session, vim.api.nvim_get_current_buf())

  if not path then
    if callback then
      callback(err)
    end

    return
  end

  reject.file(session, path, function(reject_err)
    if reject_err then
      if callback then
        callback(reject_err)
      end

      return
    end

    M.refresh(session, callback)
  end)
end

function M.accept_all(session)
  accept.all(session)
  return on_review_changed(session, 'accepted all pending hunks')
end

function M.reject_all(session, callback)
  reject.all(session, function(err)
    if err then
      if callback then
        callback(err)
      end

      return
    end

    M.refresh(session, callback)
  end)
end

return M
