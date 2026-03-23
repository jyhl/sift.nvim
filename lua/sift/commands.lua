local config = require('sift.config')
local session = require('sift.session')
local util = require('sift.util')

local M = {}

local registered = false
local panel_toggle_lhs = nil

local function request_prompt()
  session.focus_prompt()
end

local function expand_lhs(lhs)
  return vim.api.nvim_replace_termcodes(lhs, true, false, true)
end

local function setup_keymaps()
  local lhs = config.get().keymaps and config.get().keymaps.panel_toggle or nil
  local expanded_lhs = lhs and lhs ~= '' and expand_lhs(lhs) or nil

  if panel_toggle_lhs and panel_toggle_lhs ~= expanded_lhs then
    pcall(vim.keymap.del, 'n', panel_toggle_lhs)
    panel_toggle_lhs = nil
  end

  if not expanded_lhs then
    return
  end

  if panel_toggle_lhs == expanded_lhs then
    return
  end

  vim.keymap.set('n', lhs, function()
    session.toggle_panel()
  end, {
    desc = 'Sift panel',
    silent = true,
  })
  panel_toggle_lhs = expanded_lhs
end

function M.setup()
  setup_keymaps()

  if registered then
    return
  end

  registered = true

  vim.api.nvim_create_user_command('SiftStart', function()
    session.start()
  end, { desc = 'Start a sift session' })

  vim.api.nvim_create_user_command('SiftStop', function()
    session.stop()
  end, { desc = 'Stop the current sift session' })

  vim.api.nvim_create_user_command('SiftPrompt', function(command_opts)
    local text = util.trim(command_opts.args)

    if text == '' then
      request_prompt()
      return
    end

    session.prompt(text)
  end, {
    desc = 'Send a prompt or focus the sift panel prompt',
    nargs = '*',
  })

  vim.api.nvim_create_user_command('SiftPanelToggle', function()
    session.toggle_panel()
  end, { desc = 'Toggle the sift panel, starting a session if needed' })

  vim.api.nvim_create_user_command('SiftAcceptHunk', function()
    session.accept_hunk()
  end, { desc = 'Accept the pending sift hunk under the cursor' })

  vim.api.nvim_create_user_command('SiftRejectHunk', function()
    session.reject_hunk()
  end, { desc = 'Reject the pending sift hunk under the cursor' })

  vim.api.nvim_create_user_command('SiftAcceptFile', function()
    session.accept_file()
  end, { desc = 'Accept all pending sift hunks in the current file' })

  vim.api.nvim_create_user_command('SiftRejectFile', function()
    session.reject_file()
  end, { desc = 'Reject all pending sift changes in the current file' })

  vim.api.nvim_create_user_command('SiftAcceptAll', function()
    session.accept_all()
  end, { desc = 'Accept all pending sift hunks in the current session' })

  vim.api.nvim_create_user_command('SiftRejectAll', function()
    session.reject_all()
  end, { desc = 'Reject all pending sift changes in the current session' })

  vim.api.nvim_create_user_command('SiftNextHunk', function()
    session.next_hunk()
  end, { desc = 'Jump to the next pending sift hunk' })

  vim.api.nvim_create_user_command('SiftPrevHunk', function()
    session.prev_hunk()
  end, { desc = 'Jump to the previous pending sift hunk' })

  vim.api.nvim_create_user_command('SiftRefresh', function()
    session.refresh()
  end, { desc = 'Refresh pending sift changes from the session baseline' })
end

return M
