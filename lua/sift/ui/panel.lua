local config = require('sift.config')
local hunk_util = require('sift.diff.hunk')
local prompt = require('sift.prompt')

local M = {}
local namespace = vim.api.nvim_create_namespace('sift.panel')
local prompt_prefix = '> '
local prompt_line_prefix = '| '

local kind_label = {
  assistant = 'assistant',
  backend = 'backend',
  error = 'error',
  info = 'info',
  system = 'system',
  user = 'user',
}

local function split_text(text)
  if type(text) ~= 'string' or text == '' then
    return { '' }
  end

  return vim.split(text, '\n', { plain = true })
end

local function entry_id(session)
  session.panel = session.panel or {}
  local panel = session.panel
  panel.entry_seq = (panel.entry_seq or 0) + 1
  return panel.entry_seq
end

local function ensure_panel_table(session)
  session.panel = session.panel or {}
  session.transcript = session.transcript or {}
  return session.panel
end

local function transcript_blocks(session)
  local session_entries = {}
  local runs = {}
  local current_run = nil

  for _, entry in ipairs(session.transcript or {}) do
    if entry.kind == 'user' then
      current_run = {
        prompt = entry,
        entries = {},
        references = nil,
      }
      table.insert(runs, current_run)
    elseif current_run then
      if entry.kind == 'references' then
        current_run.references = entry
      else
        table.insert(current_run.entries, entry)
      end
    else
      table.insert(session_entries, entry)
    end
  end

  return session_entries, runs
end

