local backend = require('sift.backend')
local fs = require('sift.fs')
local git = require('sift.git')
local log = require('sift.log')
local repo = require('sift.repo')
local review = require('sift.review')
local state = require('sift.state')
local ui_panel = require('sift.ui.panel')
local util = require('sift.util')

local M = {}
local augroup = vim.api.nvim_create_augroup('SiftSession', { clear = true })
local setup_done = false

local function current_session(callback)
  repo.current_root(function(err, repo_root)
    if err then
      callback(err)
      return
    end

    repo_root = fs.realpath(repo_root)

    local session = state.get_session(repo_root)

    if not session then
      callback('no active sift session for this repository')
      return
    end

    callback(nil, session)
  end)
end

local function set_status(session, status)
  session.status = status
  ui_panel.render(session)
end

local function set_refreshing(session, refreshing)
  session.refreshing = refreshing

  if refreshing then
    set_status(session, 'refreshing')
  elseif not session.run then
    set_status(session, 'idle')
  end
end

local function ensure_ready(session, callback)
  if session.run then
    local message = 'a Codex run is still active for this session'
    log.warn(message)

    if callback then
      callback(message)
    end

    return false
  end

  if session.refreshing then
    local message = 'sift is refreshing review state; try again in a moment'
    log.warn(message)

    if callback then
      callback(message)
    end

    return false
  end

  return true
end

local function refresh_review(session, callback)
  set_refreshing(session, true)

  review.refresh(session, function(err, review_state)
    set_refreshing(session, false)

    if callback then
      callback(err, review_state)
    end
  end)
end

local function event_summary(event)
  if type(event) ~= 'table' then
    return nil, 'backend'
  end

  if event.type == 'thread.started' and event.thread_id then
    return 'thread started: ' .. event.thread_id, 'info'
  end

  if event.type == 'turn.started' then
    return 'turn started', 'info'
  end

  if event.type == 'turn.completed' then
    return 'turn completed', 'info'
  end

  if event.type == 'error' and event.message then
    return event.message, 'error'
  end

  if event.type == 'turn.failed' and event.error and event.error.message then
    return event.error.message, 'error'
  end

  if event.item and event.item.type == 'error' and event.item.message then
    return event.item.message, 'error'
  end

  if event.item and event.item.type == 'message' and event.item.role then
    return '[' .. event.item.role .. ' message]', 'assistant'
  end

  if event.message then
    return event.message, 'backend'
  end

  if event.delta then
    return event.delta, 'assistant'
  end

  return '[' .. (event.type or 'event') .. ']', 'backend'
end

function M.start(callback)
  repo.current_root(function(err, repo_root)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    repo_root = fs.realpath(repo_root)

    local existing = state.get_session(repo_root)

    if existing then
      ui_panel.open(existing)
      log.info('sift session already active for this repository')

      if callback then
        callback(nil, existing)
      end

      return
    end

    local session = {
      id = util.session_id(),
      repo_root = repo_root,
      baseline_ref = nil,
      baseline_commit = nil,
      run = nil,
      status = 'starting',
      transcript = {},
    }

    state.set_session(repo_root, session)
    ui_panel.open(session)
    ui_panel.append_entry(session, 'system', 'creating baseline ref...')

    git.create_baseline(repo_root, session.id, function(create_err, baseline)
      if create_err then
        state.remove_session(repo_root)
        ui_panel.append_entry(session, 'error', create_err)
        set_status(session, 'error')
        log.error(create_err)

        if callback then
          callback(create_err)
        end

        return
      end

      session.baseline_ref = baseline.ref
      session.baseline_commit = baseline.commit
      ui_panel.append_entry(
        session,
        'system',
        string.format('baseline ready: %s -> %s', session.baseline_ref, session.baseline_commit)
      )
      refresh_review(session, function(refresh_err)
        if refresh_err then
          log.warn(refresh_err)
        end

        if callback then
          callback(refresh_err, session)
        end
      end)
    end)
  end)
end

function M.stop(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if session.run and session.run.job_id then
      session.closing = true
      vim.fn.jobstop(session.run.job_id)
      session.run = nil
      ui_panel.append_entry(session, 'system', 'stopped active Codex job')
    end

    local function finish(stop_err)
      if stop_err then
        ui_panel.append_entry(session, 'error', stop_err)
        log.error(stop_err)

        if callback then
          callback(stop_err)
        end

        return
      end

      review.clear(session)
      state.remove_session(session.repo_root)
      ui_panel.close(session)
      log.info('sift session stopped')

      if callback then
        callback(nil)
      end
    end

    if session.baseline_ref then
      git.delete_ref(session.repo_root, session.baseline_ref, finish)
      return
    end

    finish(nil)
  end)
end

function M.toggle_panel(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    ui_panel.toggle(session)

    if callback then
      callback(nil, session)
    end
  end)
