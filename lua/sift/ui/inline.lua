local M = {}

local hunk_util = require('sift.diff.hunk')
local state = require('sift.state')

local function highlight_for_hunk(hunk)
  if hunk.type == 'delete' then
    return 'DiffDelete'
  end

  return 'DiffAdd'
end

local function preview_lines_for_hunk(hunk)
  local removed = {}

  for _, line in ipairs(hunk.lines or {}) do
    if vim.startswith(line, '-') then
      table.insert(removed, { { '- ' .. line:sub(2), 'DiffDelete' } })
    end
  end

  return removed
end

local function added_ranges_for_hunk(hunk)
  local ranges = {}
  local current_range = nil
  local lnum = hunk.added.start

  local function finish_range()
    if current_range then
      table.insert(ranges, current_range)
      current_range = nil
    end
  end

  for _, line in ipairs(hunk.lines or {}) do
    local prefix = line:sub(1, 1)

    if prefix == '+' then
      local line_number = math.max(lnum, 1)

      if not current_range then
        current_range = {
          start = line_number,
          finish = line_number,
        }
      else
        current_range.finish = line_number
      end

      lnum = lnum + 1
    else
      finish_range()

      if prefix == ' ' then
        lnum = lnum + 1
      end
    end
  end

  finish_range()

  return ranges
end

local function marker_line_for_hunk(hunk, ranges)
  if ranges[1] then
    return ranges[1].start
  end

  return hunk_util.anchor(hunk)
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
    local added_ranges = added_ranges_for_hunk(hunk)
    local marker_line = marker_line_for_hunk(hunk, added_ranges)
    local hl = highlight_for_hunk(hunk)

    for _, range in ipairs(added_ranges) do
      for lnum = range.start, range.finish do
        vim.api.nvim_buf_set_extmark(bufnr, state.namespaces.inline, lnum - 1, 0, {
          hl_eol = true,
          line_hl_group = hl,
          priority = 150,
        })
      end
    end

    local preview_lines = preview_lines_for_hunk(hunk)
    if not vim.tbl_isempty(preview_lines) then
      vim.api.nvim_buf_set_extmark(bufnr, state.namespaces.inline, marker_line - 1, 0, {
        priority = 149,
        virt_lines = preview_lines,
        virt_lines_above = true,
      })
    end

    vim.api.nvim_buf_set_extmark(bufnr, state.namespaces.inline, marker_line - 1, 0, {
      virt_text = { { ' pending', 'Comment' } },
      virt_text_pos = 'eol',
      priority = 151,
    })
  end
end

return M
