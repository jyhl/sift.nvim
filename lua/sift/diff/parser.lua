local M = {}

local function parse_path(marker)
  if marker == '/dev/null' then
    return nil
  end

  return marker:gsub('^[ab]/', '')
end

local function parse_count(value)
  if value == '' or value == nil then
    return 1
  end

  return tonumber(value)
end

local function classify_hunk(hunk)
  if hunk.removed.count == 0 then
    return 'add'
  end

  if hunk.added.count == 0 then
    return 'delete'
  end

  return 'change'
end

function M.parse(lines)
  local files = {}
  local current_file = nil
  local current_hunk = nil

  local function finish_hunk()
    if not current_file or not current_hunk then
      return
    end

    current_hunk.type = classify_hunk(current_hunk)
    current_hunk.index = #current_file.hunks + 1
    table.insert(current_file.hunks, current_hunk)
    current_hunk = nil
  end

  local function finish_file()
    finish_hunk()

    if not current_file then
      return
    end

    current_file.path = current_file.new_path or current_file.old_path

    if current_file.path and #current_file.hunks > 0 then
      table.insert(files, current_file)
    end

    current_file = nil
  end

  for _, line in ipairs(lines or {}) do
    if vim.startswith(line, 'diff --git ') then
      finish_file()

      local old_path, new_path = line:match('^diff %-%-git a/(.-) b/(.-)$')

      current_file = {
        header = { line },
        hunks = {},
        old_path = old_path,
        new_path = new_path,
        path = new_path or old_path,
        status = 'modified',
      }
    elseif current_file then
      local removed_start, removed_count, added_start, added_count, context =
        line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@(.*)$')

      if removed_start then
        finish_hunk()

        current_hunk = {
          header = line,
          lines = {},
          removed = {
            start = tonumber(removed_start),
            count = parse_count(removed_count),
          },
          added = {
            start = tonumber(added_start),
            count = parse_count(added_count),
          },
          context = vim.trim(context or ''),
        }
      elseif current_hunk then
        table.insert(current_hunk.lines, line)
      else
        table.insert(current_file.header, line)

        local old_marker = line:match('^%-%-%- (.+)$')
        if old_marker then
          current_file.old_path = parse_path(old_marker)
        end

        local new_marker = line:match('^%+%+%+ (.+)$')
        if new_marker then
          current_file.new_path = parse_path(new_marker)
        end

        local rename_from = line:match('^rename from (.+)$')
        if rename_from then
          current_file.old_path = rename_from
          current_file.status = 'rename'
        end

        local rename_to = line:match('^rename to (.+)$')
        if rename_to then
          current_file.new_path = rename_to
          current_file.status = 'rename'
        end

        if vim.startswith(line, 'new file mode ') then
          current_file.status = 'add'
        elseif vim.startswith(line, 'deleted file mode ') then
          current_file.status = 'delete'
        end
      end
    end
  end

  finish_file()

  return files
end

return M
