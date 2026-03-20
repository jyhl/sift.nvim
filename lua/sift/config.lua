local M = {}

local defaults = {
  codex = {
    bin = 'codex',
    sandbox = 'workspace-write',
    model = nil,
    profile = nil,
    extra_args = {},
    config_overrides = {
      model_reasoning_effort = 'medium',
    },
  },
  panel = {
    auto_start = true,
    height = 12,
    position = 'right',
    width = 50,
  },
  logging = {
    notify = false,
    level = vim.log.levels.INFO,
  },
}

local values = vim.deepcopy(defaults)

function M.defaults()
  return vim.deepcopy(defaults)
end

function M.setup(opts)
  values = vim.tbl_deep_extend('force', M.defaults(), opts or {})
  return values
end

function M.get()
  return values
end

return M
