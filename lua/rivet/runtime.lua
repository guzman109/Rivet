-- POSIX adapter: argv are always shell-quoted on plain Lua; Neovim uses vim.system.
local M = {}
-- Inside Neovim, filesystem checks use libuv instead of spawning test(1).
local uv = rawget(_G, 'vim') and (vim.uv or vim.loop)
local function stat_type(path, follow)
  local stat = (follow and uv.fs_stat or uv.fs_lstat)(path)
  return stat and stat.type
end
local function executable_file(path)
  if uv then
    return stat_type(path, true) == 'file' and uv.fs_access(path, 'X') == true
  end
  return M.run({ 'test', '-f', path }).code == 0 and M.run({ 'test', '-x', path }).code == 0
end
function M.quote(value)
  assert(type(value) == 'string' and not value:find('%z'), 'Invalid process argument')
  return "'" .. value:gsub("'", "'\\''") .. "'"
end
function M.join(a, b)
  return a:gsub('/+$', '') .. '/' .. b:gsub('^/+', '')
end
function M.dirname(path)
  local parent = path:match('^(.*)/[^/]+/?$')
  return (parent == '' or path == '/') and '/' or parent or '.'
end
function M.read(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local s = f:read('*a')
  f:close()
  return s
end
local function status(a, _, c)
  if a == true then
    return 0
  end
  if type(a) == 'number' then
    return a > 255 and math.floor(a / 256) or a
  end
  return c or 1
end
function M.run(argv, opts)
  opts = opts or {}
  if rawget(_G, 'vim') and vim.system then
    local result =
      vim.system(argv, { cwd = opts.cwd, stdin = opts.stdin, text = true }):wait(opts.timeout)
    return { code = result.code, stdout = result.stdout or '', stderr = result.stderr or '' }
  end
  assert(package.config:sub(1, 1) == '/', 'Standalone CLI currently supports macOS/Linux')
  local args = {}
  for _, arg in ipairs(argv) do
    args[#args + 1] = M.quote(arg)
  end
  local out, err, exit_status, input = os.tmpname(), os.tmpname(), os.tmpname(), nil
  local command = table.concat(args, ' ')
  if opts.cwd then
    command = 'cd ' .. M.quote(opts.cwd) .. ' && ' .. command
  end
  if opts.stdin then
    input = os.tmpname()
    local f = assert(io.open(input, 'wb'))
    f:write(opts.stdin)
    f:close()
    command = command .. ' < ' .. M.quote(input)
  end
  -- Lua's os.execute can mistake a stale libc errno for the child's nonzero
  -- exit status (for example, ENOSYS after clone3 falls back in a container).
  -- Record the POSIX shell's status separately; do not rerun the command.
  local wrapper = '( '
    .. command
    .. ' ) > '
    .. M.quote(out)
    .. ' 2> '
    .. M.quote(err)
    .. '; rivet_process_status=$?; printf "%s\\n" "$rivet_process_status" > '
    .. M.quote(exit_status)
  local wrapper_code = status(os.execute(wrapper))
  local code = tonumber(M.read(exit_status) or '')
  local result = { code = code, stdout = M.read(out) or '', stderr = M.read(err) or '' }
  if not code then
    result.code = wrapper_code ~= 0 and wrapper_code or 1
    result.stderr = result.stderr .. 'Could not capture process exit status.\n'
  end
  os.remove(out)
  os.remove(err)
  os.remove(exit_status)
  if input then
    os.remove(input)
  end
  return result
end
function M.cwd()
  if uv then
    local cwd = uv.cwd()
    return assert(cwd and uv.fs_realpath(cwd), 'Cannot resolve cwd')
  end
  local path = M.run({ 'pwd', '-P' }).stdout:match('([^\r\n]+)')
  assert(path, 'Cannot resolve cwd')
  return path
end
function M.absolute(path)
  assert(type(path) == 'string' and path ~= '' and not path:find('[%z\r\n]'), 'Invalid root path')
  if path == '~' or path:sub(1, 2) == '~/' then
    path = assert(os.getenv('HOME'), 'HOME missing') .. path:sub(2)
  end
  if path:sub(1, 1) ~= '/' then
    path = M.join(M.cwd(), path)
  end
  local parts = {}
  for p in path:gmatch('[^/]+') do
    if p == '..' then
      table.remove(parts)
    elseif p ~= '.' then
      parts[#parts + 1] = p
    end
  end
  return '/' .. table.concat(parts, '/')
end
function M.exists(path)
  if uv then
    return stat_type(path, false) ~= nil
  end
  return M.run({ 'test', '-e', path }).code == 0 or M.run({ 'test', '-L', path }).code == 0
end
function M.is_dir(path)
  if uv then
    return stat_type(path, true) == 'directory'
  end
  return M.run({ 'test', '-d', path }).code == 0
end
function M.is_link(path)
  if uv then
    return stat_type(path, false) == 'link'
  end
  return M.run({ 'test', '-L', path }).code == 0
end
function M.mkdir(path)
  local r = M.run({ 'mkdir', '-p', path })
  assert(r.code == 0, r.stderr)
end
function M.write(path, text)
  local f, err = io.open(path, 'wb')
  assert(f, err)
  local ok, why = f:write(text)
  local closed, close_error = f:close()
  assert(ok and closed, why or close_error or 'Write failed')
end
function M.mode(path)
  if uv then
    local stat, err = uv.fs_stat(path)
    assert(stat, err)
    return stat.mode % 4096
  end
  local result = M.run({ 'stat', '-c', '%a', path })
  if result.code ~= 0 then
    result = M.run({ 'stat', '-f', '%Lp', path })
  end
  assert(result.code == 0, result.stderr)
  return assert(tonumber(result.stdout:match('^%s*([0-7]+)%s*$'), 8), 'Invalid file mode')
end
function M.chmod(path, mode)
  if uv then
    local ok, err = uv.fs_chmod(path, mode)
    assert(ok, err)
  else
    local result = M.run({ 'chmod', string.format('%o', mode), path })
    assert(result.code == 0, result.stderr)
  end
end
function M.safe_relative(path)
  assert(
    type(path) == 'string' and path ~= '' and not path:find('[%z\r\n\\]') and path:sub(1, 1) ~= '/',
    'Invalid relative path'
  )
  for p in path:gmatch('[^/]+') do
    assert(p ~= '..' and p ~= '.', 'Path traversal is not allowed')
  end
  return path
end
function M.confined(root, relative)
  M.safe_relative(relative)
  local path = root
  assert(not M.is_link(root), 'Project root must not be a symlink')
  for part in relative:gmatch('[^/]+') do
    path = M.join(path, part)
    assert(not M.is_link(path), 'Refusing symlink within project: ' .. path)
  end
  return path
end
function M.executable(name)
  if name:find('/', 1, true) then
    name = M.absolute(name)
    return executable_file(name) and name or false
  end
  for dir in (os.getenv('PATH') or ''):gmatch('[^:]+') do
    local path = M.join(dir, name)
    if executable_file(path) then
      return M.absolute(path)
    end
  end
  return false
end
function M.detect_tools()
  local result = {}
  local llvm = {
    clangxx = 'clang++',
    clangd = 'clangd',
    clang_format = 'clang-format',
    clang_tidy = 'clang-tidy',
    clang_scan_deps = 'clang-scan-deps',
  }
  for key, name in pairs(llvm) do
    result[key] = M.executable('/opt/homebrew/opt/llvm/bin/' .. name)
      or M.executable('/usr/local/opt/llvm/bin/' .. name)
      or M.executable(name)
  end
  for _, name in ipairs({
    'cmake',
    'ninja',
    'make',
    'neocmakelsp',
    'gersemi',
    'lua',
    'luajit',
    'just',
    'git',
  }) do
    result[name] = M.executable(name)
  end
  result.lldb_dap = M.executable('lldb-dap')
    or M.executable('/opt/homebrew/opt/llvm/bin/lldb-dap')
    or M.executable('/usr/local/opt/llvm/bin/lldb-dap')
  if not result.lldb_dap and M.executable('xcrun') then
    local r = M.run({ 'xcrun', '--find', 'lldb-dap' })
    if r.code == 0 then
      result.lldb_dap = M.executable(r.stdout:gsub('%s+$', ''))
    end
  end
  return result
end
return M
