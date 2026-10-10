-- Local editor preferences, stored separately for each project.
local M = {}
local function filename(root)
  return vim.fn.stdpath('state') .. '/rivet/tasks/' .. vim.fn.sha256(root) .. '.json'
end

function M.load(root)
  local ok, value = pcall(function()
    local path = filename(root)
    if vim.fn.filereadable(path) == 0 then
      path = path:gsub('/rivet/tasks/', '/outset/tasks/')
    end
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  end)
  if not ok or type(value) ~= 'table' or value.root ~= root then
    return {}
  end
  local out = {}
  for _, key in ipairs({ 'preset', 'build_preset', 'test_preset', 'build_target' }) do
    if type(value[key]) == 'string' and not value[key]:find('[%z\r\n]') then
      out[key] = value[key]
    end
  end
  if type(value.target) == 'string' then
    out.target = value.target
  end
  local tasks = {}
  for _, name in ipairs({
    'configure',
    'build',
    'check',
    'test',
    'run',
    'format',
    'lint',
    'package',
    'xcode',
    'benchmark',
    'profile',
    'submit',
    'status',
    'cancel',
  }) do
    tasks[name] = true
  end
  if type(value.last_task) == 'string' and tasks[value.last_task] then
    out.last_task = value.last_task
  end
  return out
end

function M.save(root, state)
  local path = filename(root)
  local temporary = path .. '.' .. vim.fn.getpid() .. '.tmp'
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    local value = vim.tbl_extend('force', state, { root = root })
    assert(
      vim.fn.writefile({ vim.json.encode(value) }, temporary) == 0,
      'Could not write task choices'
    )
    assert((vim.uv or vim.loop).fs_rename(temporary, path))
  end)
  if not ok then
    pcall(vim.fn.delete, temporary)
    require('rivet.ui').notify(
      'Could not remember task choices: ' .. tostring(err),
      vim.log.levels.WARN
    )
  end
end

return M
