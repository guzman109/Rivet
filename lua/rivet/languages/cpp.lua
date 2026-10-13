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

function M.formatter(spec, filename, tools, context)
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
    local style = context
        and context.existing
        and require('rivet.runtime').read(context.root .. '/.clang-format')
        and ('file:' .. context.root .. '/.clang-format')
      or spec.style
    return { tools.clang_format, '--style=' .. style, '--assume-filename=' .. filename }
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

local spec_helpers = require('rivet.languages.cpp_spec')
local cpp_cmake = require('rivet.languages.cpp_cmake')
local copy = spec_helpers.copy
local identifier = spec_helpers.identifier
local enum = spec_helpers.enum
local path = spec_helpers.path
local module_name = spec_helpers.module_name
local cmake_target = spec_helpers.cmake_target
local list = spec_helpers.list
local add_unique = spec_helpers.add_unique
local targets_cmake = cpp_cmake.targets_cmake
local bootstrap = cpp_cmake.bootstrap
local dependencies_cmake = cpp_cmake.dependencies_cmake
local cmake_options = cpp_cmake.cmake_options
local presets = cpp_cmake.presets
M.default_name = spec_helpers.default_name
M.normalize = spec_helpers.normalize

local function target_for(spec, name)
  if name == nil then
    for _, target in ipairs(spec.targets) do
      if target.type == 'static' and not target.test and not target.external then
        return target
      end
    end
  end
  for _, target in ipairs(spec.targets) do
    if target.name == name then
      assert(
        not target.external,
        'This embedding target is defined in its standalone CMake include; edit the example and include together'
      )
      return target
    end
  end
  error('unknown target: ' .. tostring(name), 2)
end

function M.upgrade_files(existing)
  local spec = M.normalize(existing)
  local fresh = copy(spec)
  fresh.files, fresh.targets, fresh.module_names, fresh.dependencies = {}, {}, {}, {}
  local defaults, result = M.plan(fresh).files, {}
  for path, content in pairs(defaults) do
    if
      path == 'CMakeLists.txt'
      or path == 'CMakePresets.json'
      or path == 'README.md'
      or path == 'AGENTS.md'
      or path == 'justfile'
      or path:match('^%.')
      or path:match('^cmake/')
    then
      result[path] = content
    end
  end
  result['cmake/RivetTargets.cmake'] = targets_cmake(spec)
  result['cmake/Dependencies.cmake'] = dependencies_cmake(spec)
  return result
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
  local kind = enum(opts.kind or 'source', {
    'source',
    'c_source',
    'c_header',
    'c_pair',
    'header',
    'pair',
    'class',
    'module',
    'module_pair',
    'module_impl',
  }, 'file kind')
  local raw = path(assert(opts.name, 'file name is required'))
  raw = raw
    :gsub('%.cppm$', '')
    :gsub('%.cpp$', '')
    :gsub('%.cc$', '')
    :gsub('%.cxx$', '')
    :gsub('%.hpp$', '')
    :gsub('%.c$', '')
    :gsub('%.h$', '')
  local basename = identifier(raw:match('([^/]+)$'), 'file name')
  local stem = raw:find('/', 1, true) and raw
    or (target.source_dir == '.' and raw or target.source_dir .. '/' .. raw)
  local files, body = {}, ''
  if kind == 'c_source' or kind == 'c_header' or kind == 'c_pair' then
    if kind == 'c_source' or kind == 'c_pair' then
      add_file(
        spec,
        files,
        stem .. '.c',
        (kind == 'c_pair' and '#include "' .. basename .. '.h"\n\n' or '')
          .. 'int '
          .. basename
          .. '(void) { return 42; }\n',
        target,
        'sources'
      )
      spec.c_standard = spec.c_standard or 17
    end
    if kind == 'c_header' or kind == 'c_pair' then
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
  elseif kind == 'module' or kind == 'module_pair' or kind == 'module_impl' then
    assert(spec.modules, 'module templates require a modules project')
    local mod = module_name(
      opts.module or (kind ~= 'module_impl' and spec.name .. '.' .. raw:gsub('/', '.') or '')
    )
    if kind == 'module' or kind == 'module_pair' then
      assert(not spec.module_names[mod], 'module already exists: ' .. mod)
      body = module_start(spec, mod, true)
        .. 'export namespace '
        .. spec.name
        .. ' {\n'
        .. (kind == 'module_pair' and ('int ' .. basename .. '();\n') or '// Add exported declarations and definitions here.\n')
        .. '}\n'
      add_file(spec, files, stem .. '.cppm', body, target, 'modules')
      spec.module_names[mod] = { target = target.name, path = stem .. '.cppm' }
      if kind == 'module_pair' then
        add_file(
          spec,
          files,
          stem .. '.cpp',
          module_start(spec, mod, false)
            .. 'namespace '
            .. spec.name
            .. ' {\nint '
            .. basename
            .. '() { return 42; }\n}\n',
          target,
          'sources'
        )
      end
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
