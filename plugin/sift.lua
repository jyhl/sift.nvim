if vim.g.loaded_sift_nvim == 1 then
  return
end

vim.g.loaded_sift_nvim = 1

require('sift')._bootstrap()
