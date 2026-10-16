-- Shared CLI vocabulary for help, parsing, and shell completion generation.
local M = { commands = {}, order = {}, options = {} }
local function option(name, value, description, choices, path)
  M.options[name] =
    { name = name, value = value, description = description, choices = choices, path = path }
end
option('help', nil, 'Show command help')
option('root', 'PATH', 'Select the project root', nil, 'directory')
option('preview', nil, 'Review changes without writing or building')
option('interactive', nil, 'Choose project settings interactively')
option('build', nil, 'Build after creating the project')
option('name', 'NAME', 'Override the name inferred from the folder')
option(
  'language',
  'LANGUAGE',
  'Choose the language',
  { 'cpp', 'c', 'python', 'rust', 'swift', 'lua' }
)
option(
  'profile',
  'PROFILE',
  'Choose a C++ workload',
  { 'general', 'cpu', 'openmp', 'mpi', 'cuda', 'metal', 'webgpu', 'vulkan', 'opengl' }
)
option('standard', 'STANDARD', 'C++: 17/20/23/26; C: 11/17/23', { '11', '17', '20', '23', '26' })
option('cuda-standard', 'STANDARD', 'CUDA language standard', { '17', '20', '23' })
option(
  'cuda-architectures',
  'ARCHS',
  'CUDA architectures; quote lists like "80;90"',
  { 'native', 'all', 'all-major' }
)
option('modules', 'BOOL', 'Generate named C++ modules', { 'true', 'false' })
option('std-modules', 'BOOL', 'Use import std; requires toolchain support', { 'true', 'false' })
option('module-layout', 'LAYOUT', 'Arrange C++ module units', { 'single', 'split' })
option(
  'style',
  'STYLE',
  'Choose formatting style',
  { 'LLVM', 'Google', 'Chromium', 'Mozilla', 'WebKit', 'Microsoft', 'GNU' }
)
option('layout', 'LAYOUT', 'Arrange project sources', { 'feature', 'library', 'flat' })
option('kind', 'KIND', 'Choose project or file kind')
option('header-guard', 'GUARD', 'Choose header guards', { 'pragma', 'ifndef' })
option('generator', 'GENERATOR', 'Choose CMake generator', { 'Ninja', 'Unix Makefiles' })
option('compiler', 'PATH', 'C++ compiler executable', nil, 'file')
option('manager', 'MANAGER', 'Python environment manager', { 'python', 'uv' })
option('edition', 'EDITION', 'Rust edition', { '2021', '2024' })
option('runtime', 'RUNTIME', 'Lua runtime', { 'lua', 'luajit', 'neovim' })
option('git', 'BOOL', 'Initialize Git or reuse enclosing repository', { 'true', 'false' })
option(
  'license',
  'LICENSE',
  'Project license',
  { 'none', 'MIT', 'Apache-2.0', 'BSD-3-Clause', 'GPL-3.0-only' }
)
option('license-holder', 'NAME', 'Copyright holder')
option('license-year', 'YEAR', 'Copyright year; defaults to current year')
option('target', 'NAME', 'Select a project target')
option('module', 'NAME', 'Existing C++ module name')
option('repository', 'OWNER/REPO', 'Dependency repository')
option('tag', 'PIN', 'Pinned dependency revision')
option('version', 'PIN', 'Alias for --tag')
option('link-to', 'NAME', 'Target to link the library into')
option('from', 'PATH', 'Source path or module name')
option('to', 'PATH', 'Destination path or module name')
option('preset', 'NAME', 'Configure preset or native debug/release choice')
option('build-preset', 'NAME', 'CMake build preset')
option('test-preset', 'NAME', 'CTest preset')
option('build-target', 'NAME', 'Native build target')
local function command(name, group, usage, description, options, notes, positional)
  M.order[#M.order + 1] = name
  M.commands[name] = {
    name = name,
    group = group,
    usage = usage,
    description = description,
    options = options or {},
    notes = notes,
    positional = positional,
  }
end
command(
  'new',
  'Create',
  'ROOT [OPTIONS]',
  'Create a project',
  {
    'name',
    'language',
    'kind',
    'interactive',
    'preview',
    'build',
    'preset',
    'profile',
    'standard',
    'modules',
    'std-modules',
    'module-layout',
    'cuda-standard',
    'cuda-architectures',
    'style',
    'layout',
    'header-guard',
    'generator',
    'compiler',
    'manager',
    'edition',
    'runtime',
    'git',
    'license',
    'license-holder',
    'license-year',
    'root',
  },
  [[Defaults: C++26, named modules, standard-library headers, feature layout,
Ninja, LLVM style. Use new . to create in the current folder.
Rust also supports kind workspace; Lua also supports kind plugin.
Boolean options take a separate true or false value.
Git is opt-in; nothing is staged or committed. Ignore rules are always generated.
--preview never writes or builds. Failed builds leave files for correction.
Scaffolding downloads no packages. import std requires a compatible toolchain.]],
  'directory'
)
command(
  'file',
  'Create',
  'NAME [OPTIONS]',
  'Add a source file, class, or module',
  { 'kind', 'language', 'target', 'module', 'root', 'preview' },
  [[C++ kinds: source, header, pair, class, module, module_impl, module_pair,
c_source, c_header, c_pair. Lua kinds: module, script, embedded.
Other providers use their native source template.]]
)
command(
  'target',
  'Create',
  'NAME --kind app|library [OPTIONS]',
  'Add an application or library target',
  { 'kind', 'link-to', 'root', 'preview' }
)
command(
  'dependency',
  'Create',
  'NAME --repository OWNER/REPO --tag PIN [OPTIONS]',
  'Register a pinned dependency',
  { 'repository', 'tag', 'version', 'target', 'link-to', 'root', 'preview' },
  'CPM downloads only during configure after a dependency is explicitly added.'
)
local taskopts = { 'root', 'preset', 'target', 'build-preset', 'test-preset', 'build-target' }
for _, task in ipairs({
  { 'configure', 'Configure the project' },
  { 'build', 'Build the project' },
  { 'check', 'Check source code' },
  { 'test', 'Run tests' },
  { 'run', 'Run an application' },
  { 'format', 'Format source code' },
  { 'lint', 'Run the native linter' },
  { 'package', 'Package the project' },
  { 'xcode', 'Open the Swift Xcode workflow' },
}) do
  command(
    task[1],
    'Work',
    '[OPTIONS]',
    task[2],
    taskopts,
    [[CMake Build configures first; Test/Run configure and build first.
Native providers use their ecosystem tasks. Existing projects need no manifest.
After configure, .clangd follows the selected compilation database via
.cache/rivet; custom .clangd files are preserved.
Runtime argv/env/cwd are configured in .rivet.local.json.]]
  )
end
for _, task in ipairs({ 'benchmark', 'profile', 'submit', 'status', 'cancel' }) do
  command(
    task,
    'Hooks',
    '[OPTIONS]',
    'Run the configured ' .. task .. ' hook',
    taskopts,
    'Optional hook from .rivet.local.json; runs only when explicitly selected.'
  )
end
command(
  'move',
  'Maintain',
  'FROM TO [OPTIONS]',
  'Move a registered file',
  { 'from', 'to', 'root', 'preview' },
  nil,
  'file'
)
command(
  'remove',
  'Maintain',
  'PATH [OPTIONS]',
  'Remove a registered file',
  { 'from', 'root', 'preview' },
  nil,
  'file'
)
command(
  'module-rename',
  'Maintain',
  'FROM TO [OPTIONS]',
  'Rename a C++ module',
  { 'from', 'to', 'root', 'preview' }
)
command(
  'repair',
  'Maintain',
  'MANAGED_FILE [OPTIONS]',
  'Restore a managed file and save a backup',
  { 'root', 'preview' },
  nil,
  'file'
)
command(
  'migrate',
  'Maintain',
  '[OPTIONS]',
  'Migrate a former Outset project',
  { 'root', 'preview' }
)
command(
  'upgrade',
  'Maintain',
  '[OPTIONS]',
  'Update project templates while preserving edits',
  { 'root', 'preview' }
)
command(
  'config',
  'Inspect',
  '[TOOL [KEY VALUE]] [OPTIONS]',
  'Inspect or edit tool settings',
  { 'root', 'preview' },
  'Tools: clang-format, clang-tidy, clangd. Omit KEY VALUE to list settings.',
  { 'clang-format', 'clang-tidy', 'clangd' }
)
command(
  'cache',
  'Inspect',
  '[KEY VALUE] [OPTIONS]',
  'Inspect or edit the CMake cache',
  { 'root', 'preset' }
)
command('targets', 'Inspect', '[OPTIONS]', 'List available project targets', taskopts)
command(
  'doctor',
  'Inspect',
  '[OPTIONS]',
  'Check tools and project health',
  { 'root', 'preset', 'build-preset' }
)
command('styles', 'Inspect', '', 'Browse formatting styles')
command('layouts', 'Inspect', '', 'Browse source layouts')
command(
  'completions',
  'Shell',
  'fish|bash|zsh',
  'Print shell completion setup',
  {},
  [[Fish: rivet completions fish | source
Bash: source <(rivet completions bash)
Zsh:  autoload -Uz compinit && compinit
      source <(rivet completions zsh)
See the CLI guide for persistent installation.]],
  { 'fish', 'bash', 'zsh' }
)
command('help', 'Shell', '[COMMAND]', 'Show overview or command help')
function M.allowed()
  local allowed = {}
  for name in pairs(M.options) do
    allowed[name:gsub('-', '_')] = true
  end
  return allowed
end
function M.command_options(name)
  local result = {}
  for _, key in ipairs(M.commands[name].options) do
    local opt = M.options[key]
    local copy = {}
    for k, v in pairs(opt) do
      copy[k] = v
    end
    if key == 'kind' then
      copy.choices = name == 'new' and { 'app', 'library', 'workspace', 'plugin' }
        or name == 'file' and {
          'source',
          'header',
          'pair',
          'class',
          'module',
          'module_impl',
          'module_pair',
          'c_source',
          'c_header',
          'c_pair',
          'script',
          'embedded',
        }
        or { 'app', 'library' }
    elseif key == 'language' and name == 'file' then
      copy.choices = { 'cpp', 'c', 'lua' }
    end
    result[#result + 1] = copy
  end
  result[#result + 1] = M.options.help
  return result
end
function M.help(topic)
  local term = require('rivet.terminal')
  if topic then
    local cmd = assert(M.commands[topic], 'Unknown help topic: ' .. topic)
    term.heading('Rivet · ' .. topic)
    print('  ' .. cmd.description)
    term.heading('Usage')
    print(
      '  '
        .. term.paint('command', 'rivet ' .. topic .. (cmd.usage ~= '' and ' ' .. cmd.usage or ''))
    )
    term.heading('Options')
    for _, opt in ipairs(M.command_options(topic)) do
      term.row('--' .. opt.name .. (opt.value and ' ' .. opt.value or ''), opt.description)
      if opt.choices then
        print('      ' .. term.paint('muted', table.concat(opt.choices, ' | ')))
      end
    end
    if cmd.notes then
      term.heading('Notes')
      print(cmd.notes)
    end
  else
    term.heading('RIVET  /  Neovim-first project tools')
    print('  Create, build, and maintain projects from your terminal.')
    term.heading('Usage')
    print('  ' .. term.paint('command', 'rivet <command> [options]'))
    for _, group in ipairs({ 'Create', 'Work', 'Maintain', 'Inspect', 'Shell' }) do
      term.heading(group)
      for _, name in ipairs(M.order) do
        local cmd = M.commands[name]
        if cmd.group == group then
          term.row(name, cmd.description)
        end
      end
    end
    term.heading('Optional hooks')
    print('  benchmark · profile · submit · status · cancel')
    print('  Configure in .rivet.local.json; run only when explicitly selected.')
    term.heading('Quick start')
    print('  ' .. term.paint('command', 'rivet new . --interactive'))
    print('  ' .. term.paint('command', 'rivet build --preset debug'))
    print('  ' .. term.paint('command', 'rivet new --help'))
    term.heading('Common options')
    term.row('--root PATH', 'Select a project; default: nearest supported project')
    term.row('--help, -h', 'Show help for a command')
    term.row('--version', 'Show the installed version')
    print('\n  Use --preview on creation and mutation commands to review changes.')
  end
  print(
    '\n  '
      .. term.paint(
        'muted',
        'Color: RIVET_COLOR=auto|always|never · RIVET_THEME=dark|light · NO_COLOR'
      )
  )
end
return M
