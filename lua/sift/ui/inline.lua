local M = {}

local hunk_util = require('sift.diff.hunk')
local state = require('sift.state')

local function highlight_for_hunk(hunk)
  if hunk.type == 'add' then
    return 'DiffAdd'
  end

  if hunk.type == 'delete' then
    return 'DiffDelete'
  end

  return 'DiffChange'
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, state.namespaces.inline, 0, -1)
  end
end

function M.render(bufnr, hunks)
  M.clear(bufnr)

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  for _, hunk in ipairs(hunks or {}) do
    local start_line = hunk_util.anchor(hunk)
    local end_line = hunk_util.finish(hunk)
    local hl = highlight_for_hunk(hunk)

    for lnum = start_line, end_line do
      vim.api.nvim_buf_set_extmark(bufnr, state.namespaces.inline, lnum - 1, 0, {
        hl_eol = true,
        line_hl_group = hl,
        priority = 150,
      })
    end

    vim.api.nvim_buf_set_extmark(bufnr, state.namespaces.inline, start_line - 1, 0, {
      virt_text = { { ' pending', 'Comment' } },
      virt_text_pos = 'eol',
      priority = 151,
    })
  end
end

return M
