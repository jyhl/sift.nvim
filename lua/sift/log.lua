local config = require('sift.config')
local util = require('sift.util')

local M = {}

local function notify(level, message)
  local opts = config.get().logging

  if not opts.notify or level < opts.level then
    return
  end

  util.schedule(vim.notify, message, level, { title = 'sift.nvim' })
end

function M.debug(message)
  notify(vim.log.levels.DEBUG, message)
end

function M.info(message)
  notify(vim.log.levels.INFO, message)
end

function M.warn(message)
  notify(vim.log.levels.WARN, message)
end

function M.error(message)
  notify(vim.log.levels.ERROR, message)
end

return M
