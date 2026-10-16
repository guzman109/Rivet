-- nvim --headless -u NONE -i NONE -l tests/nvim_cli_install.lua
local root = vim.fn.fnamemodify('.', ':p')
vim.opt.runtimepath:prepend(root)
require('rivet').setup()
local messages = {}
require('rivet.ui').notify = function(message)
  messages[#messages + 1] = message
end
local temp = vim.fn.tempname()
local directory = temp .. '/bin with spaces'
local install = require('rivet').install_cli
local link = install(directory)
assert(vim.uv.fs_lstat(link).type == 'link')
assert(messages[#messages]:find('Add this directory', 1, true))
assert(install(directory) == link, 'install should be idempotent')
local result = vim.system({ link, '--version' }, { cwd = temp, text = true }):wait()
assert(result.code == 0, result.stderr)
assert(result.stdout:find('Rivet.nvim', 1, true))
assert(vim.uv.fs_unlink(link))
vim.fn.writefile({ 'keep me' }, link)
assert(not pcall(install, directory), 'must preserve existing files')
assert(vim.fn.readfile(link)[1] == 'keep me')
assert(vim.uv.fs_unlink(link))
assert(vim.uv.fs_symlink(temp .. '/missing', link))
assert(not pcall(install, directory), 'must preserve unrelated broken links')
assert(vim.uv.fs_readlink(link) == temp .. '/missing')
assert(vim.api.nvim_get_commands({}).RivetInstallCLI)
assert(vim.tbl_contains(vim.fn.getcompletion('Rivet ', 'cmdline'), 'install-cli'))
vim.fn.delete(temp, 'rf')
print('CLI install checks passed')
