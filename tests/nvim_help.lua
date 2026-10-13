-- nvim --headless -u NONE -i NONE -l tests/nvim_help.lua
local script = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(script:match('^(.*)/tests/nvim_help%.lua$') or '.', ':p')
-- Build tags in a copy so the checkout stays clean; helptags errors on duplicates.
local copy = vim.fn.tempname()
assert(vim.fn.mkdir(copy .. '/doc', 'p') == 1)
local text = vim.fn.readfile(root .. '/doc/rivet.txt')
vim.fn.writefile(text, copy .. '/doc/rivet.txt')
vim.cmd.helptags(copy .. '/doc')
vim.opt.runtimepath:prepend(copy)
for number, line in ipairs(text) do
  assert(vim.fn.strchars(line) <= 78, 'doc/rivet.txt:' .. number .. ' is wider than 78 columns')
  for link in line:gmatch('|([^|%s]+)|') do
    assert(
      pcall(vim.cmd.help, link),
      'doc/rivet.txt:' .. number .. ' links to missing tag ' .. link
    )
  end
end
-- Every registered command has a help entry.
vim.opt.runtimepath:prepend(root)
vim.cmd('runtime plugin/rivet.lua')
for name in pairs(vim.api.nvim_get_commands({})) do
  if name:match('^Rivet') then
    assert(pcall(vim.cmd.help, ':' .. name), 'No help tag for :' .. name)
  end
end
vim.fn.delete(copy, 'rf')
print('Help file checks passed')
vim.cmd('qa!')
