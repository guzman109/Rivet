-- nvim --headless -u NONE -i NONE -l tests/nvim_headers.lua
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/nvim_headers%.lua$') or '.'
vim.opt.runtimepath:prepend(root)
local temporary = vim.fn.tempname()
vim.fn.mkdir(temporary, 'p')
temporary = assert(vim.uv.fs_realpath(temporary))
local path = temporary .. '/main.cpp'
vim.fn.writefile({ '// Existing notice', '', 'int main() { return 0; }' }, path)
vim.cmd.edit(vim.fn.fnameescape(path))
vim.bo.filetype = 'cpp'
local buf = vim.api.nvim_get_current_buf()
local function content()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end
local original = content()
local spec = {
  name = 'engine',
  comment_header = { style = 'xcode', author = 'Ada Lovelace', created = '2026-10-09' },
}
local planned, applied
package.loaded['rivet.project'] = {
  root = function(start)
    return start == temporary and temporary or nil
  end,
  load = function()
    return spec
  end,
  plan = function(value, destination)
    planned = { spec = value, root = destination, files = {} }
    return planned
  end,
  apply = function()
    applied = true
  end,
}
local ui = require('rivet.ui')
local errors, fields, reviews = {}, {}, {}
ui.notify = function(message, level)
  if level == vim.log.levels.ERROR then
    errors[#errors + 1] = message
  end
end
local style = 'xcode'
local input_count, keep = 0, false
vim.ui.input = function(options, callback)
  input_count = input_count + 1
  fields[#fields + 1] = options
  callback(options.default)
end
vim.ui.select = function(items, _, callback)
  callback(items[keep and 2 or 1])
end
ui.select_preview = function(title, items, callback, options)
  if title == 'File comment header' then
    assert(
      input_count == #require('rivet.headers').fields,
      'styles appeared before user details were collected'
    )
    for _, item in ipairs(items) do
      if item.id == style then
        assert(item.preview:find('main.cpp', 1, true) or style == 'none')
        return callback(item)
      end
    end
    error('missing style')
  end
  assert(title == 'Review file header' and options.review)
  reviews[#reviews + 1] = { accept = callback, items = items }
end
local rivet = require('rivet')
rivet.setup()
assert(vim.fn.exists(':RivetHeader') == 2 and vim.fn.exists(':RivetHeaderDefaults') == 2)
rivet.header()
assert(content() == original and not vim.bo[buf].modified, 'header changed before approval')
assert(reviews[1].items[1].preview:find('-// Existing notice', 1, true))
reviews[1].accept()
assert(content():find('Author: Ada Lovelace', 1, true) and vim.bo[buf].modified)
assert(
  table.concat(vim.fn.readfile(path), '\n') == original,
  'header edit saved without user write'
)
vim.cmd('normal! u')
assert(content() == original, 'one undo did not restore the file')

-- Replacing a stale preview must not discard a buffer edit made while reviewing.
input_count = 0
rivet.header()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '// User edit after preview' })
local changed = content()
reviews[2].accept()
assert(content() == changed and #errors == 1, 'stale review discarded a user edit')

-- Canceling the review leaves the file alone. Prepending explicitly retains an
-- unrecognized notice; selecting no header can remove the initial comment only.
input_count, keep, style = 0, true, 'doc'
rivet.header()
assert(content() == changed)
reviews[3].accept()
assert(
  content():find(' * @file main.cpp', 1, true) and content():find('// Existing notice', 1, true)
)
input_count, keep, style = 0, false, 'none'
rivet.header()
reviews[4].accept()
assert(content() == changed, 'removing the prepended header altered the existing notice or source')
local review_count = #reviews
vim.ui.input = function(_, callback)
  callback(nil)
end
rivet.header()
assert(
  #reviews == review_count and content() == changed,
  'canceling a field opened a review or changed the buffer'
)

-- The creation wizard collects the same details, previews them, and waits for
-- the ordinary whole-project approval before writing anything.
input_count, style = 0, 'xcode'
vim.ui.input = function(options, callback)
  if options.prompt:match('^Project name:') then
    callback('engine')
  elseif options.prompt:match('^Project directory:') then
    callback(temporary .. '/new-project')
  elseif options.prompt:match('^C%+%+ compiler') then
    callback((vim.fn.exepath('clang++') ~= '' and vim.fn.exepath('clang++') or '/usr/bin/c++'))
  else
    input_count = input_count + 1
    callback(options.prompt:match('^Author') and 'Grace Hopper' or options.default)
  end
end
vim.ui.select = function(items, options, callback)
  if options.prompt:match('^File comment headers:') then
    for _, item in ipairs(items) do
      if item == 'Personalize and preview styles' then
        return callback(item)
      end
    end
    error('missing header personalization choice')
  end
  callback(items[1])
end
local previews = ui.select_preview
ui.select_preview = function(title, items, callback, options)
  if title == 'File comment header' then
    for _, item in ipairs(items) do
      if item.id == 'xcode' then
        assert(item.preview:find('Author: Grace Hopper', 1, true))
      end
    end
    return previews(title, items, callback, options)
  end
  callback(items[1])
end
local accept_project
ui.review = function(_, plan, callback)
  assert(
    plan.spec.comment_header.author == 'Grace Hopper' and plan.spec.comment_header.style == 'xcode'
  )
  accept_project = callback
end
rivet.new()
assert(planned and not applied and accept_project, 'creation did not wait for project approval')
accept_project()
assert(applied)
vim.fn.delete(temporary, 'rf')
print('Header wizard, preview, cancellation, undo, and stale-buffer checks passed')
vim.cmd('qa!')