local function sync_prompt_from_buffer(session)
  local panel = ensure_panel_table(session)

  if not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(panel.bufnr, 0, -1, false)
  local border = M.composer_border()
  local closing = nil
  local opening = nil

  for index = #lines, 1, -1 do
    if lines[index] == border then
      if not closing then
        closing = index
      else
        opening = index
        break
      end
    end
  end

  if not opening or not closing or closing <= opening then
    return
  end

  local prompt_lines = {}

  for index = opening + 1, closing - 1 do
    local line = lines[index] or ''

    if vim.startswith(line, prompt_line_prefix) then
      table.insert(prompt_lines, line:sub(#prompt_line_prefix + 1))
    else
      table.insert(prompt_lines, line)
    end
  end

  if vim.tbl_isempty(prompt_lines) then
    panel.prompt = ''
  else
    panel.prompt = table.concat(prompt_lines, '\n')
  end
end

local function prompt_text(session)
  local panel = ensure_panel_table(session)
  return panel.prompt or ''
end

local function prompt_lnum(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local border = M.composer_border()
  local opening = nil
  local closing = nil

  for index = #lines, 1, -1 do
    if lines[index] == border then
      if not closing then
        closing = index
      else
        opening = index
        break
      end
    end
  end

  if opening and closing and closing - opening >= 2 then
    return closing - 1
  end

  return vim.api.nvim_buf_line_count(bufnr)
end

local function focus_prompt_cursor(session)
  local panel = ensure_panel_table(session)

  if not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return
  end

  local bufnr = panel.bufnr

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lnum = prompt_lnum(bufnr)
  local prompt_lines = split_text(prompt_text(session))
  local last_line = prompt_lines[#prompt_lines] or ''
  local col = #prompt_line_prefix + #last_line

  vim.api.nvim_set_current_win(panel.winid)
  vim.api.nvim_win_set_cursor(panel.winid, { lnum, col })
end

local function complete_reference(session)
  local panel = ensure_panel_table(session)

  if not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(panel.winid)
  local line = vim.api.nvim_get_current_line()
  local ref = prompt.reference_fragment(line, cursor[2])

  if not ref then
    return false
  end

  local matches, err = prompt.complete_paths(session, ref.fragment)

  if not matches then
    M.append_entry(session, 'error', err)
    return true
  end

  if vim.tbl_isempty(matches) then
    return true
  end

  local items = {}

  for _, path in ipairs(matches) do
    table.insert(items, {
      word = '@' .. path,
      menu = 'sift',
    })
  end

  vim.fn.complete(ref.startcol, items)
  return true
end

local function feedkeys(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'in', false)
end

local function append_prompt_newline(session)
  local text = prompt_text(session)

  if text == '' then
    M.set_prompt(session, '\n')
  else
    M.set_prompt(session, text .. '\n')
  end

  M.focus_prompt(session)
end

local function action_error_message(err)
  if err == nil then
    return 'panel action failed'
  end

  if type(err) == 'string' then
    return err
  end

  if type(err) == 'table' and err.message then
    return err.message
  end

  return tostring(err)
end

local function attach_mappings(session, bufnr)
  vim.keymap.set('n', 'q', function()
    M.close(session)
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('n', 'za', function()
    M.toggle_at_cursor(session)
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('n', '<CR>', function()
    if not M.jump_at_cursor(session) then
      M.focus_prompt(session)
    end
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('n', 'gf', function()
    M.jump_at_cursor(session)
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('i', '<CR>', function()
    M.submit_prompt(session)
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('n', 'i', function()
    M.focus_prompt(session)
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('i', '<Tab>', function()
    if not complete_reference(session) then
      feedkeys('<Tab>')
    end
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('i', '<S-CR>', function()
    append_prompt_newline(session)
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('i', '<C-j>', function()
    append_prompt_newline(session)
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('n', ']s', function()
    local action = session.panel_next_hunk
    if type(action) == 'function' then
      action()
    end
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('n', '[s', function()
    local action = session.panel_prev_hunk
    if type(action) == 'function' then
      action()
    end
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('n', 'gr', function()
    local action = session.panel_refresh
    if type(action) == 'function' then
      action()
    end
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('n', 'gA', function()
    local action = session.panel_accept_all
    if type(action) == 'function' then
      action()
    end
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('n', 'gR', function()
    local action = session.panel_reject_all
    if type(action) == 'function' then
      action()
    end
  end, { buffer = bufnr, nowait = true, silent = true })
end

local function ensure_buffer(session)
  local panel = ensure_panel_table(session)

  if panel.bufnr and vim.api.nvim_buf_is_valid(panel.bufnr) then
    return panel.bufnr
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_name(bufnr, string.format('sift://panel/%s', session.id))
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].filetype = 'sift-panel'
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true

  vim.api.nvim_buf_set_var(bufnr, 'sift_session_repo_root', session.repo_root)
  attach_mappings(session, bufnr)

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged', 'BufLeave' }, {
    buffer = bufnr,
    callback = function()
      sync_prompt_from_buffer(session)
    end,
  })

  vim.api.nvim_create_autocmd('InsertLeave', {
    buffer = bufnr,
    callback = function()
      sync_prompt_from_buffer(session)

      if panel.pending_render then
        panel.pending_render = false
        M.render(session, { force = true, skip_prompt_sync = true })
      end
    end,
  })

  panel.bufnr = bufnr

  return bufnr
end

local function push_line(lines, metadata, text, meta)
  table.insert(lines, text)
  metadata[#lines] = meta or {}
end

local function render_entry(lines, metadata, entry, indent)
  table.insert(lines, string.format('%s[%s] %s', indent, entry.timestamp, kind_label[entry.kind] or entry.kind))
  metadata[#lines] = {
    kind = entry.kind,
    role = 'header',
  }

  for _, line in ipairs(split_text(entry.text)) do
    push_line(lines, metadata, string.format('%s  %s', indent, line), {
      kind = entry.kind,
      role = 'body',
    })
  end
end

local function render_references(lines, actions, metadata, entry)
  push_line(lines, metadata, string.format('  references: %d file(s) [%s]', #entry.files, entry.collapsed and 'collapsed' or 'expanded'), {
    kind = 'references',
    role = 'header',
  })
  actions[#lines] = {
    kind = 'toggle_references',
    entry_id = entry.id,
  }

  if entry.collapsed then
    return
  end

  for _, path in ipairs(entry.files or {}) do
    push_line(lines, metadata, '    @' .. path, {
      kind = 'references',
      role = 'file',
    })
    actions[#lines] = {
      kind = 'open_file',
      path = path,
    }
  end

  if entry.payload_text and entry.payload_text ~= '' then
    push_line(lines, metadata, '    payload:', {
      kind = 'references',
      role = 'payload_header',
    })

    for _, line in ipairs(split_text(entry.payload_text)) do
      push_line(lines, metadata, '      ' .. line, {
        kind = 'references',
        role = 'payload_body',
      })
    end
  end
end

local function pluralize(count, singular, plural)
  if count == 1 then
    return singular
  end

  return plural or (singular .. 's')
end

local function hunk_location(hunk)
  local anchor = hunk_util.anchor(hunk)
  local finish = hunk_util.finish(hunk)

  if anchor == finish then
    return 'line ' .. anchor
  end

  return string.format('lines %d-%d', anchor, finish)
end

local function hunk_summary(hunk)
  local detail = hunk.context

  if detail == nil or detail == '' then
    detail = hunk.type or 'change'
  end

  return string.format('    %s  %s', hunk_location(hunk), detail)
end

local function render_pending_review(lines, actions, metadata, review)
  push_line(lines, metadata, 'Pending Review:', { kind = 'section' })

  if not review or review.counts.files == 0 then
    push_line(lines, metadata, '  no pending hunks', {
      kind = 'info',
      role = 'empty_pending',
    })
    push_line(lines, metadata, '', { kind = 'spacer' })
    return
  end

  for _, file in ipairs(review.file_list or {}) do
    push_line(
      lines,
      metadata,
      string.format('  %s (%d %s)', file.path, #file.hunks, pluralize(#file.hunks, 'hunk')),
      {
        kind = 'pending',
        role = 'file',
      }
    )
    actions[#lines] = {
      kind = 'open_review_file',
      path = file.path,
    }

    for _, hunk in ipairs(file.hunks or {}) do
      push_line(lines, metadata, hunk_summary(hunk), {
        kind = 'pending',
        role = 'hunk',
      })
      actions[#lines] = {
        kind = 'jump_review_hunk',
        hunk_id = hunk.id,
      }
    end
  end

  push_line(lines, metadata, '', { kind = 'spacer' })
end

local function render_lines(session)
  local review = session.review or {
    counts = {
      files = 0,
      hunks = 0,
    },
  }

  local lines = {
    'sift.nvim',
    '',
    'repo: ' .. session.repo_root,
    'session: ' .. session.id,
    'status: ' .. session.status,
    'activity: ' .. (session.activity or 'ready for prompt'),
    'baseline: ' .. (session.baseline_ref or 'pending'),
    string.format('pending: %d files, %d hunks', review.counts.files, review.counts.hunks),
    '',
    'Prompt: use @path refs, <Tab> completes, <S-CR> newline, <CR>/gf jump, q closes',
    '',
  }
  local actions = {}
  local metadata = {
    [1] = { kind = 'title' },
  }
  local session_entries, runs = transcript_blocks(session)

  render_pending_review(lines, actions, metadata, review)

  if not vim.tbl_isempty(session_entries) then
    push_line(lines, metadata, 'Session:', { kind = 'section' })

    for _, entry in ipairs(session_entries) do
      render_entry(lines, metadata, entry, '  ')
      push_line(lines, metadata, '', { kind = 'spacer' })
    end
  end

  for index, run in ipairs(runs) do
    push_line(lines, metadata, string.format('Run %d', index), { kind = 'section' })
    render_entry(lines, metadata, run.prompt, '  ')

    if run.references then
      render_references(lines, actions, metadata, run.references)
    end

    for _, entry in ipairs(run.entries) do
      render_entry(lines, metadata, entry, '  ')
    end

    push_line(lines, metadata, '', { kind = 'spacer' })
  end

  local border = M.composer_border()
  local prompt_lines = split_text(prompt_text(session))

  push_line(lines, metadata, 'Prompt:', { kind = 'section' })
  push_line(lines, metadata, border, { kind = 'composer_border' })

  for _, line in ipairs(prompt_lines) do
    push_line(lines, metadata, prompt_line_prefix .. line, {
      kind = 'composer_body',
    })
  end

  push_line(lines, metadata, border, { kind = 'composer_border' })

  return lines, actions, metadata
end

local function apply_highlights(bufnr, lines, actions, metadata)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

  for index, line in ipairs(lines) do
    local lnum = index - 1
    local action = actions[index]
    local meta = metadata[index] or {}

    if meta.kind == 'title' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Title', lnum, 0, -1)
    elseif meta.kind == 'section' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Statement', lnum, 0, -1)
    elseif vim.startswith(line, 'repo:') or vim.startswith(line, 'session:') or vim.startswith(line, 'status:') or vim.startswith(line, 'activity:') or vim.startswith(line, 'baseline:') or vim.startswith(line, 'pending:') then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Identifier', lnum, 0, line:find(':') or -1)
    elseif meta.kind == 'composer_border' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Comment', lnum, 0, -1)
    elseif meta.kind == 'composer_body' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'String', lnum, 0, #prompt_line_prefix)
    elseif meta.kind == 'error' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'DiagnosticError', lnum, 0, -1)
    elseif meta.kind == 'assistant' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Special', lnum, 0, -1)
    elseif meta.kind == 'backend' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Comment', lnum, 0, -1)
    elseif meta.kind == 'info' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Directory', lnum, 0, -1)
    elseif action and action.kind == 'open_review_file' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Directory', lnum, 2, -1)
    elseif action and action.kind == 'jump_review_hunk' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Underlined', lnum, 4, -1)
    elseif action and action.kind == 'toggle_references' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Directory', lnum, 2, -1)
    elseif meta.kind == 'references' and meta.role == 'payload_header' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Comment', lnum, 4, -1)
    elseif meta.kind == 'references' and meta.role == 'payload_body' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Comment', lnum, 0, -1)
    elseif action and action.kind == 'open_file' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Underlined', lnum, 4, -1)
    elseif meta.role == 'header' and meta.kind == 'user' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Constant', lnum, 0, -1)
    elseif meta.role == 'header' and meta.kind == 'system' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Identifier', lnum, 0, -1)
    elseif meta.role == 'header' and meta.kind == 'assistant' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Special', lnum, 0, -1)
    elseif meta.role == 'header' and meta.kind == 'backend' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Comment', lnum, 0, -1)
    elseif meta.role == 'header' and meta.kind == 'error' then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'DiagnosticError', lnum, 0, -1)
    elseif vim.startswith(line, '  [') then
      vim.api.nvim_buf_add_highlight(bufnr, namespace, 'Comment', lnum, 2, 12)
    end
  end
end

function M.render(session, opts)
  opts = opts or {}

  if not opts.skip_prompt_sync then
    sync_prompt_from_buffer(session)
  end

  local bufnr = ensure_buffer(session)
  local panel = ensure_panel_table(session)
  local is_current = vim.api.nvim_get_current_buf() == bufnr
  local mode = vim.api.nvim_get_mode().mode
  local keep_insert = mode:sub(1, 1) == 'i' and is_current

  if keep_insert and not opts.force then
    panel.pending_render = true
    return
  end

  local lines, actions, metadata = render_lines(session)
  panel.line_actions = actions
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  apply_highlights(bufnr, lines, actions, metadata)
  panel.pending_render = false

  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) and is_current then
    focus_prompt_cursor(session)

    if keep_insert then
      vim.cmd('startinsert!')
    end
  end
end

function M.open(session, opts)
  opts = opts or {}

  local panel = ensure_panel_table(session)
  local bufnr = ensure_buffer(session)
  local current_win = vim.api.nvim_get_current_win()

  if not panel.winid or current_win ~= panel.winid then
    panel.source_winid = current_win
  end

  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    vim.api.nvim_set_current_win(panel.winid)
    M.render(session)

    if opts.focus_prompt then
      M.focus_prompt(session)
    end

    return panel.winid
  end

  local panel_config = config.get().panel

  if panel_config.position == 'bottom' then
    vim.cmd(string.format('botright %dsplit', panel_config.height))
  else
    vim.cmd(string.format('botright vertical %dsplit', panel_config.width))
  end

  panel.winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel.winid, bufnr)
  vim.wo[panel.winid].number = false
  vim.wo[panel.winid].relativenumber = false
  vim.wo[panel.winid].signcolumn = 'no'
  vim.wo[panel.winid].winfixheight = panel_config.position == 'bottom'
  vim.wo[panel.winid].winfixwidth = panel_config.position ~= 'bottom'
  vim.wo[panel.winid].wrap = false

  M.render(session)

  if opts.focus_prompt then
    M.focus_prompt(session)
  end

  return panel.winid
end

function M.close(session)
  local panel = ensure_panel_table(session)

  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    vim.api.nvim_win_close(panel.winid, true)
  end

  panel.winid = nil
end

function M.toggle(session)
  local panel = ensure_panel_table(session)

  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    M.close(session)
    return
  end

  M.open(session)
end

function M.append_entry(session, kind, text)
  session.transcript = session.transcript or {}

  table.insert(session.transcript, {
    id = entry_id(session),
    kind = kind,
    text = text,
    timestamp = os.date('%H:%M:%S'),
  })

  M.render(session)
end

function M.append_references(session, files, payload_text)
  session.transcript = session.transcript or {}

  table.insert(session.transcript, {
    id = entry_id(session),
    kind = 'references',
    files = files or {},
    payload_text = payload_text or '',
    collapsed = true,
    text = '',
    timestamp = os.date('%H:%M:%S'),
  })

  M.render(session)
end

function M.focus_prompt(session)
  M.open(session, { focus_prompt = false })
  M.render(session, { force = true })
  focus_prompt_cursor(session)
  vim.cmd('startinsert!')
end

function M.get_prompt(session)
  sync_prompt_from_buffer(session)
  return prompt_text(session)
end

function M.set_prompt(session, text)
  local panel = ensure_panel_table(session)
  panel.prompt = text or ''
  M.render(session, { force = true, skip_prompt_sync = true })
end

function M.submit_prompt(session)
  local submit = session.submit_prompt

  if type(submit) ~= 'function' then
    return
  end

  sync_prompt_from_buffer(session)
  submit(M.get_prompt(session))
end

function M.toggle_at_cursor(session)
  local panel = ensure_panel_table(session)

  if not panel.line_actions then
    return
  end

  local action = panel.line_actions[vim.api.nvim_win_get_cursor(0)[1]]

  if not action or action.kind ~= 'toggle_references' then
    return
  end

  for _, entry in ipairs(session.transcript or {}) do
    if entry.id == action.entry_id then
      entry.collapsed = not entry.collapsed
      M.render(session, { skip_prompt_sync = true })
      return
    end
  end
end

function M.jump_at_cursor(session)
  local panel = ensure_panel_table(session)

  if not panel.line_actions then
    return false
  end

  local action = panel.line_actions[vim.api.nvim_win_get_cursor(0)[1]]

  if not action then
    return false
  end

  local target_win = panel.source_winid

  if not target_win or not vim.api.nvim_win_is_valid(target_win) or target_win == panel.winid then
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if winid ~= panel.winid then
        target_win = winid
        break
      end
    end
  end

  if not target_win or not vim.api.nvim_win_is_valid(target_win) then
    return false
  end

  local panel_win = panel.winid
  local current_win = vim.api.nvim_get_current_win()
  local function run_in_target(fn)
    panel.source_winid = target_win
    vim.api.nvim_set_current_win(target_win)

    local ok, result, err = pcall(fn)
    local succeeded = ok and result ~= nil and result ~= false

    if succeeded then
      return true
    end

    if panel_win and vim.api.nvim_win_is_valid(panel_win) then
      vim.api.nvim_set_current_win(panel_win)
    elseif current_win and vim.api.nvim_win_is_valid(current_win) then
      vim.api.nvim_set_current_win(current_win)
    end

    local message = not ok and action_error_message(result) or action_error_message(err)
    if message ~= '' then
      M.append_entry(session, 'error', message)
    end

    return false
  end

  if action.kind == 'open_file' and action.path then
    return run_in_target(function()
      local ok, err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(session.repo_root .. '/' .. action.path))

      if not ok then
        return nil, err
      end

      return true
    end)
  end

  if action.kind == 'open_review_file' and action.path then
    local open_review_file = session.panel_open_file

    if type(open_review_file) == 'function' then
      return run_in_target(function()
        return open_review_file(action.path)
      end)
    end

    return run_in_target(function()
      local ok, err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(session.repo_root .. '/' .. action.path))

      if not ok then
        return nil, err
      end

      return true
    end)
  end

  if action.kind == 'jump_review_hunk' and action.hunk_id then
    local jump_review_hunk = session.panel_jump_hunk

    if type(jump_review_hunk) == 'function' then
      return run_in_target(function()
        return jump_review_hunk(action.hunk_id)
      end)
    end
  end

  return false
end

function M.composer_border()
  local width = math.max(20, (config.get().panel.width or 50) - 4)
  return '+' .. string.rep('-', width) .. '+'
end

return M
