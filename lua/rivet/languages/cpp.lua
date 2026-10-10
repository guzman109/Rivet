local M = {}
local managed = { ['cmake/RivetTargets.cmake'] = true, ['cmake/Dependencies.cmake'] = true }
local catalog = require('rivet.catalog')
M.label = 'C++'
M.services = {
  tasks = 'rivet.cmake',
  doctor = 'rivet.doctor',
  headers = 'rivet.headers',
  diagnostics = 'rivet.diagnostics',
}
M.profile_fields = {
  'standard',
  'modules',
  'std_modules',
  'module_layout',
  'kind',
  'layout',
  'style',
  'header_guard',
  'generator',
  'profile',
  'cuda_standard',
  'cuda_architectures',
}

function M.questions(kind, spec, context)
  return require('rivet.languages.cpp_questions')[kind](spec, context)
end

function M.formatter(spec, filename, tools)
  if
    tools.clang_format
    and (
      filename:match('%.cpp$')
      or filename:match('%.hpp$')
      or filename:match('%.cppm$')
      or filename:match('%.c$')
      or filename:match('%.h$')
      or filename:match('%.cu$')
    )
  then
    return { tools.clang_format, '--style=' .. spec.style, '--assume-filename=' .. filename }
  end
end

function M.local_files(spec, context)
  if not context.compiler then
    return {}
  end
  return {
    ['CMakeUserPresets.json'] = require('rivet.json').encode({
      version = 6,
      configurePresets = {
        {
          name = 'local-debug',
          inherits = 'debug',
          cacheVariables = { CMAKE_CXX_COMPILER = context.compiler },
        },
        {
          name = 'local-release',
          inherits = 'release',
          cacheVariables = { CMAKE_CXX_COMPILER = context.compiler },
        },
      },
    }),
  }
end

function M.ignore_rules()
  return [[# Rivet: C++ / CMake
/build/
/cmake-build-*/
/.cache/
/CMakeUserPresets.json
/compile_commands.json
/CMakeFiles/
/CMakeCache.txt
/Testing/

# Compiled objects, libraries, executables, and module artifacts
*.o
*.obj
*.a
*.lib
*.so
*.so.*
*.dylib
*.dll
*.exe
*.pdb
*.pcm
*.gcm
*.ifc

# macOS folder metadata
.DS_Store
]]
end

local function copy(value)
  if type(value) ~= 'table' then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v)
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

local function identifier(value, what)
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

local function enum(value, choices, what)
  for _, v in ipairs(choices) do
    if value == v then
      return value
    end
  end
  error('invalid ' .. what .. ': ' .. tostring(value), 2)
end

local function path(value)
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

local function module_name(value)
  assert(
    type(value) == 'string'
      and value ~= ''
      and not value:match('^%.')
      and not value:match('%.$')
      and not value:find('..', 1, true),
    'invalid module name'
  )
  for part in value:gmatch('[^.]+') do
    identifier(part, 'module component')
  end
  assert(not value:find('[^A-Za-z0-9_.]'), 'invalid module name: ' .. value)
  assert(not value:match('^[^.]+'):match('^std%d*$'), 'the std module namespace is reserved')
  return value
end

local function cmake_target(value)
  assert(
    type(value) == 'string' and value:match('^[A-Za-z][A-Za-z0-9_:.%-]*$'),
    'invalid CMake target: ' .. tostring(value)
  )
  return value
end

local function list(value, validate)
  assert(type(value) == 'table', 'expected an array')
  local seen = {}
  for _, v in ipairs(value) do
    validate(v)
    assert(not seen[v], 'duplicate entry: ' .. tostring(v))
    seen[v] = true
  end
end

