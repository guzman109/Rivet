-- C++ option validation and normalization, plus small helpers shared by the
-- C++ provider modules.
local catalog = require('rivet.catalog')
local M = {}

function M.copy(value)
  if type(value) ~= 'table' then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = M.copy(v)
  end
  return out
end

local keywords = {}
for word in
  ([[alignas alignof and and_eq asm auto bitand bitor bool break case catch char char8_t char16_t char32_t class compl concept const consteval constexpr constinit const_cast continue co_await co_return co_yield decltype default delete do double dynamic_cast else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept not not_eq nullptr operator or or_eq private protected public register reinterpret_cast requires return short signed sizeof static static_assert static_cast struct switch template this thread_local throw true try typedef typeid typename union unsigned using virtual void volatile wchar_t while xor xor_eq module import]]):gmatch(
    '%S+'
  )
do
  keywords[word] = true
end

function M.identifier(value, what)
  assert(
    type(value) == 'string' and value:match('^[A-Za-z][A-Za-z0-9_]*$') and not keywords[value],
    'invalid ' .. (what or 'identifier') .. ': ' .. tostring(value)
  )
  assert(not value:find('__', 1, true), 'reserved identifier: ' .. value)
  return value
end

function M.default_name(folder)
  local name = folder:gsub('[^A-Za-z0-9_]', '_'):gsub('_+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if name == '' then
    name = 'project'
  end
  if not name:match('^[A-Za-z]') or keywords[name] or name:match('^std%d*$') then
    name = 'project_' .. name
  end
  return name
end

function M.enum(value, choices, what)
  for _, v in ipairs(choices) do
    if value == v then
      return value
    end
  end
  error('invalid ' .. what .. ': ' .. tostring(value), 2)
end

function M.path(value)
  assert(
    type(value) == 'string'
      and value ~= ''
      and not value:find('[^A-Za-z0-9_./-]')
      and not value:match('^/')
      and not value:match('/$')
      and not value:find('//', 1, true),
    'invalid relative path: ' .. tostring(value)
  )
  for part in value:gmatch('[^/]+') do
    assert(
      part ~= '.'
        and part ~= '..'
        and part:match('^[A-Za-z0-9_.][A-Za-z0-9_.-]*$')
        and not part:find('..', 1, true),
      'unsafe path: ' .. value
    )
  end
  return value
end

function M.module_name(value)
  assert(
    type(value) == 'string'
      and value ~= ''
      and not value:match('^%.')
      and not value:match('%.$')
      and not value:find('..', 1, true),
    'invalid module name'
  )
  for part in value:gmatch('[^.]+') do
    M.identifier(part, 'module component')
  end
  assert(not value:find('[^A-Za-z0-9_.]'), 'invalid module name: ' .. value)
  assert(not value:match('^[^.]+'):match('^std%d*$'), 'the std module namespace is reserved')
  return value
end

function M.cmake_target(value)
  assert(
    type(value) == 'string' and value:match('^[A-Za-z][A-Za-z0-9_:.%-]*$'),
    'invalid CMake target: ' .. tostring(value)
  )
  return value
end

function M.list(value, validate)
  assert(type(value) == 'table', 'expected an array')
  local seen = {}
  for _, v in ipairs(value) do
    validate(v)
    assert(not seen[v], 'duplicate entry: ' .. tostring(v))
    seen[v] = true
  end
end

function M.normalize(opts)
  local spec = M.copy(opts)
  spec.schema_version = spec.schema_version or 1
  assert(spec.schema_version == 1, 'unsupported manifest schema')
  spec.language = spec.language or 'cpp'
  assert(spec.language == 'cpp', 'C++ adapter requires language=cpp')
  spec.name = M.identifier(spec.name or 'sandbox', 'project name')
  assert(spec.name ~= 'std', 'the std C++ namespace is reserved')
  spec.standard = tonumber(spec.standard or 26)
  M.enum(spec.standard, { 17, 20, 23, 26 }, 'C++ standard (17, 20, 23, or 26)')
  require('rivet.languages.cpp_profiles').normalize(spec)
  if spec.modules == nil then
    spec.modules = spec.standard >= 20
  end
  assert(type(spec.modules) == 'boolean', 'modules must be a boolean')
  if spec.std_modules == nil then
    spec.std_modules = false
  end
  assert(type(spec.std_modules) == 'boolean', 'std_modules must be a boolean')
  assert(not spec.modules or spec.standard >= 20, 'Named modules require C++20 or newer')
  assert(not spec.std_modules or spec.standard >= 23, 'import std requires C++23 or newer')
  -- Missing fields in existing manifests retain the original split starter.
  spec.module_layout = M.enum(spec.module_layout or 'split', { 'single', 'split' }, 'module layout')
  spec.style = spec.style or 'LLVM'
  local styles = {}
  for _, style in ipairs(catalog.styles) do
    styles[#styles + 1] = style.id
  end
  M.enum(spec.style, styles, 'formatting style')
  spec.layout = M.enum(spec.layout or 'feature', { 'feature', 'library', 'flat' }, 'layout')
  spec.kind = M.enum(spec.kind or 'app', { 'app', 'library' }, 'project kind')
  spec.header_guard = M.enum(spec.header_guard or 'pragma', { 'pragma', 'ifndef' }, 'header guard')
  spec.comment_header = require('rivet.headers').normalize(spec.comment_header)
  spec.generator = M.enum(spec.generator or 'Ninja', { 'Ninja', 'Unix Makefiles' }, 'generator')
  assert(
    not (spec.modules or spec.std_modules) or spec.generator == 'Ninja',
    'C++ modules require Ninja; disable both named and standard-library modules for Unix Makefiles'
  )
  if spec.compiler ~= nil then
    assert(
      type(spec.compiler) == 'string' and not spec.compiler:find('[\r\n%z]'),
      'invalid compiler path'
    )
  end
  spec.targets = spec.targets or {}
  spec.dependencies = spec.dependencies or {}
  spec.module_names = spec.module_names or {}
  spec.files = spec.files or {}
  M.list(spec.files, M.path)
  local tracked = {}
  for _, filename in ipairs(spec.files) do
    assert(not tracked[filename:lower()], 'case-insensitive file collision: ' .. filename)
    tracked[filename:lower()] = true
  end
  local target_names, file_names = {}, {}
  for _, target in ipairs(spec.targets) do
    M.identifier(target.name, 'target name')
    assert(not target_names[target.name], 'duplicate target: ' .. target.name)
    target_names[target.name] = true
    target.type = M.enum(
      target.type or (target.kind == 'app' and 'executable' or 'static'),
      { 'executable', 'static' },
      'target type'
    )
    target.kind = target.type == 'executable' and 'app' or 'library'
    target.source_dir = target.source_dir
      or (spec.layout == 'flat' and '.' or 'src/' .. target.name)
    if target.source_dir ~= '.' then
      M.path(target.source_dir)
    end
    target.sources, target.modules, target.headers =
      target.sources or {}, target.modules or {}, target.headers or {}
    target.links, target.include_dirs = target.links or {}, target.include_dirs or {}
    target.resources = target.resources or {}
    M.list(target.resources, M.path)
    for _, field in ipairs({ 'sources', 'modules', 'headers' }) do
      M.list(target[field], M.path)
      for _, f in ipairs(target[field]) do
        assert(tracked[f:lower()], 'target file is missing from manifest files: ' .. f)
        assert(not file_names[f:lower()], 'file belongs to more than one target: ' .. f)
        file_names[f:lower()] = true
      end
    end
    assert(spec.modules or #target.modules == 0, 'module files require modules=true')
    M.list(target.links, M.cmake_target)
    M.list(target.include_dirs, function(v)
      if v ~= '.' then
        M.path(v)
      end
    end)
    if target.test ~= nil then
      assert(type(target.test) == 'boolean', 'target.test must be boolean')
    end
  end
  for name, entry in pairs(spec.module_names) do
    M.module_name(name)
    assert(type(entry) == 'table' and target_names[entry.target], 'module refers to unknown target')
    M.path(entry.path)
    local found = false
    for _, target in ipairs(spec.targets) do
      if target.name == entry.target then
        for _, filename in ipairs(target.modules) do
          if filename == entry.path then
            found = true
          end
        end
      end
    end
    assert(found, 'module interface is not registered in its target: ' .. name)
  end
  for _, dep in ipairs(spec.dependencies) do
    M.identifier(dep.name, 'package name')
    assert(
      type(dep.repository) == 'string' and dep.repository:match('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'),
      'repository must be owner/repo'
    )
    assert(
      type(dep.tag) == 'string'
        and dep.tag:match('^[A-Za-z0-9][A-Za-z0-9_./+-]*$')
        and dep.tag ~= 'main'
        and dep.tag ~= 'master'
        and dep.tag ~= 'HEAD'
        and dep.tag ~= 'latest',
      'dependency requires an explicit release tag or commit'
    )
    M.cmake_target(dep.target)
    assert(target_names[dep.link_to], 'dependency link_to refers to unknown target')
  end
  return spec
end

function M.add_unique(values, value)
  for _, entry in ipairs(values) do
    if entry == value then
      return
    end
  end
  values[#values + 1] = value
end

return M
