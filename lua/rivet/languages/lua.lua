-- Standalone Lua applications, reusable modules, and Neovim plugins.
local headers = require('rivet.lua_headers')
local M = {
  label = 'Lua',
  profile_fields = { 'kind', 'runtime' },
  services = {
    tasks = 'rivet.lua_tasks',
    doctor = 'rivet.lua_doctor',
    headers = 'rivet.lua_headers',
    diagnostics = 'rivet.lua_diagnostics',
  },
}
local keywords = {}
local builtins = {}
for name in
  ('coroutine debug io math os package string table utf8 bit bit32 ffi jit vim luv lpeg'):gmatch(
    '%S+'
  )
do
  builtins[name] = true
end
for word in
  ('and break do else elseif end false for function goto if in local nil not or repeat return then true until while'):gmatch(
    '%S+'
  )
do
  keywords[word] = true
end
local function copy(value)
  if type(value) ~= 'table' then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end
function M.identifier(value)
  assert(
    type(value) == 'string' and value:match('^[A-Za-z][A-Za-z0-9_]*$') and not keywords[value],
    'Use a Lua identifier that is not a keyword'
  )
  return value
end
local function module_identifier(value)
  M.identifier(value)
  assert(not builtins[value], 'Lua module name conflicts with a built-in module: ' .. value)
  return value
end
function M.path(value)
  require('rivet.runtime').safe_relative(value)
  assert(
    value:match('^[A-Za-z0-9_./%-]+$') and not value:find('//', 1, true) and not value:match('/$'),
    'Use a project-relative path with letters, digits, underscores, hyphens, and slashes'
  )
  return value
