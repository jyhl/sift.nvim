local commands = require('sift.commands')
local config = require('sift.config')
local review = require('sift.review')
local session = require('sift.session')

local M = {}

function M._bootstrap()
  session.setup()
  review.setup()
  commands.setup()
end

function M.setup(opts)
  config.setup(opts)
  session.setup()
  review.setup()
  commands.setup()
end

function M.start()
  session.start()
end

function M.stop()
  session.stop()
end

function M.prompt(text)
  session.prompt(text)
end

function M.panel_toggle()
  session.toggle_panel()
end

function M.refresh()
  session.refresh()
end

function M.accept_hunk()
  session.accept_hunk()
end

function M.reject_hunk()
  session.reject_hunk()
end

function M.accept_file()
  session.accept_file()
end

function M.reject_file()
  session.reject_file()
end

function M.accept_all()
  session.accept_all()
end

function M.reject_all()
  session.reject_all()
end

function M.next_hunk()
  session.next_hunk()
end

function M.prev_hunk()
  session.prev_hunk()
end

return M