function M.normalize(opts)
  local spec = copy(opts)
  spec.schema_version = spec.schema_version or 1
  assert(spec.schema_version == 1, 'unsupported manifest schema')
  spec.language = spec.language or 'cpp'
  assert(spec.language == 'cpp', 'C++ adapter requires language=cpp')
  spec.name = identifier(spec.name or 'sandbox', 'project name')
  assert(spec.name ~= 'std', 'the std C++ namespace is reserved')
  spec.standard = tonumber(spec.standard or 26)
  enum(spec.standard, { 17, 20, 23, 26 }, 'C++ standard (17, 20, 23, or 26)')
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
  spec.module_layout = enum(spec.module_layout or 'split', { 'single', 'split' }, 'module layout')
  spec.style = spec.style or 'LLVM'
  local styles = {}
  for _, style in ipairs(catalog.styles) do
    styles[#styles + 1] = style.id
  end
  enum(spec.style, styles, 'formatting style')
  spec.layout = enum(spec.layout or 'feature', { 'feature', 'library', 'flat' }, 'layout')
  spec.kind = enum(spec.kind or 'app', { 'app', 'library' }, 'project kind')
  spec.header_guard = enum(spec.header_guard or 'pragma', { 'pragma', 'ifndef' }, 'header guard')
  spec.comment_header = require('rivet.headers').normalize(spec.comment_header)
  spec.generator = enum(spec.generator or 'Ninja', { 'Ninja', 'Unix Makefiles' }, 'generator')
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
  list(spec.files, path)
  local tracked = {}
  for _, filename in ipairs(spec.files) do
    assert(not tracked[filename:lower()], 'case-insensitive file collision: ' .. filename)
    tracked[filename:lower()] = true
  end
  local target_names, file_names = {}, {}
  for _, target in ipairs(spec.targets) do
    identifier(target.name, 'target name')
    assert(not target_names[target.name], 'duplicate target: ' .. target.name)
    target_names[target.name] = true
    target.type = enum(
      target.type or (target.kind == 'app' and 'executable' or 'static'),
      { 'executable', 'static' },
      'target type'
    )
    target.kind = target.type == 'executable' and 'app' or 'library'
    target.source_dir = target.source_dir
      or (spec.layout == 'flat' and '.' or 'src/' .. target.name)
    if target.source_dir ~= '.' then
      path(target.source_dir)
    end
    target.sources, target.modules, target.headers =
      target.sources or {}, target.modules or {}, target.headers or {}
    target.links, target.include_dirs = target.links or {}, target.include_dirs or {}
    target.resources = target.resources or {}
    list(target.resources, path)
    for _, field in ipairs({ 'sources', 'modules', 'headers' }) do
      list(target[field], path)
      for _, f in ipairs(target[field]) do
        assert(tracked[f:lower()], 'target file is missing from manifest files: ' .. f)
        assert(not file_names[f:lower()], 'file belongs to more than one target: ' .. f)
        file_names[f:lower()] = true
      end
    end
    assert(spec.modules or #target.modules == 0, 'module files require modules=true')
    list(target.links, cmake_target)
    list(target.include_dirs, function(v)
      if v ~= '.' then
        path(v)
      end
    end)
    if target.test ~= nil then
      assert(type(target.test) == 'boolean', 'target.test must be boolean')
    end
  end
  for name, entry in pairs(spec.module_names) do
    module_name(name)
    assert(type(entry) == 'table' and target_names[entry.target], 'module refers to unknown target')
    path(entry.path)
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
    identifier(dep.name, 'package name')
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
    cmake_target(dep.target)
    assert(target_names[dep.link_to], 'dependency link_to refers to unknown target')
  end
  return spec
end

local function target_for(spec, name)
  if name == nil then
    for _, target in ipairs(spec.targets) do
      if target.type == 'static' and not target.test then
        return target
      end
    end
  end
  for _, target in ipairs(spec.targets) do
    if target.name == name then
      return target
    end
  end
  error('unknown target: ' .. tostring(name), 2)
end

local function add_unique(values, value)
  for _, entry in ipairs(values) do
    if entry == value then
      return
    end
  end
  values[#values + 1] = value
end

local function add_file(spec, files, filename, content, target, field)
  path(filename)
  for _, existing in ipairs(spec.files) do
    assert(existing:lower() ~= filename:lower(), 'file already exists in project: ' .. filename)
  end
  spec.files[#spec.files + 1] = filename
  files[filename] = require('rivet.headers').render(spec.comment_header, {
    filename = filename,
    project = spec.name,
  }) .. content
  if target then
    target[field][#target[field] + 1] = filename
  end
end

local function new_target(spec, name, kind, source_dir)
  identifier(name, 'target name')
  for _, target in ipairs(spec.targets) do
    assert(target.name ~= name, 'target already exists: ' .. name)
  end
  local reserved = {
    all = true,
    clean = true,
    help = true,
    install = true,
    test = true,
    format = true,
    package = true,
    rebuild_cache = true,
    edit_cache = true,
  }
  assert(not reserved[name], 'reserved build target: ' .. name)
  local target = {
    name = name,
    kind = kind,
    type = kind == 'app' and 'executable' or 'static',
    source_dir = source_dir,
    sources = {},
    modules = {},
    headers = {},
    links = {},
    include_dirs = {},
  }
  spec.targets[#spec.targets + 1] = target
  return target
end

local function header(spec, filename, body)
  if spec.header_guard == 'pragma' then
    return '#pragma once\n\n' .. body
  end
  local guard = (spec.name .. '_' .. filename):upper():gsub('[^A-Z0-9]', '_'):gsub('_+', '_')
  return '#ifndef '
    .. guard
    .. '\n#define '
    .. guard
    .. '\n\n'
    .. body
    .. '\n#endif // '
    .. guard
    .. '\n'
end

local function quoted_paths(lines, values, indent)
  for _, value in ipairs(values) do
    lines[#lines + 1] = (indent or '  ') .. '"${PROJECT_SOURCE_DIR}/' .. value .. '"'
  end
end

local function targets_cmake(spec)
  local lines = {
    '# Generated from .rivet.json. Use Rivet or its Lua CLI to edit targets.',
    '# Put hand-written extensions in the root CMakeLists.txt after this include.',
    '',
  }
  if spec.c_standard then
    assert(
      spec.c_standard == 11 or spec.c_standard == 17 or spec.c_standard == 23,
      'Invalid C standard'
    )
    lines[#lines + 1] = 'enable_language(C)\nset(CMAKE_C_STANDARD '
      .. spec.c_standard
      .. ')\nset(CMAKE_C_STANDARD_REQUIRED ON)\nset(CMAKE_C_EXTENSIONS OFF)'
  end
  local format_files = {}
  for _, target in ipairs(spec.targets) do
    if target.test then
      lines[#lines + 1] = 'if(BUILD_TESTING)'
    end
    if target.type == 'executable' then
      lines[#lines + 1] = 'add_executable(' .. target.name .. ')'
    else
      lines[#lines + 1] = 'add_library(' .. target.name .. ' STATIC)'
    end
    lines[#lines + 1] = 'set_target_properties(' .. target.name .. ' PROPERTIES'
    lines[#lines + 1] = '  CXX_STANDARD '
      .. spec.standard
      .. ' CXX_STANDARD_REQUIRED YES CXX_EXTENSIONS NO'
    lines[#lines + 1] = '  CXX_SCAN_FOR_MODULES '
      .. ((spec.modules or spec.std_modules) and 'ON' or 'OFF')
    if spec.std_modules then
      lines[#lines + 1] = '  CXX_MODULE_STD ON'
    end
    lines[#lines + 1] = ')'
    if #target.sources + #target.headers > 0 then
      lines[#lines + 1] = 'target_sources(' .. target.name .. ' PRIVATE'
      quoted_paths(lines, target.sources)
      quoted_paths(lines, target.headers)
      lines[#lines + 1] = ')'
    end
    if #target.modules > 0 then
      lines[#lines + 1] = 'target_sources('
        .. target.name
        .. ' '
        .. (target.type == 'static' and 'PUBLIC' or 'PRIVATE')
      lines[#lines + 1] = '  FILE_SET cxx_modules TYPE CXX_MODULES'
      lines[#lines + 1] = '  BASE_DIRS "${PROJECT_SOURCE_DIR}"'
      lines[#lines + 1] = '  FILES'
      quoted_paths(lines, target.modules, '    ')
      lines[#lines + 1] = ')'
    end
    if #target.include_dirs > 0 then
      lines[#lines + 1] = 'target_include_directories('
        .. target.name
        .. ' '
        .. (target.type == 'static' and 'PUBLIC' or 'PRIVATE')
      quoted_paths(lines, target.include_dirs)
      lines[#lines + 1] = ')'
    end
    if #target.links > 0 then
      lines[#lines + 1] = 'target_link_libraries('
        .. target.name
        .. ' '
        .. (target.type == 'static' and 'PUBLIC' or 'PRIVATE')
        .. ' '
        .. table.concat(target.links, ' ')
        .. ')'
    end
    lines[#lines + 1] = 'rivet_target_options(' .. target.name .. ')'
    if target.test then
      lines[#lines + 1] = 'add_test(NAME ' .. target.name .. ' COMMAND ' .. target.name .. ')'
      lines[#lines + 1] = 'endif()'
    end
    lines[#lines + 1] = ''
    for _, field in ipairs({ 'sources', 'modules', 'headers' }) do
      for _, filename in ipairs(target[field]) do
        add_unique(format_files, filename)
      end
    end
  end
  lines[#lines + 1] = 'find_program(RIVET_CLANG_FORMAT NAMES clang-format)'
  lines[#lines + 1] = 'if(RIVET_CLANG_FORMAT)'
  lines[#lines + 1] = '  add_custom_target(format'
  lines[#lines + 1] = '    COMMAND "${RIVET_CLANG_FORMAT}" -i --style=file'
  quoted_paths(lines, format_files, '      ')
  lines[#lines + 1] = '    WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}" VERBATIM)'
  lines[#lines + 1] = 'endif()'
  return table.concat(lines, '\n') .. '\n'
end

local bootstrap = [[# CPM bootstrap pinned to upstream v0.43.1 (official release checksum).
set(CPM_SOURCE_CACHE "${PROJECT_SOURCE_DIR}/.cache/CPM" CACHE PATH "Project dependency source cache" FORCE)
set(_wb_cpm "${PROJECT_SOURCE_DIR}/.cache/CPM/CPM_0.43.1.cmake")
set(_wb_cpm_sha "1c40fc102ce9625d7de7eb14f541cab30cc3138dca627f0b0ec40293ce6c2934")
file(MAKE_DIRECTORY "${PROJECT_SOURCE_DIR}/.cache/CPM")
if(EXISTS "${_wb_cpm}")
  file(SHA256 "${_wb_cpm}" _wb_actual_sha)
  if(NOT _wb_actual_sha STREQUAL _wb_cpm_sha)
    message(FATAL_ERROR "CPM checksum mismatch: ${_wb_cpm}. Remove the corrupt cache file and configure again.")
  endif()
else()
  file(DOWNLOAD
    "https://github.com/cpm-cmake/CPM.cmake/releases/download/v0.43.1/CPM.cmake"
    "${_wb_cpm}.tmp"
    STATUS _wb_download_status TLS_VERIFY ON TIMEOUT 120)
  list(GET _wb_download_status 0 _wb_download_code)
  if(NOT _wb_download_code EQUAL 0)
    file(REMOVE "${_wb_cpm}.tmp")
    message(FATAL_ERROR "CPM download failed: ${_wb_download_status}")
  endif()
  file(SHA256 "${_wb_cpm}.tmp" _wb_actual_sha)
  if(NOT _wb_actual_sha STREQUAL _wb_cpm_sha)
    file(REMOVE "${_wb_cpm}.tmp")
    message(FATAL_ERROR "Downloaded CPM checksum does not match the pinned release")
  endif()
  file(RENAME "${_wb_cpm}.tmp" "${_wb_cpm}")
endif()
include("${_wb_cpm}")
]]

local function dependencies_cmake(spec)
  local lines = {
    '# Generated from .rivet.json; explicitly versioned CPM dependencies.',
    '# Empty projects configure and build without accessing the network.',
  }
  if #spec.dependencies > 0 then
    lines[#lines + 1] = 'include("${CMAKE_CURRENT_LIST_DIR}/CPM.cmake")'
    for _, dep in ipairs(spec.dependencies) do
      lines[#lines + 1] = 'CPMAddPackage('
      lines[#lines + 1] = '  NAME ' .. dep.name
      lines[#lines + 1] = '  GITHUB_REPOSITORY "' .. dep.repository .. '"'
      lines[#lines + 1] = '  GIT_TAG "' .. dep.tag .. '"'
      lines[#lines + 1] = ')'
      lines[#lines + 1] = 'if(NOT TARGET ' .. dep.target .. ')'
      lines[#lines + 1] = '  message(FATAL_ERROR "Dependency '
        .. dep.name
        .. ' did not define expected target '
        .. dep.target
        .. '")'
      lines[#lines + 1] = 'endif()'
    end
  end
  return table.concat(lines, '\n') .. '\n'
end

local function std_import(spec)
  return spec.std_modules and 'import std;\n\n' or ''
end

local function module_start(spec, name, interface)
  local prefix = ''
  if interface and not spec.std_modules then
    prefix =
      '// Put standard-library #includes in a global module fragment:\n// module;\n// #include <cstddef>\n'
  end
  return prefix
    .. (interface and 'export module ' or 'module ')
    .. name
    .. ';\n\n'
    .. std_import(spec)
end

local function initial_sources(spec, files)
  local flat = spec.layout == 'flat'
  local dir = flat and '.' or (spec.layout == 'feature' and 'src/core' or 'src')
  local prefix = spec.name:gsub('_$', '')
  local core =
    new_target(spec, spec.kind == 'library' and spec.name or prefix .. '_core', 'library', dir)
  local interface = flat and 'core'
    or (
      spec.layout == 'feature' and 'src/core/core'
      or (spec.modules and 'modules/core' or 'include/' .. spec.name .. '/core')
    )
  local impl = (dir == '.' and '' or dir .. '/') .. 'core.cpp'
  local body = 'namespace '
    .. spec.name
    .. [[ {
struct WorkRange {
  int begin;
  int end;
};

// Divide [0, total) into balanced, non-overlapping worker ranges.
// Invalid arguments return an empty range.
WorkRange partition_work(int total, int workers, int index);
} // namespace ]]
    .. spec.name
    .. '\n'
  local impl_body = 'namespace '
    .. spec.name
    .. [[ {
WorkRange partition_work(int total, int workers, int index) {
  if (total < 0 || workers <= 0 || index < 0 || index >= workers) {
    return {0, 0};
  }
  const int base = total / workers;
  const int extra = total % workers;
  const int begin = index * base + (index < extra ? index : extra);
  return {begin, begin + base + (index < extra ? 1 : 0)};
}
} // namespace ]]
    .. spec.name
    .. '\n'
  local consume
  if spec.modules then
    local mod = module_name(spec.name .. '.core')
    add_file(
      spec,
      files,
      interface .. '.cppm',
      module_start(spec, mod, true)
        .. 'export '
        .. body
        .. (spec.module_layout == 'single' and ('\n' .. impl_body) or ''),
      core,
      'modules'
    )
    if spec.module_layout ~= 'single' then
      add_file(spec, files, impl, module_start(spec, mod, false) .. impl_body, core, 'sources')
    end
    spec.module_names[mod] = { target = core.name, path = interface .. '.cppm' }
    consume = std_import(spec) .. 'import ' .. mod .. ';\n'
  else
    local include_name = spec.layout == 'library' and spec.name .. '/core.hpp' or 'core.hpp'
    core.include_dirs = { spec.layout == 'library' and 'include' or dir }
    add_file(
      spec,
      files,
      interface .. '.hpp',
      header(spec, interface .. '.hpp', body),
      core,
      'headers'
    )
    add_file(
      spec,
      files,
      impl,
      '#include "' .. include_name .. '"\n\n' .. std_import(spec) .. impl_body,
      core,
      'sources'
    )
    consume = '#include "'
      .. include_name
      .. '"\n'
      .. (spec.std_modules and '\n' .. std_import(spec) or '')
  end
  if spec.kind == 'app' then
    local app = new_target(spec, spec.name, 'app', flat and '.' or 'app')
    app.links = { core.name }
    add_file(
      spec,
      files,
      flat and 'main.cpp' or 'app/main.cpp',
      (spec.std_modules and '' or '#include <iostream>\n\n')
        .. consume
        .. '\nint main() {\n  const auto range = '
        .. spec.name
        .. '::partition_work(10, 3, 0);\n'
        .. '  std::cout << "Worker 0: [" << range.begin << ", " << range.end << ")\\n";\n'
        .. '  return 0;\n}\n',
      app,
      'sources'
    )
  end
  local test = new_target(spec, prefix .. '_test', 'app', flat and '.' or 'tests')
  test.test, test.links = true, { core.name }
  add_file(spec, files, flat and 'core_test.cpp' or 'tests/core_test.cpp', consume .. [[
int main() {
  const int expected_begin[] = {0, 4, 7};
  const int expected_end[] = {4, 7, 10};
  for (int worker = 0; worker < 3; ++worker) {
    const auto range = ]] .. spec.name .. [[::partition_work(10, 3, worker);
    if (range.begin != expected_begin[worker] || range.end != expected_end[worker]) {
      return 1;
    }
  }
  const auto invalid = ]] .. spec.name .. [[::partition_work(10, 0, 0);
  return invalid.begin == 0 && invalid.end == 0 ? 0 : 1;
}
]], test, 'sources')
end

local cmake_options = [[# User-editable project-wide options; scoped to this project's targets.
option(RIVET_WARNINGS "Enable useful compiler warnings" ON)
option(RIVET_SANITIZERS "Enable address and undefined behavior sanitizers" OFF)

function(rivet_target_options target)
  if(RIVET_WARNINGS)
    if(MSVC)
      target_compile_options(${target} PRIVATE /W4)
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(${target} PRIVATE "$<$<COMPILE_LANGUAGE:C,CXX,OBJCXX>:-Wall;-Wextra;-Wpedantic>")

    endif()
  endif()
  if(RIVET_SANITIZERS)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(${target} PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
      target_link_options(${target} PRIVATE -fsanitize=address,undefined)
    else()
      message(FATAL_ERROR "This sanitizer preset requires Clang or GCC")
    endif()
  endif()
endfunction()
]]

local function presets(spec)
  local minimum = spec.std_modules and '"major": 4, "minor": 4' or '"major": 3, "minor": 30'
  return [[{
  "version": 6,
  "cmakeMinimumRequired": { ]] .. minimum .. [[, "patch": 0 },
  "configurePresets": [
    {
      "name": "debug", "displayName": "Debug",
      "generator": "]] .. spec.generator .. [[",
      "binaryDir": "${sourceDir}/build/debug",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Debug", "CMAKE_EXPORT_COMPILE_COMMANDS": true, "BUILD_TESTING": true }
    },
    {
      "name": "release", "displayName": "Release", "inherits": "debug",
      "binaryDir": "${sourceDir}/build/release",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Release" }
    }
  ],
  "buildPresets": [
    { "name": "debug", "configurePreset": "debug" },
    { "name": "release", "configurePreset": "release" }
  ],
  "testPresets": [
    { "name": "debug", "configurePreset": "debug", "output": { "outputOnFailure": true } },
    { "name": "release", "configurePreset": "release", "output": { "outputOnFailure": true } }
  ]
}
]]
end

local function readme(spec)
  return '# '
    .. spec.name
    .. '\n\n'
    .. 'C++'
    .. spec.standard
    .. ' with CMake '
    .. (spec.std_modules and '4.4.0 through 4.4.4' or '3.30+')
    .. ', a recent compiler, and '
    .. spec.generator
    .. [[.
The selected language mode is requested strictly; availability of individual features depends on
the compiler and standard library. Run the Rivet doctor before configuring.

```sh
cmake --preset debug
cmake --build --preset debug
ctest --preset debug
cmake --build --preset debug --target format
```

If Rivet created compiler-specific `CMakeUserPresets.json`, configure with
`cmake --preset local-debug` (or `local-release`) instead. The shared build/test
presets still address the matching `build/debug` or `build/release` directory.
The CLI and editor pick the local preset automatically. `just` is optional.

The example partitions work into balanced worker ranges; its CTest check verifies
coverage boundaries without third-party dependencies. It does not create threads.
Keep platform/render/compute features in their own directories as they emerge.

## Files and targets

`.rivet.json` records files, target ownership, module names, and dependencies.
Rivet regenerates only `cmake/RivetTargets.cmake` and
`cmake/Dependencies.cmake` during file/target/dependency operations. Extend the root
`CMakeLists.txt` and `cmake/Options.cmake` directly for your own build logic.
Source lists are explicit: a new file must be registered to compile it.

For named modules, the interface contains `export module project.feature;` and
exported declarations and optionally definitions. Single-file modules keep both
in the interface; split modules use a `.cpp` implementation with `module project.feature;`.
Consumers use `import project.feature;` and link the owning library. CMake lists
interfaces in a `PUBLIC FILE_SET ... TYPE CXX_MODULES`; implementations are ordinary
`PRIVATE` sources. Use Ninja for modules and a compiler with dependency scanning.
]]
    .. (spec.std_modules and [[
Standard-library modules are enabled separately from the project's own modules.
Sources use `import std;`; module units place it after `export module name;` or
`module name;`. Put local/third-party `#include`s before imports, or before the
module declaration in a global module fragment. Headers remain self-contained and
use ordinary includes when they need standard-library declarations.

`cmake/StandardModules.cmake` enables CMake's experimental gate before compiler
discovery, then checks the selected standard and the library's module metadata.
Its version gate is verified for CMake 4.4.0 through 4.4.4; a different release
requires updating the helper against that release's official experimental guide.
Missing libc++ metadata is discovered beside the selected LLVM compiler when
possible. Explicit `CMAKE_CXX_STDLIB_MODULES_JSON` in `CMakeUserPresets.json` takes
precedence. The helper preserves the selected compiler and standard library.

Configure and build once before expecting clangd to resolve `std`. CMake creates
the compiled module files during the build; changing module interfaces may require
rebuilding them before editor diagnostics update. No toolchain is downloaded.

]] or [[Use standard-library `#include`s (before imports or in the global module fragment)
until you deliberately opt into the separate toolchain requirements of `import std`.

]])
    .. [[For headers, add a source/header pair or a class template. Public library layout
uses `include/` and target include directories; feature layout co-locates files.
The selected guard is ]]
    .. spec.header_guard
    .. [[ and clang-format style is ]]
    .. spec.style
    .. [[.
Formatting style is independent of architecture, naming conventions, and domain.

## Dependencies and configuration

CPM downloads nothing until you register a dependency and configure. Supply an
explicit release tag or immutable commit, its exported CMake target, and the local
target to link. CPM itself is pinned by SHA256. Sources are cached under `.cache/CPM`;
an immutable commit provides stronger reproducibility than a movable tag.

Use the editor's CMake cache interface, `cmake-gui -S . -B build/debug`, or
`ccmake -S . -B build/debug` after initial configure. `BUILD_TESTING`,
`RIVET_WARNINGS`, and `RIVET_SANITIZERS` are useful starting options.
Keep machine-specific compiler paths and local cache choices in
`CMakeUserPresets.json`. Rivet refreshes `.cache/rivet/compile_commands.json` from the active build after configure.
Run configure/build through Rivet to prepare clangd, or set CompilationDatabase
in `.clangd` explicitly when using CMake directly.
]]
end

function M.plan(opts)
  local spec = M.normalize(opts)
  assert(
    #spec.targets == 0 and #spec.files == 0,
    'plan expects a new project; use mutation operations for an existing manifest'
  )
  local files = {}
  initial_sources(spec, files)
  require('rivet.languages.cpp_profiles').apply(spec, files)
  local defaults = {
    ['CMakeLists.txt'] = 'cmake_minimum_required(VERSION '
      .. (spec.std_modules and '4.4' or '3.30')
      .. ')\n'
      .. (spec.std_modules and 'include(cmake/StandardModules.cmake)\n' or '')
      .. 'project('
      .. spec.name
      .. ' VERSION 0.1.0 LANGUAGES CXX)\n'
      .. (spec.std_modules and ('rivet_check_std_modules(' .. spec.standard .. ')\n') or '')
      .. '\nset(CMAKE_EXPORT_COMPILE_COMMANDS ON)\nset(CMAKE_CXX_SCAN_FOR_MODULES '
      .. ((spec.modules or spec.std_modules) and 'ON' or 'OFF')
      .. ')\ninclude(CTest)\ninclude(cmake/Options.cmake)\ninclude(cmake/Dependencies.cmake)\ninclude(cmake/RivetTargets.cmake)\n\n# Add hand-written project extensions here.\n',
    ['CMakePresets.json'] = presets(spec),
    ['cmake/Options.cmake'] = cmake_options,
    ['cmake/RivetTargets.cmake'] = targets_cmake(spec),
    ['cmake/Dependencies.cmake'] = dependencies_cmake(spec),
    ['cmake/CPM.cmake'] = bootstrap,
    ['.clang-format'] = 'BasedOnStyle: ' .. spec.style .. '\n',
    ['.clang-tidy'] = "Checks: '-*,clang-analyzer-*,bugprone-*,performance-*,modernize-use-nullptr,modernize-use-override'\nWarningsAsErrors: ''\nHeaderFilterRegex: '.*'\n",
    ['.clangd'] = 'CompileFlags:\n  CompilationDatabase: .cache/rivet\n',

    ['.editorconfig'] = 'root = true\n\n[*]\ncharset = utf-8\nend_of_line = lf\ninsert_final_newline = true\ntrim_trailing_whitespace = true\nindent_style = space\nindent_size = '
      .. ((spec.style == 'WebKit' or spec.style == 'Microsoft') and '4' or '2')
      .. '\n',
    ['README.md'] = readme(spec),
    ['AGENTS.md'] = '# Project conventions\n\nC++'
      .. spec.standard
      .. '; '
      .. spec.style
      .. ' formatting; '
      .. spec.layout
      .. ' layout; '
      .. (spec.modules and 'named C++ modules' or 'headers with ' .. spec.header_guard .. ' guards')
      .. (spec.std_modules and '; standard-library import std enabled' or '; standard-library headers')
      .. [[.
Read README.md and .rivet.json before editing the build.
Use Rivet file/target/dependency operations to keep explicit source lists in sync.
The manifest owns cmake/RivetTargets.cmake and cmake/Dependencies.cmake;
do not hand-edit them unless updating the manifest in the same change.
Keep custom build logic in CMakeLists.txt or cmake/Options.cmake.
Module interfaces belong to CXX_MODULES file sets; implementations are ordinary sources.
Never switch standard, compiler, package versions, or formatting style silently.
Keep dependencies versioned and machine paths in ignored CMakeUserPresets.json.
Configure, build, and run CTest after changing modules or target relationships.
Review generated diffs before applying AI suggestions; do not execute downloaded code
or add a dependency merely to answer a question about the build.
]],
    ['justfile'] = [[# Optional command shortcuts; prefer the selected machine-local compiler.
configure preset="debug":
    #!/usr/bin/env sh
    set -eu
    chosen="{{preset}}"
    if cmake --list-presets | grep -Fq '"local-{{preset}}"'; then
      chosen="local-{{preset}}"
    fi
    cmake --preset "$chosen"

build preset="debug": (configure preset)
    cmake --build --preset {{preset}}

test preset="debug": (build preset)
    ctest --preset {{preset}}

fmt: (configure "debug")
    cmake --build --preset debug --target format
]]
      .. (
        spec.kind == 'app'
          and ('\nrun preset="debug": (build preset)\n    ./build/{{preset}}/' .. spec.name .. '\n')
        or ''
      ),
  }
  if spec.profile ~= 'general' then
    defaults['CMakeLists.txt'] = defaults['CMakeLists.txt']:gsub(
      'include%(cmake/RivetTargets.cmake%)',
      'include(cmake/ProfileSetup.cmake)\ninclude(cmake/RivetTargets.cmake)\ninclude(cmake/Profile.cmake)'
    )
  end
  if spec.std_modules then
    defaults['cmake/StandardModules.cmake'] = require('rivet.languages.cpp_std')
  end
  for filename, content in pairs(defaults) do
    -- Configuration dotfiles are intentionally generated but never accepted as source paths.
    files[filename] = content
    spec.files[#spec.files + 1] = filename
  end
  table.sort(spec.files)
  return { spec = spec, files = files, managed = copy(managed) }
end

function M.add_file(existing, opts)
  local spec = M.normalize(existing)
  local target = target_for(spec, opts.target)
  local kind = enum(
    opts.kind or 'source',
    { 'source', 'c_source', 'c_header', 'header', 'pair', 'class', 'module', 'module_impl' },
    'file kind'
  )
  local raw = path(assert(opts.name, 'file name is required'))
  raw = raw:gsub('%.cppm$', ''):gsub('%.cpp$', ''):gsub('%.hpp$', '')
  local basename = identifier(raw:match('([^/]+)$'), 'file name')
  local stem = raw:find('/', 1, true) and raw
    or (target.source_dir == '.' and raw or target.source_dir .. '/' .. raw)
  local files, body = {}, ''
  if kind == 'c_source' or kind == 'c_header' then
    if kind == 'c_source' then
      add_file(
        spec,
        files,
        stem .. '.c',
        'int ' .. basename .. '(void) { return 42; }\n',
        target,
        'sources'
      )
      spec.c_standard = spec.c_standard or 17
    else
      add_file(
        spec,
        files,
        stem .. '.h',
        '#pragma once\n#ifdef __cplusplus\nextern "C" {\n#endif\nint '
          .. basename
          .. '(void);\n#ifdef __cplusplus\n}\n#endif\n',
        target,
        'headers'
      )
    end
  elseif kind == 'module' or kind == 'module_impl' then
    assert(spec.modules, 'module templates require a modules project')
    local mod = module_name(
      opts.module or (kind == 'module' and spec.name .. '.' .. raw:gsub('/', '.') or '')
    )
    if kind == 'module' then
      assert(not spec.module_names[mod], 'module already exists: ' .. mod)
      body = module_start(spec, mod, true)
        .. 'export namespace '
        .. spec.name
        .. ' {\n// Add exported declarations and definitions here.\n}\n'
      add_file(spec, files, stem .. '.cppm', body, target, 'modules')
      spec.module_names[mod] = { target = target.name, path = stem .. '.cppm' }
    else
      local owner = assert(spec.module_names[mod], 'unknown module: ' .. mod)
      assert(
        owner.target == target.name,
        'module implementation must belong to its interface target'
      )
      add_file(
        spec,
        files,
        stem .. '.cpp',
        module_start(spec, mod, false)
          .. 'namespace '
          .. spec.name
          .. " {\n// Define the module's declarations here.\n}\n",
        target,
        'sources'
      )
    end
  elseif kind == 'source' then
    add_file(
      spec,
      files,
      stem .. '.cpp',
      std_import(spec) .. 'namespace ' .. spec.name .. ' {\n// Add implementation here.\n}\n',
      target,
      'sources'
    )
  else
    local header_stem, include_name = stem, basename .. '.hpp'
    if spec.layout == 'library' and target.type == 'static' and not raw:find('/', 1, true) then
      local suffix = target.source_dir == 'src' and '' or '/' .. target.name
      header_stem = 'include/' .. spec.name .. suffix .. '/' .. raw
      include_name = spec.name .. suffix .. '/' .. basename .. '.hpp'
      add_unique(target.include_dirs, 'include')
    else
      add_unique(target.include_dirs, stem:match('^(.*)/[^/]+$') or '.')
    end
    local declaration, definition
    if kind == 'class' then
      declaration = 'class ' .. basename .. ' {\npublic:\n  ' .. basename .. '();\n};\n'
      definition = basename .. '::' .. basename .. '() = default;\n'
    else
      declaration = kind == 'header' and '// Add declarations here.\n'
        or 'void ' .. basename .. '();\n'
      definition = 'void ' .. basename .. '() {\n}\n'
    end
    add_file(
      spec,
      files,
      header_stem .. '.hpp',
      header(
        spec,
        header_stem .. '.hpp',
        'namespace ' .. spec.name .. ' {\n' .. declaration .. '} // namespace ' .. spec.name .. '\n'
      ),
      target,
      'headers'
    )
    if kind == 'pair' or kind == 'class' then
      add_file(
        spec,
        files,
        stem .. '.cpp',
        '#include "'
          .. include_name
          .. '"\n\n'
          .. std_import(spec)
          .. 'namespace '
          .. spec.name
          .. ' {\n'
          .. definition
          .. '} // namespace '
          .. spec.name
          .. '\n',
        target,
        'sources'
      )
    end
  end
  files['cmake/RivetTargets.cmake'] = targets_cmake(spec)
  table.sort(spec.files)
  return { spec = spec, files = files, managed = copy(managed) }
end

function M.add_target(existing, opts)
  local spec = M.normalize(existing)
  local name = identifier(opts.name, 'target name')
  local kind = enum(
    opts.kind or (opts.type == 'executable' and 'app' or 'library'),
    { 'app', 'library' },
    'target kind'
  )
  if opts.type then
    enum(opts.type, { 'executable', 'static' }, 'target type')
  end
  local dir = spec.layout == 'flat' and '.' or (kind == 'app' and 'app/' or 'src/') .. name
  local target = new_target(spec, name, kind, dir)
  local files = {}
  if kind == 'app' then
    add_file(
      spec,
      files,
      (dir == '.' and name or dir .. '/main') .. '.cpp',
      std_import(spec) .. 'int main() {\n  return 0;\n}\n',
      target,
      'sources'
    )
  else
    add_file(
      spec,
      files,
      (dir == '.' and name or dir .. '/' .. name) .. '.cpp',
      std_import(spec)
        .. 'namespace '
        .. spec.name
        .. ' {\n// Add library implementation here.\n}\n',
      target,
      'sources'
    )
  end
  if opts.link_to then
    local consumer = target_for(spec, opts.link_to)
    assert(
      kind == 'library' and consumer.name ~= target.name,
      'only a library may be linked to another target'
    )
    add_unique(consumer.links, name)
  end
  files['cmake/RivetTargets.cmake'] = targets_cmake(spec)
  table.sort(spec.files)
  return { spec = spec, files = files, managed = copy(managed) }
end

function M.add_dependency(existing, opts)
  local spec = M.normalize(existing)
  local dep = {
    name = identifier(opts.name, 'package name'),
    repository = opts.repository,
    tag = opts.tag or opts.version,
    target = cmake_target(opts.target),
    link_to = target_for(spec, opts.link_to).name,
  }
  for _, old in ipairs(spec.dependencies) do
    assert(old.name ~= dep.name, 'dependency already exists: ' .. dep.name)
  end
  spec.dependencies[#spec.dependencies + 1] = dep
  add_unique(target_for(spec, dep.link_to).links, dep.target)
  spec = M.normalize(spec)
  return {
    spec = spec,
    managed = copy(managed),
    files = {
      ['cmake/Dependencies.cmake'] = dependencies_cmake(spec),
      ['cmake/RivetTargets.cmake'] = targets_cmake(spec),
    },
  }
end

function M.lifecycle(spec, opts, contents)
  local plan = require('rivet.lifecycle').plan(spec, opts, contents, targets_cmake)
  plan.spec = M.normalize(plan.spec)
  return plan
end
return M