end
function M.default_name(folder)
  local name = folder:gsub('[^A-Za-z0-9_]', '_'):gsub('_+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if name == '' then
    return 'project'
  end
  if not pcall(module_identifier, name) then
    name = 'project_' .. name
  end
  return name
end
function M.normalize(opts)
  local s = copy(opts)
  s.schema_version = s.schema_version or 1
  assert(s.schema_version == 1, 'Unsupported manifest schema')
  assert(s.language == nil or s.language == 'lua', 'Lua provider requires language=lua')
  s.language = 'lua'
  s.name = module_identifier(s.name or 'example')
  s.kind = s.kind or 'app'
  assert(
    s.kind == 'app' or s.kind == 'library' or s.kind == 'plugin',
    'Choose app, library, or plugin'
  )
  s.runtime = s.runtime or (s.kind == 'plugin' and 'neovim' or 'lua')
  assert(
    s.runtime == 'lua' or s.runtime == 'luajit' or s.runtime == 'neovim',
    'Choose lua, luajit, or neovim'
  )
  assert(s.kind ~= 'plugin' or s.runtime == 'neovim', 'Neovim plugins require the neovim runtime')
  s.files, s.targets, s.dependencies, s.module_names =
    s.files or {}, s.targets or {}, s.dependencies or {}, s.module_names or {}
  s.comment_header = headers.normalize(s.comment_header)
  local paths, targets = {}, {}
  for _, path in ipairs(s.files) do
    M.path(path)
    assert(not paths[path:lower()], 'File already registered: ' .. path)
    paths[path:lower()] = true
  end
  for _, target in ipairs(s.targets) do
    M.identifier(target.name)
    assert(not targets[target.name], 'Target already exists: ' .. target.name)
    targets[target.name] = true
    assert(
      target.type == 'executable' or target.type == 'library',
      'Choose an executable or library target'
    )
    target.sources = target.sources or {}
    if target.entrypoint then
      M.path(target.entrypoint)
      assert(paths[target.entrypoint:lower()], 'Target entrypoint is not a registered file')
    end
    for _, source in ipairs(target.sources) do
      M.path(source)
      assert(paths[source:lower()], 'Target source is not a registered file')
    end
    if target.source_dir then
      M.path(target.source_dir)
    end
  end
  if s.test_script then
    M.path(s.test_script)
    assert(paths[s.test_script:lower()], 'Test script is not a registered file')
  end
  return s
end
function M.ignore_rules()
  return '/.cache/\n/luac.out\n/.luarocks/\n.DS_Store\n'
end

-- A script can be launched from any cwd. Resolve modules relative to its file.
function M.bootstrap(path)
  local parents = select(2, path:gsub('/', ''))
  return 'local source = debug.getinfo(1, "S").source\n'
    .. 'local script = source:sub(1, 1) == "@" and source:sub(2) or arg[0]\n'
    .. 'local root = (script:match("^(.*)/[^/]+$") or ".")'
    .. string.rep(' .. "/.."', parents)
    .. '\n'
    .. 'package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path\n\n'
end

-- Reused by mixed-language file generation without creating a native build target.
function M.file_template(opts, context)
  context = context or {}
  local kind = opts.kind or 'module'
  assert(kind == 'module' or kind == 'script', 'Choose a Lua module or script')
  local raw = M.path(assert(opts.name, 'File name required')):gsub('%.lua$', '')
  M.identifier(raw:match('[^/]+$'))
  local path = raw:find('/', 1, true) and raw .. '.lua'
    or (kind == 'module' and ('lua/' .. M.identifier(context.name or 'example') .. '/') or 'scripts/')
      .. raw
      .. '.lua'
  local body = kind == 'module' and 'local M = {}\n\n-- Add module functions here.\n\nreturn M\n'
    or M.bootstrap(path)
      .. '-- Add script behavior here.\nprint("Hello from '
      .. raw:match('[^/]+$')
      .. '")\n'
  return path,
    headers.render(context.comment_header, { filename = path, project = context.name or '' })
      .. body
end

local function add(s, files, path, text, target)
  M.path(path)
  for _, registered in ipairs(s.files) do
    assert(registered:lower() ~= path:lower(), 'File already registered: ' .. path)
  end
  s.files[#s.files + 1] = path
  files[path] = path:match('%.lua$')
      and (headers.render(s.comment_header, { filename = path, project = s.name }) .. text)
    or text
  if target then
    target.sources[#target.sources + 1] = path
  end
end
local function target(s, name, kind, source_dir, entrypoint)
  M.identifier(name)
  for _, existing in ipairs(s.targets) do
    assert(existing.name ~= name, 'Target already exists: ' .. name)
  end
  local t =
    { name = name, type = kind, source_dir = source_dir, sources = {}, entrypoint = entrypoint }
  s.targets[#s.targets + 1] = t
  return t
end
local function result(s, files)
  table.sort(s.files)
  return { spec = M.normalize(s), files = files, managed = {} }
end
function M.upgrade_files(spec)
  local s = M.normalize(spec)
  local files = {
    ['.luarc.json'] = require('rivet.json').encode({
      ['runtime.version'] = s.runtime == 'lua' and 'Lua 5.1' or 'LuaJIT',
      ['runtime.path'] = { 'lua/?.lua', 'lua/?/init.lua' },
      ['workspace.checkThirdParty'] = false,
      ['diagnostics.globals'] = require('rivet.json').array(
        s.runtime == 'neovim' and { 'vim' } or {}
      ),
    }),
    ['.luacheckrc'] = 'std = "'
      .. (s.runtime == 'lua' and 'lua51' or 'luajit')
      .. '"\n'
      .. (s.runtime == 'neovim' and 'globals = { "vim" }\n' or ''),
    ['.stylua.toml'] = 'column_width = 100\nindent_type = "Spaces"\nindent_width = 2\nquote_style = "AutoPreferSingle"\n',
    ['README.md'] = '# '
      .. s.name
      .. '\n\nLua '
      .. s.kind
      .. ' created with Rivet. Runtime: `'
      .. s.runtime
      .. '`.\n\nRun `:RivetTask check` to check syntax without executing source files and `:RivetTask test` for the included correctness test.\n'
      .. (s.kind == 'app' and 'Run `:RivetTask run` to execute the application.\n' or '')
      .. (s.kind == 'plugin' and 'Add this folder to Neovim runtimepath, then use `require("' .. s.name .. '").setup({})`. Plugin tests run in a clean headless Neovim.\n' or '')
      .. '\nSet `lua` in `.rivet.local.json` to select a local executable for the chosen runtime. Lua modules live under `lua/`; scripts resolve that directory relative to their own file.\n\nStyLua and Luacheck are optional, explicitly installed formatting and lint tools. Rivet does not install packages or manage LuaRocks dependencies.\n',
    ['AGENTS.md'] = '# Project guidance\n\nUse Lua 5.1-compatible syntax for portable modules. The selected runtime is `'
      .. s.runtime
      .. "`.\nKeep modules under `lua/` and scripts in their recorded project-relative locations.\nRun syntax checks and the dependency-free test before proposing changes. Syntax checks must not execute source files.\nDo not install packages automatically; review dependency changes through the project's existing workflow.\n",
  }
  if s.kind == 'plugin' then
    local command = (s.name .. '_'):gsub('([^_]+)_', function(part)
      return part:sub(1, 1):upper() .. part:sub(2)
    end) .. 'Hello'
    files['doc/' .. s.name .. '.txt'] = '*'
      .. s.name
      .. '.txt*  '
      .. s.name
      .. ' Neovim plugin\n\nSETUP\n\n    require("'
      .. s.name
      .. '").setup({ greeting = "Hello" })\n\nCOMMAND\n\n    :'
      .. command
      .. '\n\nvim:tw=78:ts=8:ft=help:norl:\n'
  end
  return files
end
function M.plan(opts)
  local s = M.normalize(opts)
  assert(#s.files == 0 and #s.targets == 0, 'New projects only')
  local files = {}
  local module =
    target(s, s.kind == 'app' and s.name .. '_core' or s.name, 'library', 'lua/' .. s.name)
  local module_text = 'local M = {}\n\nfunction M.add(a, b)\n  return a + b\nend\n'
  local command = (s.name .. '_'):gsub('([^_]+)_', function(part)
    return part:sub(1, 1):upper() .. part:sub(2)
  end) .. 'Hello'
  if s.kind == 'plugin' then
    module_text = module_text
      .. '\nM.options = {}\n\nfunction M.setup(opts)\n  M.options = vim.tbl_deep_extend("force", { greeting = "Hello from '
      .. s.name
      .. '" }, opts or {})\nend\n\nfunction M.greet()\n  vim.notify(M.options.greeting or "Hello from '
      .. s.name
      .. '")\nend\n'
    add(
      s,
      files,
      'plugin/' .. s.name .. '.lua',
      'if vim.g.loaded_'
        .. s.name
        .. ' then\n  return\nend\nvim.g.loaded_'
        .. s.name
        .. ' = true\n\nvim.api.nvim_create_user_command("'
        .. command
        .. '", function()\n  require("'
        .. s.name
        .. '").greet()\nend, { desc = "Show a greeting from '
        .. s.name
        .. '" })\n'
    )
  end
  add(s, files, 'lua/' .. s.name .. '/init.lua', module_text .. '\nreturn M\n', module)
  if s.kind == 'app' then
    local app = target(s, s.name, 'executable', nil, 'main.lua')
    add(
      s,
      files,
      'main.lua',
      M.bootstrap('main.lua')
        .. 'local project = require("'
        .. s.name
        .. '")\nprint(project.add(20, 22))\n',
      app
    )
  end
  s.test_script = 'tests/test.lua'
  local test = M.bootstrap(s.test_script)
  if s.kind == 'plugin' then
    test = test
      .. 'vim.opt.runtimepath:prepend(root)\nvim.cmd("runtime plugin/'
      .. s.name
      .. '.lua")\nassert(vim.g.loaded_'
      .. s.name
      .. ')\nassert(vim.api.nvim_get_commands({ builtin = false })["'
      .. command
      .. '"])\n'
  end
  test = test
    .. 'local project = require("'
    .. s.name
    .. '")\nassert(project.add(20, 22) == 42)\nassert(project.add(-1, 1) == 0)\n'
  if s.kind == 'plugin' then
    test = test
      .. 'project.setup({ greeting = "Test greeting" })\nassert(project.options.greeting == "Test greeting")\n'
  end
  add(s, files, s.test_script, test .. 'print("Lua correctness tests passed")\n')
  for path, text in pairs(M.upgrade_files(s)) do
    add(s, files, path, text)
  end
  return result(s, files)
end

function M.add_file(existing, opts)
  local s = M.normalize(existing)
  local context = { name = s.name, comment_header = s.comment_header }
  local owner
  if (opts.kind or 'module') == 'module' and not opts.target then
    for _, t in ipairs(s.targets) do
      if t.type == 'library' and t.source_dir == 'lua/' .. s.name then
        owner = t
        break
      end
    end
  end
  if opts.target then
    for _, t in ipairs(s.targets) do
      if t.name == opts.target then
        owner = t
      end
    end
    assert(owner, 'Unknown target: ' .. opts.target)
    if (opts.kind or 'module') == 'module' then
      assert(owner.type == 'library', 'Select a library target for a module')
      context.name = owner.source_dir and owner.source_dir:match('^lua/(.+)$') or s.name
    end
  end
  local path, text = M.file_template(opts, context)
  local files = {}
  if opts.kind == 'script' then
    assert(not opts.target, 'A script becomes its own executable target; use its file name')
    owner = target(s, M.default_name(opts.name:gsub('%.lua$', '')), 'executable', nil, path)
  end
  -- file_template already rendered the chosen header.
  local before = s.comment_header
  s.comment_header = { style = 'none' }
  add(s, files, path, text, owner)
  s.comment_header = before
  return result(s, files)
end
function M.add_target(existing, opts)
  local s = M.normalize(existing)
  local name = M.identifier(assert(opts.name, 'Target name required'))
  local kind = opts.kind or 'app'
  assert(kind == 'app' or kind == 'library', 'Choose app or library')
  if kind == 'library' then
    module_identifier(name)
  end
  local files = {}
  local path = kind == 'app' and 'scripts/' .. name .. '.lua' or 'lua/' .. name .. '/init.lua'
  local t = target(
    s,
    name,
    kind == 'app' and 'executable' or 'library',
    kind == 'library' and 'lua/' .. name or nil,
    kind == 'app' and path or nil
  )
  add(
    s,
    files,
    path,
    kind == 'app' and (M.bootstrap(path) .. 'print("Hello from ' .. name .. '")\n')
      or 'local M = {}\n\nreturn M\n',
    t
  )
  return result(s, files)
end
function M.add_dependency()
  error(
    'Use LuaRocks or your existing dependency workflow; Rivet does not install or resolve Lua packages'
  )
end
function M.questions(kind, spec)
  if kind == 'new' then
    return {
      {
        key = 'kind',
        title = 'Lua project kind',
        items = {
          { id = 'app', label = 'Application / script' },
          { id = 'library', label = 'Reusable Lua library' },
          { id = 'plugin', label = 'Neovim plugin' },
        },
      },
      {
        key = 'runtime',
        title = 'Lua runtime',
        items = {
          { id = 'lua', label = 'Lua (portable 5.1+ templates)' },
          { id = 'luajit', label = 'LuaJIT' },
          { id = 'neovim', label = 'Neovim' },
        },
        when = function(s)
          if s.kind == 'plugin' then
            s.runtime = 'neovim'
            return false
          end
          return true
        end,
      },
    }
  end
  assert(kind ~= 'dependency', 'Use LuaRocks or your existing dependency workflow')
  local steps = {}
  if kind == 'file' then
    steps[#steps + 1] = {
      key = 'kind',
      title = 'Lua file kind',
      items = {
        { id = 'module', label = 'Module returning a table' },
        { id = 'script', label = 'Runnable script' },
      },
    }
    local libraries = {}
    for _, item in ipairs(spec.targets or {}) do
      if item.type == 'library' then
        libraries[#libraries + 1] = { id = item.name, label = item.name }
      end
    end
    steps[#steps + 1] = {
      key = 'target',
      title = 'Owning Lua module',
      items = libraries,
      when = function(options)
        if options.kind == 'script' then
          options.target = nil
          return false
        end
        return true
      end,
    }
  elseif kind == 'target' then
    steps[#steps + 1] = {
      key = 'kind',
      title = 'Lua target kind',
      items = {
        { id = 'app', label = 'Runnable script' },
        { id = 'library', label = 'Reusable module' },
      },
    }
  end
  steps[#steps + 1] = {
    key = 'name',
    title = kind == 'file' and 'Name or project-relative path (optional .lua extension)'
      or 'Target name (Lua identifier)',
    input = true,
    default = 'feature',
    validate = function(value)
      if kind == 'file' then
        M.path(value)
        M.identifier(value:gsub('%.lua$', ''):match('[^/]+$'))
      else
        M.identifier(value)
      end
    end,
  }
  return steps
end
return M
