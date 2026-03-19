local M = {
  sessions = {},
  namespaces = {
    inline = vim.api.nvim_create_namespace('sift.inline'),
    signs = vim.api.nvim_create_namespace('sift.signs'),
  },
}

function M.get_session(repo_root)
  return M.sessions[repo_root]
end

function M.set_session(repo_root, session)
  M.sessions[repo_root] = session
  return session
end

function M.remove_session(repo_root)
  local session = M.sessions[repo_root]
  M.sessions[repo_root] = nil
  return session
end

function M.all_sessions()
  return M.sessions
end

return M
