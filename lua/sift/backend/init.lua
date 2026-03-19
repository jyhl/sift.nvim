local M = {}

function M.start(session, prompt, handlers)
  return require('sift.backend.codex').start(session, prompt, handlers)
end

return M
