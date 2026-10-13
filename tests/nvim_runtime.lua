-- nvim --headless -u NONE -i NONE -l tests/nvim_runtime.lua
local script = debug.getinfo(1, 'S').source:sub(2)
local root = script:match('^(.*)/tests/nvim_runtime%.lua$') or '.'
vim.opt.runtimepath:prepend(root)
local runtime = require('rivet.runtime')
-- Load a second copy without vim in scope to exercise the test(1) fallback.
local load_shell = assert(loadfile(root .. '/lua/rivet/runtime.lua'))
local editor = _G.vim
_G.vim = nil
local shell = load_shell()
_G.vim = editor

local dir = assert(vim.uv.fs_realpath(vim.uv.os_tmpdir()))
dir = dir .. '/rivet-runtime-' .. vim.uv.getpid()
assert(vim.fn.mkdir(dir, 'p') == 1)
vim.fn.writefile({}, dir .. '/file')
vim.fn.writefile({ '#!/bin/sh' }, dir .. '/tool')
assert(vim.uv.fs_chmod(dir .. '/tool', tonumber('755', 8)))
assert(vim.uv.fs_symlink(dir .. '/missing', dir .. '/broken'))
assert(vim.uv.fs_symlink(dir, dir .. '/linked_dir'))

for _, path in ipairs({ 'file', 'tool', 'broken', 'linked_dir', 'absent' }) do
  path = dir .. '/' .. path
  for _, name in ipairs({ 'exists', 'is_dir', 'is_link' }) do
    assert(runtime[name](path) == shell[name](path), name .. ' differs for ' .. path)
  end
  assert(runtime.executable(path) == shell.executable(path), 'executable differs for ' .. path)
end
assert(runtime.exists(dir .. '/broken') and not runtime.exists(dir .. '/absent'))
assert(runtime.is_dir(dir .. '/linked_dir') and runtime.is_link(dir .. '/linked_dir'))
assert(runtime.executable(dir .. '/tool') == dir .. '/tool')
assert(not runtime.executable(dir .. '/file'))
assert(runtime.executable('sh') == shell.executable('sh'))
assert(not runtime.executable('rivet-no-such-tool'))
assert(runtime.cwd() == shell.cwd(), 'cwd differs')

vim.fn.delete(dir, 'rf')
print('Runtime filesystem checks passed')
vim.cmd('qa!')