end

function M.prompt(prompt_text, callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if session.run then
      local message = 'a Codex run is already active for this session'
      ui_panel.append_entry(session, 'error', message)
      log.warn(message)

      if callback then
        callback(message)
      end

      return
    end

    if not ensure_ready(session, callback) then
      return
    end

    local text = util.trim(prompt_text)

    if text == '' then
      local message = 'prompt cannot be empty'
      ui_panel.append_entry(session, 'error', message)
      log.warn(message)

      if callback then
        callback(message)
      end

      return
    end

    ui_panel.open(session)
    ui_panel.append_entry(session, 'user', text)
    set_status(session, 'running')

    local job_id, start_err = backend.start(session, text, {
      on_event = function(event)
        local message, kind = event_summary(event)

        if message and util.trim(message) ~= '' then
          ui_panel.append_entry(session, kind, message)
        end
      end,
      on_stdout_line = function(line)
        if util.trim(line) ~= '' then
          ui_panel.append_entry(session, 'backend', line)
        end
      end,
      on_stderr_line = function(line)
        if util.trim(line) ~= '' then
          ui_panel.append_entry(session, 'error', line)
        end
      end,
      on_exit = function(code)
        if session.closing then
          return
        end

        session.run = nil
        local exit_code = tonumber(code)
        local run_err = nil

        if exit_code ~= 0 then
          run_err = string.format('Codex exited with code %s', tostring(code))
        end

        if exit_code == 0 then
          ui_panel.append_entry(session, 'system', 'Codex run completed')
        else
          ui_panel.append_entry(session, 'error', run_err)
        end

        refresh_review(session, function(refresh_err)
          if refresh_err then
            log.warn(refresh_err)
          end

          if callback then
            callback(run_err or refresh_err, session)
          end
        end)
      end,
    })

    if not job_id then
      session.run = nil
      set_status(session, 'idle')
      ui_panel.append_entry(session, 'error', start_err)
      log.error(start_err)

      if callback then
        callback(start_err)
      end

      return
    end

    session.run = {
      job_id = job_id,
      prompt = text,
    }
    session.closing = false
  end)
end

function M.refresh(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if not ensure_ready(session, callback) then
      return
    end

    refresh_review(session, callback)
  end)
end

function M.next_hunk(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if not ensure_ready(session, callback) then
      return
    end

    review.next_hunk(session)

    if callback then
      callback(nil, session)
    end
  end)
end

function M.prev_hunk(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if not ensure_ready(session, callback) then
      return
    end

    review.prev_hunk(session)

    if callback then
      callback(nil, session)
    end
  end)
end

function M.accept_hunk(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if not ensure_ready(session, callback) then
      return
    end

    local review_state, accept_err = review.accept_hunk(session)

    if not review_state then
      log.warn(accept_err)

      if callback then
        callback(accept_err)
      end

      return
    end

    if callback then
      callback(nil, review_state)
    end
  end)
end

function M.reject_hunk(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if not ensure_ready(session, callback) then
      return
    end

    review.reject_hunk(session, function(reject_err, review_state)
      if reject_err then
        log.warn(reject_err)
      end

      if callback then
        callback(reject_err, review_state)
      end
    end)
  end)
end

function M.accept_file(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if not ensure_ready(session, callback) then
      return
    end

    local review_state, accept_err = review.accept_file(session)

    if not review_state then
      log.warn(accept_err)

      if callback then
        callback(accept_err)
      end

      return
    end

    if callback then
      callback(nil, review_state)
    end
  end)
end

function M.reject_file(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if not ensure_ready(session, callback) then
      return
    end

    review.reject_file(session, function(reject_err, review_state)
      if reject_err then
        log.warn(reject_err)
      end

      if callback then
        callback(reject_err, review_state)
      end
    end)
  end)
end

function M.accept_all(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if not ensure_ready(session, callback) then
      return
    end

    local review_state = review.accept_all(session)

    if callback then
      callback(nil, review_state)
    end
  end)
end

function M.reject_all(callback)
  current_session(function(err, session)
    if err then
      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    if not ensure_ready(session, callback) then
      return
    end

    review.reject_all(session, function(reject_err, review_state)
      if reject_err then
        log.warn(reject_err)
      end

      if callback then
        callback(reject_err, review_state)
      end
    end)
  end)
end

local function cleanup_for_exit()
  for _, session in pairs(state.all_sessions()) do
    session.closing = true

    if session.run and session.run.job_id then
      vim.fn.jobstop(session.run.job_id)
      session.run = nil
    end

    if session.baseline_ref then
      git.delete_ref_sync(session.repo_root, session.baseline_ref)
    end
  end
end

function M.setup()
  if setup_done then
    return
  end

  setup_done = true

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = cleanup_for_exit,
  })
end

return M
