local M = {}

local hunk_util = require('sift.diff.hunk')

local defined = false
local group = 'sift_pending_review'

local function ensure_defined()
  if defined then
    return
  end

  defined = true

  vim.fn.sign_define('SiftPendingAdd', {
    text = '+',
    texthl = 'DiffAdd',
  })
  vim.fn.sign_define('SiftPendingChange', {
    text = '~',
    texthl = 'DiffChange',
  })
  vim.fn.sign_define('SiftPendingDelete', {
    text = '_',
    texthl = 'DiffDelete',
  })
end

local function sign_name(hunk)
  if hunk.type == 'add' then
    return 'SiftPendingAdd'
  end

  if hunk.type == 'delete' then
    return 'SiftPendingDelete'
  end

  return 'SiftPendingChange'
end

function M.clear(bufnr)
  vim.fn.sign_unplace(group, { buffer = bufnr })
end

function M.render(bufnr, hunks)
  ensure_defined()
  M.clear(bufnr)

  for _, hunk in ipairs(hunks or {}) do
    vim.fn.sign_place(0, group, sign_name(hunk), bufnr, {
      lnum = hunk_util.anchor(hunk),
      priority = 25,
    })
  end
end

return M
