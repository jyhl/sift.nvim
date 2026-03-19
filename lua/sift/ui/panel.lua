local config = require('sift.config')

local M = {}

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

local function ensure_panel_table(session)
  session.panel = session.panel or {}
  session.transcript = session.transcript or {}
  return session.panel
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
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_buf_set_var(bufnr, 'sift_session_repo_root', session.repo_root)

  vim.keymap.set('n', 'q', function()
    M.close(session)
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set('n', '<CR>', function()
    vim.cmd('SiftPrompt')
  end, { buffer = bufnr, nowait = true, silent = true })

  panel.bufnr = bufnr

  return bufnr
end

local function render_lines(session)
  local lines = {
    'sift.nvim',
    '',
    'repo: ' .. session.repo_root,
    'session: ' .. session.id,
    'status: ' .. session.status,
    'baseline: ' .. (session.baseline_ref or 'pending'),
    '',
    'Commands: :SiftPrompt  :SiftRefresh  :SiftStop  :SiftPanelToggle',
    '',
  }

  for _, entry in ipairs(session.transcript or {}) do
    table.insert(lines, string.format('[%s] %s', entry.timestamp, kind_label[entry.kind] or entry.kind))

    for _, line in ipairs(split_text(entry.text)) do
      table.insert(lines, '  ' .. line)
    end

    table.insert(lines, '')
  end

  return lines
end

function M.render(session)
  local bufnr = ensure_buffer(session)
  local view = nil

  if vim.api.nvim_get_current_buf() == bufnr then
    view = vim.fn.winsaveview()
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, render_lines(session))
  vim.bo[bufnr].modifiable = false

  if view then
    vim.fn.winrestview(view)
  end
end

function M.open(session)
  local panel = ensure_panel_table(session)
  local bufnr = ensure_buffer(session)

  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    vim.api.nvim_set_current_win(panel.winid)
    M.render(session)
    return panel.winid
  end

  local height = config.get().panel.height

  vim.cmd(string.format('botright %dsplit', height))

  panel.winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel.winid, bufnr)
  vim.wo[panel.winid].number = false
  vim.wo[panel.winid].relativenumber = false
  vim.wo[panel.winid].signcolumn = 'no'
  vim.wo[panel.winid].winfixheight = true
  vim.wo[panel.winid].wrap = false

  M.render(session)

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
    kind = kind,
    text = text,
    timestamp = os.date('%H:%M:%S'),
  })

  M.render(session)
end

return M
