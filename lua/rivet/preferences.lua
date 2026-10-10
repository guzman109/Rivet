-- Opt-in local profiles and identity; never inferred from Git or the OS account.
local M = {}
local function path()
  return vim.fn.stdpath('state') .. '/rivet/preferences.json'
end
function M.load()
  local source = path()
  if vim.fn.filereadable(source) == 0 then
    source = source:gsub('/rivet/preferences.json$', '/outset/preferences.json')
  end
  if vim.fn.filereadable(source) == 0 then
    return { profiles = {} }
  end
  local ok, value = pcall(vim.json.decode, table.concat(vim.fn.readfile(source), '\n'))
  assert(
    ok and type(value) == 'table' and type(value.profiles) == 'table',
    'Invalid Rivet preferences: ' .. path()
  )
  return value
end
function M.save(value)
  local filename = path()
  vim.fn.mkdir(vim.fn.fnamemodify(filename, ':h'), 'p')
  local temporary = filename .. '.' .. vim.fn.getpid() .. '.tmp'
  assert(
    vim.fn.writefile({ vim.json.encode(value) }, temporary) == 0,
    'Cannot save Rivet preferences'
  )
  local ok, err = (vim.uv or vim.loop).fs_rename(temporary, filename)
  if not ok then
    vim.fn.delete(temporary)
    error(err)
  end
end
return M
