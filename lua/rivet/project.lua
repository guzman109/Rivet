local rt = require('rivet.runtime')
local json = require('rivet.json')
local model = require('rivet.model')
local M = {}
local function canonical(path)
  path = rt.absolute(path)
  if rt.is_dir(path) then
    local r = rt.run({ 'pwd', '-P' }, { cwd = path })
    assert(r.code == 0, r.stderr)
    return r.stdout:gsub('[\r\n]+$', '')
  end
  local parent = rt.dirname(path)
  if parent ~= path then
    return rt.join(canonical(parent), path:match('[^/]+$'))
  end
  return path
end
M.canonical = canonical
local function cmake_project(text)
  -- Ignore quoted/bracket arguments and comments; project() inside an example
  -- or commented-out subproject is not a root declaration.
  local clean, i = {}, 1
  while i <= #text do
    local rest = text:sub(i)
    local bracket = rest:match('^#?%[(=*)%[')
    if bracket then
      local _, stop = text:find(']' .. bracket .. ']', i + #bracket + 2, true)
      i = stop and stop + 1 or #text + 1
      clean[#clean + 1] = ' '
    elseif rest:sub(1, 1) == '#' then
      i = text:find('\n', i, true) or #text + 1
    elseif rest:sub(1, 1) == '"' then
      i = i + 1
      while i <= #text do
        local c = text:sub(i, i)
        i = i + (c == '\\' and 2 or 1)
        if c == '"' then
          break
        end
      end
      clean[#clean + 1] = ' '
    else
      clean[#clean + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(clean):lower():find('%f[%w_]project%s*%(') ~= nil
end
function M.root(start)
  local path = canonical(start or rt.cwd())
  if not rt.is_dir(path) then
    path = rt.dirname(path)
  end
  local native, cmake_fallback
  while path and path ~= '' do
    if rt.read(rt.join(path, '.rivet.json')) or rt.read(rt.join(path, '.outset.json')) then
      return path
    end
    if not native then
      for _, marker in ipairs({ 'Cargo.toml', 'pyproject.toml', 'Package.swift' }) do
        if rt.read(rt.join(path, marker)) then
          native = path
          break
        end
      end
      local cmake = rt.read(rt.join(path, 'CMakeLists.txt'))
      if not native and cmake then
        cmake_fallback = cmake_fallback or path
        if
          cmake_project(cmake)
          or rt.read(rt.join(path, 'CMakePresets.json'))
          or rt.read(rt.join(path, 'CMakeUserPresets.json'))
        then
          native = path
        end
      end
    end
    if path == '/' then
      break
    end
    path = rt.dirname(path)
  end
  return native or cmake_fallback
end
-- Discovery never creates a manifest or claims ownership of existing source lists.
function M.inspect(root)
  assert(
    not rt.exists(rt.confined(root, '.outset.json')),
    'Outset project: review :RivetMigrate or rivet migrate --preview before using Rivet'
  )
  if rt.read(rt.confined(root, '.rivet.json')) then
    return M.load(root)
  end
  for _, entry in ipairs({
    { 'CMakeLists.txt', 'cpp' },
    { 'Cargo.toml', 'rust' },
    { 'pyproject.toml', 'python' },
    { 'Package.swift', 'swift' },
  }) do
    if rt.read(rt.confined(root, entry[1])) then
      return { language = entry[2], name = root:match('[^/]+$'), external = true }
    end
  end
  error('No supported project in ' .. root)
end
function M.load(root)
  root = canonical(root)
  local path = rt.confined(root, '.rivet.json')
  local raw = assert(rt.read(path), 'No .rivet.json in ' .. root .. '; initialize a project first')
  local spec = json.decode(raw)
  assert(type(spec) == 'table' and spec.schema_version == 1, 'Unsupported project manifest version')
  model.normalize(spec) -- validates the registered provider and its configuration
  return spec, raw
end
local function prepare(root, plan, previous, manifest_before)
  root = canonical(root)
  plan.root, plan.expected = root, {}
  local compiler = plan.spec.compiler
  plan.spec.compiler = nil
  plan.spec.generated = previous and previous.generated or {}
  local provider = model.provider(plan.spec)
  if provider.formatter then
    local tools = rt.detect_tools()
    for path, content in pairs(plan.files) do
      local argv = type(content) == 'string'
        and not (plan.replace and plan.replace[path])
        and provider.formatter(plan.spec, path, tools)
      if argv then
        local r = rt.run(argv, { stdin = content })
        assert(r.code == 0, 'Formatting failed: ' .. r.stderr)
        plan.files[path] = r.stdout
      end
    end
  end
  if not previous and provider.local_files then
    local executable
    if compiler and compiler ~= '' then
      executable = assert(rt.executable(compiler), 'Compiler is not executable: ' .. compiler)
    end
    for path, content in pairs(provider.local_files(plan.spec, { compiler = executable })) do
      assert(not plan.files[path], 'Duplicate local file: ' .. path)
      plan.files[path] = content
    end
  end
  for path, content in pairs(plan.files) do
    local full = rt.confined(root, path)
    local existing = rt.read(full)
    local managed = plan.managed and plan.managed[path]
    if previous and managed then
      assert(
        previous.generated and previous.generated[path] == existing,
        'Managed file was edited outside Rivet: '
          .. path
          .. '. Preserve your edits and reconcile this file with the manifest before retrying.'
      )
    elseif previous and plan.replace and plan.replace[path] then
      if plan.original then
        assert(existing == plan.original[path], 'File changed while preparing preview: ' .. path)
      end
      assert(existing ~= nil, 'Source file is missing: ' .. path)
    elseif not previous and path == '.gitignore' and existing then
      -- User rules come last so their exceptions retain Git's normal precedence.
      content = content .. '\n# Existing project rules\n' .. existing
      plan.files[path] = content
    else
      assert(not rt.exists(full), 'Refusing to overwrite existing file: ' .. path)
    end
    plan.expected[path] = existing or false
    if managed then
      plan.spec.generated[path] = content
    end
  end
  plan.files['.rivet.json'] = json.encode(plan.spec)
  plan.expected['.rivet.json'] = previous and assert(manifest_before, 'Missing manifest snapshot')
    or false
  if not previous then
    assert(not rt.exists(rt.join(root, '.rivet.json')), 'Project already initialized')
  end
  return plan
end
function M.plan(opts, root)
  assert(
    not rt.exists(rt.confined(canonical(root or rt.cwd()), '.outset.json')),
    'This folder is an Outset project; use rivet migrate --preview'
  )
  opts = opts or {}
  assert(opts.git == nil or type(opts.git) == 'boolean', 'git must be a boolean')
  local options = {}
  for key, value in pairs(opts) do
    if key ~= 'git' then
      options[key] = value
    end
  end
  local plan = model.plan(options)
  plan = prepare(root or rt.cwd(), plan)
  if opts.git then
    plan.git = require('rivet.git').plan(plan.root)
  end
  return plan
end
function M.file_plan(root, opts)
  local spec, raw = M.load(root)
  return prepare(root, model.add_file(spec, opts), spec, raw)
end
function M.target_plan(root, opts)
  local spec, raw = M.load(root)
  return prepare(root, model.add_target(spec, opts), spec, raw)
end
function M.dependency_plan(root, opts)
  local spec, raw = M.load(root)
  return prepare(root, model.add_dependency(spec, opts), spec, raw)
end
function M.header_plan(root, options)
  local spec, raw = M.load(root)
  spec.comment_header = require('rivet.tasks').service(spec, 'headers').normalize(options)
  return {
    root = canonical(root),
    spec = spec,
    files = { ['.rivet.json'] = json.encode(spec) },
    expected = { ['.rivet.json'] = raw },
  }
end
function M.lifecycle_plan(root, options)
  local spec, raw = M.load(root)
  local provider = model.provider(spec)
  assert(
    provider.lifecycle,
    'This provider does not own source lists; use its native tools for file changes'
  )
  local contents = {}
  for _, path in ipairs(spec.files or {}) do
    contents[path] = rt.read(rt.confined(root, path))
  end
  return prepare(root, provider.lifecycle(spec, options, contents), spec, raw)
end
function M.repair_plan(root, path)
  local spec, raw = M.load(root)
  local baseline =
    assert((spec.generated or {})[path], 'This file has no recorded generated version')
  assert(type(baseline) == 'string', 'Invalid generated snapshot')
  local current = assert(rt.read(rt.confined(root, path)), 'Managed file is missing')
  assert(current ~= baseline, 'Managed file already matches its recorded version')
  local backup = '.rivet-recovery/' .. os.date('%Y%m%d-%H%M%S') .. '/' .. path
  assert(
    not rt.exists(rt.confined(root, backup)),
    'A recovery backup already exists; retry after a second'
  )
  return {
    root = canonical(root),
    spec = spec,
    files = { [path] = baseline, [backup] = current },
    expected = { [path] = current, [backup] = false },
    notes = {
      'Restores the last generated version. Your edited copy is preserved in '
        .. backup
        .. (
          spec.language == 'swift'
            and '. This restores Package.swift; it does not merge custom dependencies, platforms, or targets. Source additions and native tasks preserve a customized package; edit new targets in Package.swift directly when retaining those settings.'
          or '. Move intended custom settings into CMakeLists.txt or your own included CMake file before another mutation.'
        ),
    },
  }
end
function M.apply(root, plan)
  root = canonical(root)
  assert(root == plan.root, 'Plan belongs to a different project root')
  if plan.git then
    require('rivet.git').check(root, plan.git)
  end
  local paths = {}
  for path in pairs(plan.files) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  -- Check the complete plan before touching any project file.
  for _, path in ipairs(paths) do
    local full = rt.confined(root, path)
    assert((rt.read(full) or false) == plan.expected[path], 'File changed since preview: ' .. path)
    assert(not rt.is_dir(full), 'Destination is a directory: ' .. path)
  end
  local buffers = {}
  if rawget(_G, 'vim') then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and not name:match('^%w+://') then
        local full = canonical(name)
        for _, path in ipairs(paths) do
          if full == rt.join(root, path) then
            assert(
              not vim.bo[buf].modified,
              'Save or discard unsaved edits before applying: ' .. path
            )
            buffers[#buffers + 1] = { buf = buf, path = path }
          end
        end
      end
    end
  end
  rt.mkdir(root)
  local lock = rt.confined(root, '.rivet-lock')
  local locked = rt.run({ 'mkdir', lock })
  assert(
    locked.code == 0,
    'Another Rivet write is active (.rivet-lock); if interrupted, remove that empty directory before retrying'
  )
  local staged, committed = {}, {}
  local ok, err = pcall(function()
    for index, path in ipairs(paths) do
      local full = rt.confined(root, path)
      assert(
        (rt.read(full) or false) == plan.expected[path],
        'File changed since preview: ' .. path
      )
      rt.mkdir(rt.dirname(full))
      local temporary = rt.join(lock, tostring(index))
      if plan.files[path] ~= false then
        rt.write(temporary, plan.files[path])
        staged[path] = temporary
      end
    end
    for _, path in ipairs(paths) do
      local full = rt.confined(root, path)
      assert((rt.read(full) or false) == plan.expected[path], 'File changed during write: ' .. path)
      if plan.files[path] == false then
        assert(os.remove(full))
      else
        assert(os.rename(staged[path], full))
      end
      committed[#committed + 1] = path
    end
  end)
  if not ok then
    for i = #committed, 1, -1 do
      local path = committed[i]
      local full = rt.confined(root, path)
      if plan.expected[path] == false then
        os.remove(full)
      else
        rt.write(full, plan.expected[path])
      end
    end
  end
  for _, path in pairs(staged) do
    os.remove(path)
  end
  rt.run({ 'rmdir', lock })
  assert(ok, err)
  if rawget(_G, 'vim') then
    -- Retire destination buffers before renaming a source into their name.
    -- No changed buffer may reach this point: the full plan was checked above.
    local destinations = {}
    for _, path in pairs(plan.moves or {}) do
      destinations[path] = true
    end
    for _, entry in ipairs(buffers) do
      if destinations[entry.path] then
        vim.api.nvim_buf_delete(entry.buf, { force = true })
      end
    end
    for _, entry in ipairs(buffers) do
      local buf, path = entry.buf, entry.path
      if vim.api.nvim_buf_is_valid(buf) and not destinations[path] then
        if plan.moves and plan.moves[path] then
          vim.api.nvim_buf_set_name(buf, rt.join(root, plan.moves[path]))
          if vim.api.nvim_buf_is_loaded(buf) then
            -- Establish the existing destination as the buffer's current
            -- file, so an ordinary :write does not need an E13 override.
            vim.api.nvim_buf_call(buf, function()
              vim.cmd('silent noautocmd edit!')
            end)
          end
        elseif plan.files[path] == false then
          vim.api.nvim_buf_delete(buf, { force = true })
        elseif vim.api.nvim_buf_is_loaded(buf) then
          vim.api.nvim_buf_call(buf, function()
            vim.cmd('silent noautocmd edit!')
          end)
        end
      end
    end
  end
  if plan.git then
    local git_ok, git_error = pcall(require('rivet.git').apply, root, plan.git)
    if not git_ok then
      error(
        'Project files were saved in '
          .. root
          .. ', but Git setup failed: '
          .. tostring(git_error)
          .. '. Correct the Git issue, then run git init in that folder; do not repeat project creation.'
      )
    end
  end
  return plan.spec
end
return M
