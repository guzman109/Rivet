-- nvim --headless -u NONE -i NONE -l tests/nvim_lifecycle.lua
local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/nvim_lifecycle%.lua$') or '.'
vim.opt.runtimepath:prepend(repo)
vim.o.swapfile = false
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert(vim.uv.fs_realpath(root))
local project, rt = require('rivet.project'), require('rivet.runtime')
project.apply(
  root,
  project.plan({ language = 'cpp', name = 'sample', standard = 17, modules = false }, root)
)
local added = project.file_plan(root, { name = 'extra', kind = 'source' })
project.apply(root, added)
local path
for p in pairs(added.files) do
  if p:match('extra%.cpp$') then
    path = p
  end
end
assert(path)
vim.cmd.edit(vim.fn.fnameescape(root .. '/' .. path))
local buf = vim.api.nvim_get_current_buf()
local moved = 'src/renamed.cpp'
project.apply(root, project.lifecycle_plan(root, { action = 'move', from = path, to = moved }))
assert(vim.api.nvim_buf_get_name(buf) == root .. '/' .. moved, 'Buffer kept the old name')
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '// edit after move' })
vim.api.nvim_buf_call(buf, function()
  vim.cmd.write()
end)
assert(not rt.exists(root .. '/' .. path), 'Saving resurrected the old file')
assert(rt.read(root .. '/' .. moved):find('// edit after move', 1, true))

local removal = project.lifecycle_plan(root, { action = 'remove', from = moved })
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '// unsaved' })
assert(not pcall(project.apply, root, removal), 'Removed an unsaved buffer')
assert(rt.exists(root .. '/' .. moved))
vim.api.nvim_buf_call(buf, function()
  vim.cmd('edit!')
end)
project.apply(root, removal)
assert(not vim.api.nvim_buf_is_valid(buf), 'Removed file retained a writable buffer')

-- Rewrites must refresh clean buffers as well, or the next save undoes them.
local fragment = root .. '/cmake/RivetTargets.cmake'
vim.cmd.edit(vim.fn.fnameescape(fragment))
project.apply(root, project.file_plan(root, { name = 'next_file', kind = 'source' }))
assert(
  table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('next_file.cpp', 1, true)
)
vim.cmd('bwipeout!')
vim.fn.delete(root, 'rf')
print('Lifecycle buffers follow moves, removals, and generated rewrites')
vim.cmd('qa!')
