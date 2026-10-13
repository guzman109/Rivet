if vim.g.loaded_rivet then
  return
end
vim.g.loaded_rivet = true
require('rivet').setup()
