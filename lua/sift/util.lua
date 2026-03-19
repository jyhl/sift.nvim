local M = {}
local unpack_fn = table.unpack or unpack

local function make_line_accumulator(on_line)
  local partial = ''

  local function push(data)
    if type(data) ~= 'table' or vim.tbl_isempty(data) then
      return
    end

    for index, chunk in ipairs(data) do
      local line = chunk

      if index == 1 then
        line = partial .. line
      end

      if index == #data and chunk ~= '' then
        partial = line
      else
        partial = ''
        on_line(line)
      end
    end
  end

  local function flush()
    if partial ~= '' then
      on_line(partial)
      partial = ''
    end
  end

  return {
    push = push,
    flush = flush,
  }
end

function M.trim(value)
  if value == nil then
    return ''
  end

  return (tostring(value):gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.is_blank(value)
  return M.trim(value) == ''
end

function M.schedule(fn, ...)
  local args = { ... }

  vim.schedule(function()
    fn(unpack_fn(args))
  end)
end

function M.lines(text)
  if type(text) ~= 'string' or text == '' then
    return {}
  end

  return vim.split(text, '\n', { plain = true })
end

function M.session_id()
  local millis = math.floor(vim.loop.hrtime() / 1000000)
  local random = math.random(0, 0xFFFFFF)
  return string.format('%d-%06x', millis, random)
end

function M.toml_literal(value)
  local value_type = type(value)

  if value_type == 'string' then
    return vim.inspect(value)
  end

  if value_type == 'boolean' or value_type == 'number' then
    return tostring(value)
  end

  error(string.format('unsupported TOML literal type: %s', value_type))
end

function M.jobstart(spec)
  vim.validate({
    spec = { spec, 'table' },
    ['spec.cmd'] = { spec.cmd, 'table' },
  })

  local stdout = make_line_accumulator(function(line)
    if spec.on_stdout_line then
      spec.on_stdout_line(line)
    end
  end)

  local stderr = make_line_accumulator(function(line)
    if spec.on_stderr_line then
      spec.on_stderr_line(line)
    end
  end)

  local options = {
    cwd = spec.cwd,
    env = spec.env,
    stderr_buffered = false,
    stdout_buffered = false,
    on_stdout = function(_, data)
      stdout.push(data)
    end,
    on_stderr = function(_, data)
      stderr.push(data)
    end,
    on_exit = function(_, code, signal)
      stdout.flush()
      stderr.flush()

      if spec.on_exit then
        M.schedule(spec.on_exit, code, signal)
      end
    end,
  }

  local job_id = vim.fn.jobstart(spec.cmd, options)

  if job_id <= 0 then
    local error_map = {
      [-1] = 'failed to start job',
      [0] = 'invalid job arguments',
    }

    return nil, error_map[job_id] or string.format('jobstart failed with code %d', job_id)
  end

  if type(spec.stdin) == 'string' then
    vim.fn.chansend(job_id, spec.stdin)
    vim.fn.chanclose(job_id, 'stdin')
  end

  return job_id
end

return M
