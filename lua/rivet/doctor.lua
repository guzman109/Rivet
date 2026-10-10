-- Read the selected project configuration. Never configure, build or install from Doctor.
local rt, json = require('rivet.runtime'), require('rivet.json')
local M = {}
local function version(executable)
  if not executable then
    return '', nil
  end
  local result = rt.run({ executable, '--version' }, { timeout = 3000 })
  local line = (result.stdout .. result.stderr):match('[^\r\n]+') or ''
  return line, tonumber(line:match('version (%d+)') or line:match('(%d+)%.'))
end
local function same_path(a, b)
  local function real(path)
    local result = rt.run({ 'realpath', path })
    return result.code == 0 and result.stdout:gsub('%s+$', '') or path
  end
  return real(a) == real(b)
end
function M.inspect(root, preset, options)
  options = options or {}
  local report = {}
  local function add(level, message)
    report[#report + 1] = { level = level, message = message }
  end
  local tools = rt.detect_tools()
  for _, name in ipairs({ 'cmake', 'ninja', 'clangd', 'clang_format', 'git' }) do
    add(tools[name] and 'info' or 'warn', name .. ': ' .. (tools[name] or 'not detected'))
  end
  if not root then
    add('info', 'Open an Rivet project to inspect its selected preset and actual toolchain')
    return report
  end
  local project = require('rivet.project')
  local ok, spec = pcall(project.inspect, root)
  if not ok then
    add('error', tostring(spec))
    return report
  end
  local valid, selected = pcall(
    require('rivet.cmake').context,
    root,
    preset,
    { tasks = true, task = 'build', build_preset = options.build_preset }
  )
  if not valid then
    add('error', tostring(selected))
    return report
  end
  add(
    'info',
    'Project: '
      .. root
      .. ' · '
      .. (spec.standard and ('C++' .. spec.standard) or 'existing CMake project')
      .. ' · preset '
      .. selected.name
  )
  add('info', 'Build directory: ' .. selected.binaryDir)
  local cmake_banner = version(selected.db.cmake)
  local major, minor, patch = cmake_banner:match('(%d+)%.(%d+)%.(%d+)')
  if major then
    local supported = tonumber(major) > 3 or tonumber(major) == 3 and tonumber(minor) >= 30
    if not spec.external then
      add(supported and 'ok' or 'error', 'Generated projects require CMake 3.30+: ' .. cmake_banner)
    end
    if spec.std_modules then
      local verified = major == '4' and minor == '4' and tonumber(patch) <= 4
      add(
        verified and 'ok' or 'error',
        'import std gate is verified for CMake 4.4.0–4.4.4; selected ' .. cmake_banner
      )
    end
  end
  local cache = {}
  local raw_cache = rt.read(rt.confined(selected.binaryDir, 'CMakeCache.txt'))
  for line in (raw_cache or ''):gmatch('[^\r\n]+') do
    local name, value = line:match('^([^/#:][^:]*):[^=]+=(.*)$')
    if name then
      cache[name] = value
    end
  end
  if cache.CMAKE_HOME_DIRECTORY and not same_path(cache.CMAKE_HOME_DIRECTORY, root) then
    add(
      'error',
      'This cache belongs to ' .. cache.CMAKE_HOME_DIRECTORY .. '; select a fresh build directory'
    )
    return report
  end
  local api, api_error = require('rivet.file_api').read(selected.binaryDir)
  if not api then
    add('warn', api_error)
  end
  local actual
  for _, item in ipairs(api and api.toolchains and api.toolchains.toolchains or {}) do
    if item.language == 'CXX' then
      actual = item.compiler
    end
  end
  local requested = selected.cache.CMAKE_CXX_COMPILER or selected.environment.CXX
  local function requested_executable()
    return require('rivet.presets').executable(requested, selected.environment, selected.db.root)
  end
  local compiler = actual and actual.path or cache.CMAKE_CXX_COMPILER
  if not compiler then
    if selected.toolchainFile or selected.cache.CMAKE_TOOLCHAIN_FILE then
      add(
        'warn',
        'Toolchain file: '
          .. (selected.toolchainFile or selected.cache.CMAKE_TOOLCHAIN_FILE)
          .. '. Configure this preset to discover its actual compiler; Doctor will not guess from PATH'
      )
    elseif requested and requested ~= false then
      compiler = requested_executable()
      add(
        compiler and 'info' or selected.cache.CMAKE_CXX_COMPILER and 'error' or 'warn',
        'Requested compiler (not configured yet): '
          .. requested
          .. '. Configure to resolve any wrapper arguments'
      )
    else
      add(
        'warn',
        'Preset compiler is not configured. Run configure to let CMake select it, then run Doctor again'
      )
    end
  else
    add(
      'ok',
      'Configured compiler: '
        .. compiler
        .. (actual and (' · ' .. (actual.id or '') .. ' ' .. (actual.version or '')) or '')
    )
    if requested and requested ~= false then
      local path = requested_executable()
      if not path then
        add(
          selected.cache.CMAKE_CXX_COMPILER and 'error' or 'warn',
          'Preset compiler is unavailable: '
            .. requested
            .. '; the existing cache still uses '
            .. compiler
        )
      elseif not same_path(path, compiler) then
        add(
          'error',
          'Preset requests '
            .. path
            .. ' but the cache uses '
            .. compiler
            .. '; use a fresh build directory'
        )
      end
    end
  end
  if compiler and not rt.executable(compiler) then
    add('error', 'Configured compiler no longer exists or is not executable: ' .. compiler)
    compiler = nil
  end
  local banner, compiler_major = version(compiler)
  if compiler and spec.standard then
    add('info', banner)
    local command = require('rivet.presets').environment_command(
      { compiler, '-std=c++' .. spec.standard, '-x', 'c++', '-fsyntax-only', '-' },
      selected.environment
    )
    local probe =
      rt.run(command, { cwd = root, stdin = 'int main() { return 0; }\n', timeout = 10000 })
    add(
      probe.code == 0 and 'ok' or 'error',
      probe.code == 0
          and ('Compiler accepts C++' .. spec.standard .. ' (this probe does not test every language/library feature)')
        or ('C++' .. spec.standard .. ' probe failed: ' .. probe.stderr)
    )
  end
  if spec.modules or spec.std_modules then
    local generator = cache.CMAKE_GENERATOR or selected.value.generator
    add(
      (generator == 'Ninja' or generator == 'Ninja Multi-Config') and 'ok' or 'error',
      'Module generator: ' .. tostring(generator)
    )
    if generator == 'Ninja' or generator == 'Ninja Multi-Config' then
      local ninja = cache.CMAKE_MAKE_PROGRAM or tools.ninja
      local text = ninja and rt.run({ ninja, '--version' }, { timeout = 3000 }).stdout or ''
      local major, minor = text:match('(%d+)%.(%d+)')
      local supported = major
        and (tonumber(major) > 1 or tonumber(major) == 1 and tonumber(minor) >= 11)
      add(
        supported and 'ok' or 'error',
        'Module scanning needs Ninja 1.11+: ' .. text:gsub('%s+$', '')
      )
    end
    if banner:find('[Cc]lang') then
      local scanner = cache.CMAKE_CXX_COMPILER_CLANG_SCAN_DEPS
      if not scanner and compiler then
        scanner = rt.executable(rt.join(rt.dirname(compiler), 'clang-scan-deps'))
      end
      if scanner and scanner:match('NOTFOUND$') then
        scanner = nil
      end
      scanner = scanner and rt.executable(scanner)
      local scanner_version, scanner_major = version(scanner)
      if not scanner or scanner:match('NOTFOUND$') then
        add(
          'error',
          'No clang-scan-deps for the selected compiler. Install/select a complete matching LLVM toolchain'
        )
      elseif scanner_major ~= compiler_major then
        add(
          'error',
          'Compiler/scanner mismatch: '
            .. banner
            .. ' vs '
            .. scanner_version
            .. ' ('
            .. scanner
            .. ')'
        )
      else
        add('ok', 'Matching Clang scanner: ' .. scanner)
      end
      if banner:find('Apple clang', 1, true) or compiler_major and compiler_major < 16 then
        add(
          'error',
          'This Clang does not meet the named-module toolchain requirements. Select a recent upstream LLVM toolchain'
        )
      end
    end
    add(
      'info',
      'A successful project build is the module capability check; configure and the syntax probe alone do not prove it'
    )
  end
  if api and api.codemodel then
    for _, configuration in ipairs(api.codemodel.configurations or {}) do
      for _, entry in ipairs(configuration.targets or {}) do
        local data = api.read(entry.jsonFile)
        for _, group in ipairs(data.compileGroups or {}) do
          if
            group.language == 'CXX'
            and group.languageStandard
            and spec.standard
            and tonumber(group.languageStandard.standard) ~= spec.standard
          then
            add(
              'error',
              entry.name
                .. ' is configured for C++'
                .. group.languageStandard.standard
                .. ' but the manifest requests C++'
                .. spec.standard
            )
          end
        end
      end
    end
  end
  if spec.std_modules then
    local cmake_version = raw_cache
      and cache.CMAKE_CACHE_MAJOR_VERSION
      and table.concat({
        cache.CMAKE_CACHE_MAJOR_VERSION,
        cache.CMAKE_CACHE_MINOR_VERSION,
        cache.CMAKE_CACHE_PATCH_VERSION,
      }, '.')
    local metadata = cmake_version
        and rt.read(
          rt.confined(
            selected.binaryDir,
            'CMakeFiles/' .. cmake_version .. '/CMakeCXXCompiler.cmake'
          )
        )
      or ''
    local standards = metadata and metadata:match('set%(CMAKE_CXX_COMPILER_IMPORT_STD "([^"]*)"%)')
      or ''
    local advertised = (';' .. standards .. ';'):find(';' .. spec.standard .. ';', 1, true)
    add(
      advertised and 'ok' or 'warn',
      'Configured import std standards: '
        .. (
          standards ~= '' and standards
          or 'not discovered; configure the selected preset and inspect its error'
        )
    )
  end
  local database = rt.read(rt.confined(selected.binaryDir, 'compile_commands.json'))
  if database then
    database = require('rivet.cmake').compilation_database(database, selected.configuration)
  end
  add(
    database and 'ok' or 'warn',
    database and 'Selected build has a compilation database'
      or 'No compilation database. Configure with CMAKE_EXPORT_COMPILE_COMMANDS=ON using Ninja or Make'
  )
  local clangd_config = rt.read(rt.confined(root, '.clangd')) or ''
  local database_path = clangd_config:match('CompilationDatabase:%s*([^\r\n]+)')
  local active = rt.read(rt.confined(root, '.cache/rivet/selection.json'))
  if database_path == '.cache/rivet' then
    local valid_state, state = pcall(json.decode, active or '')
    local current = valid_state
      and state.binaryDir == selected.binaryDir
      and state.configuration == selected.configuration
      and rt.read(rt.confined(root, '.cache/rivet/compile_commands.json')) == database
    add(
      current and database and 'ok' or 'warn',
      current and database and 'clangd compilation database follows the selected preset'
        or 'clangd database is missing or stale for this preset. Run configure through Rivet'
    )
  else
    add(
      'warn',
      '.clangd CompilationDatabase is '
        .. tostring(database_path)
        .. '; set it to .cache/rivet to follow Rivet, or verify your custom path manually'
    )
  end
  local clangd = options.clangd or tools.clangd
  local clangd_version, clangd_major = version(clangd)
  if clangd then
    add('info', 'clangd: ' .. clangd_version .. ' (' .. clangd .. ')')
    if (spec.modules or spec.std_modules) and compiler_major and clangd_major ~= compiler_major then
      add(
        'warn',
        'clangd and the selected compiler have different major versions. Matching LLVM versions reduce module artifact incompatibilities'
      )
    end
  end
  if spec.modules or spec.std_modules then
    add(
      options.module_flag and 'ok' or 'warn',
      options.module_flag and 'Attached clangd enables experimental module support'
        or 'Enable --experimental-modules-support in your clangd LSP command, then build module artifacts. Doctor cannot verify this flag without an attached client'
    )
  end
  for _, entry in ipairs(require('rivet.profile_doctor').inspect(spec, selected, cache)) do
    report[#report + 1] = entry
  end
  return report
end
return M
