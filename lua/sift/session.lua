local backend = require('sift.backend')
local config = require('sift.config')
local fs = require('sift.fs')
local git = require('sift.git')
local log = require('sift.log')
local prompt_refs = require('sift.prompt')
local repo = require('sift.repo')
local review = require('sift.review')
local state = require('sift.state')
local ui_panel = require('sift.ui.panel')
local util = require('sift.util')

local M = {}
local augroup = vim.api.nvim_create_augroup('SiftSession', { clear = true })
local setup_done = false
local spinner_frames = { '|', '/', '-', '\\' }

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

local function stop_spinner(session)
  if session.spinner_timer then
    session.spinner_timer:stop()
    session.spinner_timer:close()
    session.spinner_timer = nil
  end
end

local function set_activity(session, activity, opts)
  opts = opts or {}
  session.activity_base = activity

  if opts.spinning then
    session.spinner_frame = session.spinner_frame or 1
    session.activity = string.format('%s %s', spinner_frames[session.spinner_frame], activity)

    if not session.spinner_timer then
      local timer = vim.loop.new_timer()
      session.spinner_timer = timer
      timer:start(
        120,
        120,
        vim.schedule_wrap(function()
          if session.spinner_timer ~= timer then
            return
          end

          session.spinner_frame = (session.spinner_frame % #spinner_frames) + 1
          session.activity = string.format('%s %s', spinner_frames[session.spinner_frame], session.activity_base or '')
          ui_panel.render(session)
        end)
      )
    end
  else
    stop_spinner(session)
    session.spinner_frame = 1
    session.activity = activity
  end

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
  set_activity(session, 'refreshing review state', { spinning = true })
  set_refreshing(session, true)

  review.refresh(session, function(err, review_state)
    set_refreshing(session, false)

    if err then
      set_activity(session, 'review refresh failed')
    else
      set_activity(session, 'ready for prompt')
    end

    if callback then
      callback(err, review_state)
    end
  end)
end

local function prime_tracked_files(session, callback)
  if session.tracked_files_loaded then
    util.schedule(callback, nil, session.tracked_files or {})
    return
  end

  git.tracked_files(session.repo_root, function(err, files)
    session.tracked_files_loaded = true
    session.tracked_files = files or {}

    if callback then
      callback(err, session.tracked_files)
    end
  end)
end

local function event_summary(event)
  local function append_text(texts, seen, value)
    if type(value) ~= 'string' then
      return
    end

    local trimmed = util.trim(value)
    if trimmed == '' or seen[trimmed] then
      return
    end

    seen[trimmed] = true
    table.insert(texts, trimmed)
  end

  local function collect_text(texts, seen, value)
    local value_type = type(value)

    if value_type == 'string' then
      append_text(texts, seen, value)
      return
    end

    if value_type ~= 'table' then
      return
    end

    if vim.islist(value) then
      for _, item in ipairs(value) do
        collect_text(texts, seen, item)
      end

      return
    end

    for _, key in ipairs({
      'summary',
      'content',
      'delta',
      'text',
      'message',
      'output_text',
      'reasoning',
    }) do
      collect_text(texts, seen, value[key])
    end

    if value.type == 'text' or value.type == 'output_text' or value.type == 'summary_text' then
      append_text(texts, seen, value.text or value.value)
    end
  end

  local function extract_text(value)
    local texts = {}
    local seen = {}
    collect_text(texts, seen, value)

    if vim.tbl_isempty(texts) then
      return nil
    end

    return table.concat(texts, '\n')
  end

  if type(event) ~= 'table' then
    return nil, 'backend'
  end

  if event.type == 'thread.started' and event.thread_id then
    return 'connected to Codex thread ' .. event.thread_id, 'info'
  end

  if event.type == 'turn.started' then
    return 'Codex started working on the prompt', 'info'
  end

  if event.type == 'turn.completed' then
    return 'Codex completed the prompt', 'info'
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

  if event.item and event.item.type == 'tool_call' and event.item.name then
    return 'tool call: ' .. event.item.name, 'backend'
  end

  if event.item and event.item.type == 'reasoning' then
    local detail = extract_text(event.item.summary) or extract_text(event.summary) or extract_text(event.delta)
    return detail or 'Codex is reasoning', 'assistant'
  end

  if event.item and event.item.type == 'message' and event.item.role then
    local detail = extract_text(event.item.content) or extract_text(event.delta)

    if detail then
      return detail, 'assistant'
    end

    return event.item.role == 'assistant' and 'assistant response' or ('[' .. event.item.role .. ' message]'), 'assistant'
  end

  if event.message then
    return event.message, 'backend'
  end

  if event.delta then
    local detail = extract_text(event.delta)

    if detail then
      return detail, 'assistant'
    end

    return nil, 'assistant'
  end

  return nil, 'backend'
end

local function event_activity(event)
  if type(event) ~= 'table' then
    return nil
  end

  if event.type == 'thread.started' then
    return 'connected to Codex'
  end

  if event.type == 'turn.started' then
    return 'Codex is working'
  end

  if event.type == 'turn.completed' then
    return 'Codex completed the turn'
  end

  if event.type == 'turn.failed' or event.type == 'error' then
    return 'Codex reported an error'
  end

  if event.item and event.item.type == 'message' and event.item.role == 'assistant' then
    return 'Codex sent a message'
  end

  if event.delta then
    return 'Codex is streaming output'
  end

  return nil
end

local function ensure_session_bindings(session)
  if type(session.submit_prompt) ~= 'function' then
    session.submit_prompt = function(text)
      M.prompt(text, function(prompt_err)
        if prompt_err then
          return
        end

        ui_panel.focus_prompt(session)
      end)
    end
  end

  if type(session.panel_next_hunk) ~= 'function' then
    session.panel_next_hunk = function()
      M.next_hunk()
    end
  end

  if type(session.panel_prev_hunk) ~= 'function' then
    session.panel_prev_hunk = function()
      M.prev_hunk()
    end
  end

  if type(session.panel_refresh) ~= 'function' then
    session.panel_refresh = function()
      M.refresh()
    end
  end

  if type(session.panel_open_file) ~= 'function' then
    session.panel_open_file = function(path)
      return review.open_file(session, path)
    end
  end

  if type(session.panel_jump_hunk) ~= 'function' then
    session.panel_jump_hunk = function(hunk_id)
      return review.jump_to_hunk_id(session, hunk_id)
    end
  end

  if type(session.panel_accept_all) ~= 'function' then
    session.panel_accept_all = function()
      M.accept_all()
    end
  end

  if type(session.panel_reject_all) ~= 'function' then
    session.panel_reject_all = function()
      M.reject_all()
    end
  end
end

local function reference_payload(text, expanded_prompt)
  local prompt_lines = util.lines(text)
  local expanded_lines = util.lines(expanded_prompt)
  local start = #prompt_lines + 2

  if start > #expanded_lines then
    return ''
  end

  return table.concat(vim.list_slice(expanded_lines, start, #expanded_lines), '\n')
end

local function summarize_review_files(review_state)
  if not review_state or not review_state.file_list then
    return 'no pending file changes after this run'
  end

  if review_state.counts.files == 0 then
    return 'no pending file changes after this run'
  end

  local paths = {}

  for index, file in ipairs(review_state.file_list) do
    if index > 5 then
      break
    end

    table.insert(paths, file.path)
  end

  local suffix = ''

  if review_state.counts.files > #paths then
    suffix = string.format(' (+%d more)', review_state.counts.files - #paths)
  end

  return 'pending files after this run: ' .. table.concat(paths, ', ') .. suffix
end

local function start_session(callback)
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
      ensure_session_bindings(existing)
      ui_panel.open(existing)
      set_activity(existing, existing.activity or 'ready for prompt')
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
      activity = 'creating baseline ref',
      tracked_files = {},
      tracked_files_loaded = false,
      transcript = {},
    }

    ensure_session_bindings(session)
    state.set_session(repo_root, session)
    ui_panel.open(session, { focus_prompt = false })
    ui_panel.append_entry(session, 'system', 'creating baseline ref...')

    git.create_baseline(repo_root, session.id, function(create_err, baseline)
      if create_err then
        state.remove_session(repo_root)
        ui_panel.append_entry(session, 'error', create_err)
        set_status(session, 'error')
        set_activity(session, 'failed to create baseline')
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
      set_activity(session, 'loading tracked files', { spinning = true })

      prime_tracked_files(session, function(files_err)
        if files_err then
          ui_panel.append_entry(session, 'error', files_err)
          log.warn(files_err)
        end

        refresh_review(session, function(refresh_err, review_state)
          if refresh_err then
            log.warn(refresh_err)
          else
            ui_panel.append_entry(session, 'system', summarize_review_files(review_state))
          end

          if callback then
            callback(refresh_err, session)
          end
        end)
      end)
    end)
  end)
end

function M.start(callback)
  start_session(callback)
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
      stop_spinner(session)
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
      if config.get().panel.auto_start then
        start_session(function(start_err, started_session)
          if start_err then
            if callback then
              callback(start_err)
            end

            return
          end

          ui_panel.focus_prompt(started_session)

          if callback then
            callback(nil, started_session)
          end
        end)
        return
      end

      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    ensure_session_bindings(session)
    if session.panel and session.panel.winid and vim.api.nvim_win_is_valid(session.panel.winid) then
      ui_panel.close(session)
    else
      ui_panel.focus_prompt(session)
    end

    if callback then
      callback(nil, session)
    end
  end)
end

function M.focus_prompt(callback)
  current_session(function(err, session)
    if err then
      if config.get().panel.auto_start then
        start_session(function(start_err, started_session)
          if start_err then
            if callback then
              callback(start_err)
            end

            return
          end

          ui_panel.focus_prompt(started_session)

          if callback then
            callback(nil, started_session)
          end
        end)
        return
      end

      log.error(err)

      if callback then
        callback(err)
      end

      return
    end

    ensure_session_bindings(session)
    ui_panel.focus_prompt(session)

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

    ensure_session_bindings(session)
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

    local expanded_prompt, referenced_files, expand_err = prompt_refs.expand(session, text)

    if not expanded_prompt then
      ui_panel.append_entry(session, 'error', expand_err)
      log.warn(expand_err)

      if callback then
        callback(expand_err)
      end

      return
    end

    ui_panel.open(session)
    ui_panel.append_entry(session, 'user', text)
    if not vim.tbl_isempty(referenced_files) then
      ui_panel.append_references(session, referenced_files, reference_payload(text, expanded_prompt))
    end
    set_status(session, 'running')
    set_activity(session, 'sending prompt to Codex', { spinning = true })

    local job_id, start_err = backend.start(session, expanded_prompt, {
      on_event = function(event)
        local message, kind = event_summary(event)
        local activity = event_activity(event)

        if activity then
          set_activity(session, activity, { spinning = true })
        end

        if message and util.trim(message) ~= '' then
          ui_panel.append_entry(session, kind, message)
        end
      end,
      on_stdout_line = function(line)
        if util.trim(line) ~= '' then
          set_activity(session, 'Codex produced backend output', { spinning = true })
          ui_panel.append_entry(session, 'backend', line)
        end
      end,
      on_stderr_line = function(line)
        if util.trim(line) ~= '' then
          set_activity(session, 'Codex produced stderr output', { spinning = true })
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
          set_activity(session, 'refreshing workspace changes', { spinning = true })
          ui_panel.append_entry(session, 'system', 'Codex run completed')
        else
          set_activity(session, 'Codex run failed')
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
      set_activity(session, 'failed to start Codex')
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

    stop_spinner(session)

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
