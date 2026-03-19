local config = require('sift.config')
local util = require('sift.util')

local M = {}

local function build_command(session, prompt)
  local opts = config.get().codex
  local cmd = {
    opts.bin,
    'exec',
    '--json',
    '-C',
    session.repo_root,
    '--sandbox',
    opts.sandbox,
  }

  if opts.profile then
    vim.list_extend(cmd, { '--profile', opts.profile })
  end

  if opts.model then
    vim.list_extend(cmd, { '--model', opts.model })
  end

  for key, value in pairs(opts.config_overrides or {}) do
    table.insert(cmd, '--config')
    table.insert(cmd, string.format('%s=%s', key, util.toml_literal(value)))
  end

  for _, arg in ipairs(opts.extra_args or {}) do
    table.insert(cmd, arg)
  end

  table.insert(cmd, prompt)

  return cmd
end

local function parse_json_line(line)
  if util.is_blank(line) then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, line)

  if ok and type(decoded) == 'table' then
    return decoded
  end

  return nil
end

function M.start(session, prompt, handlers)
  local stdout = {}
  local stderr = {}

  local job_id, err = util.jobstart({
    cmd = build_command(session, prompt),
    cwd = session.repo_root,
    on_stdout_line = function(line)
      table.insert(stdout, line)

      local event = parse_json_line(line)

      if event then
        if handlers.on_event then
          handlers.on_event(event)
        end
      elseif handlers.on_stdout_line then
        handlers.on_stdout_line(line)
      end
    end,
    on_stderr_line = function(line)
      table.insert(stderr, line)

      if handlers.on_stderr_line then
        handlers.on_stderr_line(line)
      end
    end,
    on_exit = function(code, signal)
      if handlers.on_exit then
        handlers.on_exit(code, signal, stdout, stderr)
      end
    end,
  })

  if not job_id then
    return nil, err
  end

  return job_id
end

return M
