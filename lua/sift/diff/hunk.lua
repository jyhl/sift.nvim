local M = {}

function M.anchor(hunk)
  local line = hunk.added.start

  if line <= 0 then
    line = 1
  end

  return line
end

function M.finish(hunk)
  if hunk.added.count <= 0 then
    return M.anchor(hunk)
  end

  return hunk.added.start + hunk.added.count - 1
end

function M.contains_line(hunk, lnum)
  return lnum >= M.anchor(hunk) and lnum <= M.finish(hunk)
end

function M.compare(left, right)
  if left.path ~= right.path then
    return left.path < right.path
  end

  if M.anchor(left) ~= M.anchor(right) then
    return M.anchor(left) < M.anchor(right)
  end

  return (left.index or 0) < (right.index or 0)
end

return M
