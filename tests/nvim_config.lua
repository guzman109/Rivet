-- nvim --headless -u NONE -i NONE -l tests/nvim_config.lua
local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/nvim_config%.lua$') or '.'
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(repo, ':p'))
vim.o.swapfile = false
local rt = require('rivet.runtime')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert(vim.uv.fs_realpath(root))
rt.write(root .. '/CMakeLists.txt', 'project(sample LANGUAGES CXX)\n')
rt.write(root .. '/.clang-format', '# Team style\nBasedOnStyle: LLVM\n')
vim.cmd.cd(vim.fn.fnameescape(root))
local ui, command = require('rivet.ui'), require('rivet.commands.config')
local prompt, input, notices
notices = {}
ui.notify = function(text)
  notices[#notices + 1] = text
end
ui.select_preview = function(title, items, callback, options)
  prompt = { title = title, items = items, callback = callback, options = options }
end
ui.input = function(title, default, callback)
  input = { title = title, default = default, callback = callback }
end
local function select(label)
  for _, item in ipairs(prompt.items) do
    if item.label == label then
      prompt.callback(item)
      return item
    end
  end
  error('Missing choice: ' .. label)
end
command.config()
assert(#prompt.items == 3 and prompt.items[1].preview:find('review', 1, true))
select('clang-format · source formatting')
local item = select('IndentWidth')
assert(item.preview:find('Number of columns', 1, true))
assert(item.preview:find('# Team style', 1, true))
assert(input.title:find('integer', 1, true))
input.callback('4')
assert(prompt.options.review, 'Mutation bypassed review')
assert(
  not rt.read(root .. '/.clang-format'):find('IndentWidth', 1, true),
  'Preview saved before apply'
)
assert(prompt.items[2].preview:find('IndentWidth: 4', 1, true))
prompt.callback(prompt.items[1])
assert(rt.read(root .. '/.clang-format'):find('IndentWidth: 4', 1, true))
assert(not rt.exists(root .. '/.rivet.json'))
-- Cancel means dropping the review callback: the file stays untouched.
local saved = rt.read(root .. '/.clang-format')
command.config('format')
select('ColumnLimit')
input.callback('100')
assert(prompt.options.review)
assert(rt.read(root .. '/.clang-format') == saved)
-- A modified config buffer must block an otherwise reviewed plan.
vim.cmd.edit(vim.fn.fnameescape(root .. '/.clang-format'))
vim.api.nvim_buf_set_lines(0, -1, -1, false, { '# Unsaved' })
prompt.callback(prompt.items[1])
assert(rt.read(root .. '/.clang-format') == saved)
assert(notices[#notices]:find('unsaved edits', 1, true))
vim.cmd('edit!')
-- Manual option opens the real file and does not replace it with a template.
command.config('format')
select('Open YAML · arbitrary keys and advanced configuration')
assert(vim.api.nvim_buf_get_name(0) == root .. '/.clang-format')
assert(vim.bo.filetype == 'yaml' and rt.read(root .. '/.clang-format') == saved)
-- Enumeration choices explain values before the reviewed change.
command.config('clangd')
select('Diagnostics.ClangTidy.FastCheckFilter')
assert(prompt.items[1].description:find('measured', 1, true))
prompt.callback(prompt.items[1])
assert(prompt.options.review and not rt.exists(root .. '/.clangd'))
prompt.callback(prompt.items[1])
assert(rt.read(root .. '/.clangd'):find("FastCheckFilter: 'Strict'", 1, true))
vim.cmd('bwipeout!')
vim.fn.delete(root, 'rf')
print(
  'Config picker explanations, preview/apply/cancel, manual YAML, and unsaved-buffer guards passed'
)
vim.cmd('qa!')
