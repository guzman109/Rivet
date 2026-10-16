local M = {}
local ref = require('rivet.cli_reference')
local quote = require('rivet.runtime').quote
local function choices(values)
  local result = {}
  for _, value in ipairs(values) do
    result[#result + 1] = quote(value)
  end
  return table.concat(result, ' ')
end
local function bash()
  local lines = {
    [[# Rivet completion; compatible with Bash 3.2+.
_rivet() {
  local cur prev command candidate
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  command="${COMP_WORDS[1]}"
  if [ "$COMP_CWORD" -eq 1 ]; then]],
  }
  local function add(s)
    lines[#lines + 1] = s
  end
  local function enum(values, indent)
    add(indent .. 'for candidate in ' .. choices(values) .. '; do')
    add(indent .. '  [[ "$candidate" == "$cur"* ]] && COMPREPLY+=("$candidate")')
    add(indent .. 'done')
  end
  local commands = { '--help', '-h', '--version' }
  for _, name in ipairs(ref.order) do
    commands[#commands + 1] = name
  end
  enum(commands, '    ')
  add('    return 0\n  fi\n  case "$command" in')
  for _, name in ipairs(ref.order) do
    add('    ' .. name .. ')\n      case "$prev" in')
    for _, opt in ipairs(ref.command_options(name)) do
      if opt.value then
        add('        --' .. opt.name .. ')')
        if opt.choices then
          enum(opt.choices, '          ')
        elseif opt.path then
          add(
            '          while IFS= read -r candidate; do COMPREPLY+=("$candidate"); done < <(compgen -'
              .. (opt.path == 'directory' and 'd' or 'f')
              .. ' -- "$cur")'
          )
        end
        add('          return 0 ;;')
      end
    end
    add('      esac\n      if [[ "$cur" == -* ]]; then')
    local opts = { '-h' }
    for _, opt in ipairs(ref.command_options(name)) do
      opts[#opts + 1] = '--' .. opt.name
    end
    enum(opts, '        ')
    add('        return 0\n      fi')
    local positional = ref.commands[name].positional
    if name == 'help' then
      positional = ref.order
    end
    if type(positional) == 'table' then
      add('      if [ "$COMP_CWORD" -eq 2 ]; then')
      enum(positional, '        ')
      add('      fi')
    elseif positional then
      add(
        '      while IFS= read -r candidate; do COMPREPLY+=("$candidate"); done < <(compgen -'
          .. (positional == 'directory' and 'd' or 'f')
          .. ' -- "$cur")'
      )
    end
    add('      ;;')
  end
  add('  esac\n  return 0\n}\ncomplete -o filenames -F _rivet rivet\n')
  return table.concat(lines, '\n')
end
local function fish()
  local lines = {
    [[# Rivet completion; no project commands are executed.
function __rivet_command
    set -l words (commandline -opc)
    test (count $words) -ge 2; and test "$words[2]" = "$argv[1]"
end
complete -c rivet -f
complete -c rivet -n '__fish_use_subcommand' -l help -s h -d 'Show help'
complete -c rivet -n '__fish_use_subcommand' -l version -d 'Show version']],
  }
  for _, name in ipairs(ref.order) do
    local cmd = ref.commands[name]
    lines[#lines + 1] = "complete -c rivet -n '__fish_use_subcommand' -a "
      .. quote(name)
      .. ' -d '
      .. quote(cmd.description)
    local condition = quote('__rivet_command ' .. name)
    for _, opt in ipairs(ref.command_options(name)) do
      local line = 'complete -c rivet -n '
        .. condition
        .. ' -l '
        .. opt.name
        .. ' -d '
        .. quote(opt.description)
      if opt.name == 'help' then
        line = line .. ' -s h'
      end
      if opt.value then
        line = line .. (opt.path == 'file' and ' -r' or ' -r -f')
      end
      if opt.choices then
        line = line .. ' -a ' .. quote(choices(opt.choices))
      elseif opt.path == 'directory' then
        line = line .. " -a '(__fish_complete_directories)'"
      elseif opt.path then
        line = line .. ' -F'
      end
      lines[#lines + 1] = line
    end
    local positional = cmd.positional
    if name == 'help' then
      positional = ref.order
    end
    if type(positional) == 'table' then
      lines[#lines + 1] = 'complete -c rivet -n '
        .. quote('__rivet_command ' .. name .. '; and test (count (commandline -opc)) -eq 2')
        .. ' -a '
        .. quote(choices(positional))
    elseif positional then
      lines[#lines + 1] = 'complete -c rivet -n '
        .. condition
        .. (positional == 'directory' and " -a '(__fish_complete_directories)'" or ' -F')
    end
  end
  return table.concat(lines, '\n') .. '\n'
end
local function zsh()
  local lines = {
    [[#compdef rivet
# Source after compinit.
_rivet() {
  local context state state_descr line
  typeset -A opt_args
  local -a commands
  commands=(]],
  }
  for _, name in ipairs(ref.order) do
    lines[#lines + 1] = '    ' .. quote(name .. ':' .. ref.commands[name].description)
  end
  lines[#lines + 1] = [[  )
  if (( CURRENT == 2 )); then
    _describe 'command' commands
    _arguments '--help[Show help]' '-h[Show help]' '--version[Show version]'
    return
  fi
  local command=$words[2]
  words=(${words[1]} "${words[@]:2}")
  (( CURRENT-- ))
  case $command in]]
  for _, name in ipairs(ref.order) do
    lines[#lines + 1] = '    ' .. name .. ')\n      _arguments \\'
    for _, opt in ipairs(ref.command_options(name)) do
      local spec = '--' .. opt.name .. '[' .. opt.description .. ']'
      if opt.value then
        local action = ''
        if opt.choices then
          action = '(' .. choices(opt.choices) .. ')'
        elseif opt.path then
          action = opt.path == 'directory' and '_files -/' or '_files'
        end
        spec = spec .. ':' .. opt.value .. ':' .. action
      end
      lines[#lines + 1] = '        ' .. quote(spec) .. ' \\'
    end
    lines[#lines + 1] = "        '-h[Show command help]' \\"
    local positional = ref.commands[name].positional
    if name == 'help' then
      positional = ref.order
    end
    local spec = '*:argument:'
    if type(positional) == 'table' then
      spec = '1:value:(' .. choices(positional) .. ')'
    elseif positional then
      spec = '*:path:' .. (positional == 'directory' and '_files -/' or '_files')
    end
    lines[#lines + 1] = '        ' .. quote(spec) .. '\n      ;;'
  end
  lines[#lines + 1] = '  esac\n}\ncompdef _rivet rivet\n'
  return table.concat(lines, '\n')
end
function M.generate(shell)
  local render = ({ bash = bash, fish = fish, zsh = zsh })[shell]
  assert(render, 'Unsupported shell: ' .. tostring(shell) .. '. Choose fish, bash, or zsh.')
  return render()
end
return M
