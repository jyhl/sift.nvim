local tracker = require('sift.review.tracker')

local M = {}

function M.hunk(session, hunk)
  return tracker.accept_hunk(session, hunk)
end

function M.file(session, relative_path)
  return tracker.accept_file(session, relative_path)
end

function M.all(session)
  return tracker.accept_all(session)
end

return M
