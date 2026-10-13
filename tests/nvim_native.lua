-- nvim --headless -u NONE -i NONE -l tests/nvim_native.lua
local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/nvim_native%.lua$') or '.'
vim.opt.runtimepath:prepend(repo)
vim.o.swapfile = false
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert(vim.uv.fs_realpath(root))
local project = require('rivet.project')
local plan = project.plan({ language = 'python', name = 'sample' }, root)
project.apply(root, plan)
local file = root .. '/src/sample/script.py'
vim.fn.writefile({ '#!/usr/bin/env python3', '# coding: utf-8', 'print(42)' }, file)
vim.cmd.edit(file)
local ui = require('rivet.ui')
ui.input = function(_, default, callback)
  callback(default)
end
ui.select_preview = function(_, items, callback)
  callback(items[1])
end
require('rivet.header_ui').edit(root, {
  language = 'python',
  name = 'sample',
  comment_header = { style = 'compact', author = 'Ada Lovelace' },
}, vim.api.nvim_get_current_buf())
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(text:match('^#!/usr/bin/env python3\n# coding: utf%-8\n#'), 'Python preamble moved')
assert(text:find('# Author: Ada Lovelace', 1, true))
-- Header syntax follows the current file in a mixed-language project.
local lua_file = root .. '/scripts/helper.lua'
vim.fn.mkdir(root .. '/scripts', 'p')
vim.fn.writefile({ '#!/usr/bin/env lua', 'print(42)' }, lua_file)
vim.cmd('new ' .. lua_file)
require('rivet.header_ui').edit(root, {
  language = 'python',
  name = 'sample',
  comment_header = { style = 'compact', author = 'Ada Lovelace' },
}, vim.api.nvim_get_current_buf())
local lua_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(lua_text:match('^#!/usr/bin/env lua\n%-%-'), 'Lua header used host Python syntax')
assert(lua_text:find('Ada Lovelace', 1, true) and lua_text:find('print(42)', 1, true))
vim.cmd('bwipeout!')
-- Review-time filesystem changes may not override modified native editor buffers.
local settings = require('rivet.task_options').plan(root, { args = { '--sample' } })
vim.cmd('new ' .. root .. '/.rivet.local.json')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved' })
assert(not pcall(project.apply, root, settings), 'Unsaved local task options were overwritten')
vim.cmd('bwipeout!')
local diagnostics = require('rivet.native_diagnostics')
local data = {
  reason = 'compiler-message',
  message = {
    level = 'error',
    message = 'bad type',
    rendered = 'error: bad type\n  --> src/lib.rs:4:2\n',
    spans = { { is_primary = true, file_name = 'src/lib.rs', line_start = 4, column_start = 2 } },
  },
}
local encoded = vim.json.encode(data)
local item = diagnostics.parse(encoded, root)
assert(item.lnum == 4 and item.col == 2 and item.filename == root .. '/src/lib.rs')
assert(diagnostics.render(encoded):find('error: bad type', 1, true))
assert(
  diagnostics.render('{"reason":"compiler-artifact","target":{"name":"sample"}}') == 'Built sample'
)
vim.fn.delete(root, 'rf')
print('Native header preambles, option snapshots, and diagnostics checks passed')
vim.cmd('qa!')
