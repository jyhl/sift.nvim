local M = {}

local parser = require('sift.diff.parser')

function M.parse(lines)
  return parser.parse(lines)
end

return M
