-- Small, conservative YAML edits: preserve text outside the selected setting.
local rt, json = require('rivet.runtime'), require('rivet.json')
local M = {}
local tools = {
  {
    id = 'clang-format',
    path = '.clang-format',
    label = 'clang-format · source formatting',
    description = 'Controls indentation, line wrapping, and layout.',
    url = 'https://clang.llvm.org/docs/ClangFormatStyleOptions.html',
  },
  {
    id = 'clang-tidy',
    path = '.clang-tidy',
    label = 'clang-tidy · static analysis',
    description = 'Selects checks, warning policy, and check-specific options.',
    url = 'https://clang.llvm.org/extra/clang-tidy/',
  },
  {
    id = 'clangd',
    path = '.clangd',
    label = 'clangd · editor language server',
    description = 'Controls parsing, editor diagnostics, indexing, and completion.',
    url = 'https://clangd.llvm.org/config',
  },
}
local function choices(entries)
  local result = {}
  for _, pair in ipairs(entries) do
    result[#result + 1] =
      { id = pair[1], label = pair[1] .. ' — ' .. pair[2], description = pair[2] }
  end
  return result
end
local styles = choices({
  { 'LLVM', 'LLVM project conventions' },
  { 'Google', 'Google C++ conventions' },
  { 'Chromium', 'Chromium conventions' },
  { 'Mozilla', 'Mozilla conventions' },
  { 'WebKit', 'WebKit conventions' },
  { 'Microsoft', 'Microsoft conventions' },
  { 'GNU', 'GNU conventions' },
})
local catalogs = {
  ['clang-format'] = {
    {
      key = 'BasedOnStyle',
      type = 'string',
      default = 'LLVM',
      description = 'Base preset. Explicit keys in this file override its defaults.',
      choices = styles,
    },
    {
      key = 'IndentWidth',
      type = 'integer',
      default = '2',
      description = 'Number of columns per indentation level. Nonnegative integer.',
    },
    {
      key = 'ColumnLimit',
      type = 'integer',
      default = '80',
      description = 'Preferred maximum line width. 0 removes the column limit; some constructs still keep their original breaks.',
    },
    {
      key = 'UseTab',
      type = 'string',
      default = 'Never',
      description = 'Where formatting may use tab characters.',
      choices = choices({
        { 'Never', 'Use spaces' },
        { 'ForIndentation', 'Tabs only for indentation' },
        { 'ForContinuationAndIndentation', 'Tabs for indentation and continuation' },
        { 'AlignWithSpaces', 'Use spaces for alignment' },
        { 'Always', 'Use tabs wherever possible' },
      }),
    },
    {
      key = 'BreakBeforeBraces',
      type = 'string',
      default = 'Attach',
      description = 'Brace placement style. Custom uses the separate BraceWrapping mapping; edit that mapping manually.',
      choices = choices({
        { 'Attach', 'Attach braces to the previous line' },
        { 'Allman', 'Put braces on separate lines' },
        { 'Linux', 'Separate function, class, and namespace braces' },
        { 'Stroustrup', 'Separate function braces and else/catch' },
        { 'GNU', 'GNU brace placement and indentation' },
        { 'WebKit', 'Separate function braces' },
        { 'Custom', 'Use your BraceWrapping settings' },
      }),
    },
    {
      key = 'PointerAlignment',
      type = 'string',
      default = 'Right',
      description = 'Placement of * and &. If DerivePointerAlignment is enabled, existing code can override this choice.',
      choices = choices({
        { 'Left', 'int* value' },
        { 'Right', 'int *value' },
        { 'Middle', 'int * value' },
      }),
    },
    {
      key = 'DerivePointerAlignment',
      type = 'boolean',
      default = 'false',
      description = 'true infers pointer alignment from the file; false uses PointerAlignment.',
    },
  },
  ['clang-tidy'] = {
    {
      key = 'Checks',
      type = 'string',
      default = '-*,clang-analyzer-*,bugprone-*,performance-*,modernize-use-nullptr,modernize-use-override',
      description = 'Comma-separated check globs, applied in order. -* disables defaults; bugprone-* enables a family; -check-name disables one check.',
    },
    {
      key = 'WarningsAsErrors',
      type = 'string',
      default = '',
      description = 'Comma-separated check globs whose warnings fail the task. Empty disables promotion; * promotes all enabled checks. This does not enable checks.',
    },
    {
      key = 'HeaderFilterRegex',
      type = 'string',
      default = '.*',
      description = 'Regular expression selecting headers whose diagnostics are shown. .* includes all headers; main-file diagnostics are always shown.',
    },
    {
      key = 'ExcludeHeaderFilterRegex',
      type = 'string',
      default = '',
      description = 'Regular expression excluding headers from HeaderFilterRegex. Empty excludes none; requires a clang-tidy version supporting this key.',
    },
    {
      key = 'FormatStyle',
      type = 'string',
      default = 'none',
      description = 'Formatting of suggested fixes. none disables formatting; file reads .clang-format; a named style uses that preset.',
      choices = choices({
        { 'none', 'Do not format fixes' },
        { 'file', 'Follow .clang-format' },
        { 'LLVM', 'Use LLVM style' },
        { 'Google', 'Use Google style' },
      }),
    },
    {
      key = 'CheckOptions',
      custom = true,
      type = 'string',
      default = '',
      description = 'Set a documented per-check option by its exact check.option key, for example readability-identifier-naming.VariableCase. Values depend on the check. Existing legacy key/value lists require manual editing.',
    },
  },
  clangd = {
    {
      key = 'CompileFlags.Add',
      type = 'array',
      default = '["-Wall"]',
      description = 'JSON array of compiler arguments to add, one argument per item. Example: ["-Iinclude", "-DMODE=1"]. These affect editor parsing, not the actual build.',
    },
    {
      key = 'CompileFlags.Remove',
      type = 'array',
      default = '["-W*"]',
      description = 'JSON array of flags to remove. A trailing * matches a prefix; recognized options also remove their arguments. Flags added in this same fragment remain.',
    },
    {
      key = 'CompileFlags.CompilationDatabase',
      type = 'string',
      default = '.cache/rivet',
      description = 'Directory containing compile_commands.json, relative to this file or absolute. Ancestors searches parent directories; None disables lookup. .cache/rivet follows Rivet’s selected CMake build.',
    },
    {
      key = 'Diagnostics.ClangTidy.Add',
      type = 'array',
      default = '["bugprone-*"]',
      description = 'JSON array of check names or globs to enable in clangd. Merged with .clang-tidy; clangd must have clang-tidy integration enabled.',
    },
    {
      key = 'Diagnostics.ClangTidy.Remove',
      type = 'array',
      default = '[]',
      description = 'JSON array of checks or globs to disable in clangd. Removal takes precedence over Add.',
    },
    {
      key = 'Diagnostics.ClangTidy.FastCheckFilter',
      type = 'string',
      default = 'Strict',
      description = 'Trade editor diagnostic coverage against latency.',
      choices = choices({
        { 'Strict', 'Only checks measured to be fast' },
        { 'Loose', 'Exclude checks known to be slow' },
        { 'None', 'Allow checks regardless of speed' },
      }),
    },
    {
      key = 'Diagnostics.ClangTidy.CheckOptions',
      custom = true,
      type = 'string',
      default = '',
      description = 'Set an exact documented check.option key for clangd. Overrides the same per-check setting from .clang-tidy.',
    },
    {
      key = 'Index.Background',
      type = 'string',
      default = 'Build',
      description = 'Background indexing supplies project-wide symbol information.',
      choices = choices({
        { 'Build', 'Index project translation units' },
        { 'Skip', 'Skip background indexing' },
      }),
    },
    {
      key = 'Completion.AllScopes',
      type = 'boolean',
      default = 'true',
      description = 'true suggests names outside the visible scope and inserts qualifiers; false limits those suggestions.',
    },
  },
}
function M.tools()
  return tools
end
function M.tool(name)
  name = ({ format = 'clang-format', tidy = 'clang-tidy' })[name] or name
  for _, tool in ipairs(tools) do
    if tool.id == name or tool.path == name then
      return tool
    end
  end
  error('Choose clang-format, clang-tidy, or clangd')
end
function M.catalog(name)
  return catalogs[M.tool(name).id]
end
local function setting(name, key)
  for _, entry in ipairs(M.catalog(name)) do
    local path = {}
    for part in entry.key:gmatch('[^.]+') do
      path[#path + 1] = part
    end
    if entry.key == key and not entry.custom then
      return entry, path
    elseif entry.custom and key:sub(1, #entry.key + 1) == entry.key .. '.' then
      local option = key:sub(#entry.key + 2)
      assert(option:match('^[%w_%-]+%.[%w_.%-]+$'), 'Use the exact documented check.option name')
      path[#path + 1] = option
      return entry, path
    end
  end
  error(
    'Unknown curated setting: ' .. tostring(key) .. '. Use the manual YAML editor for other keys.'
  )
end
local function encode(entry, value)
  if entry.type == 'integer' then
    local number = tonumber(value)
    assert(
      number and number >= 0 and number % 1 == 0 and number <= 2147483647,
      'Use a nonnegative integer'
    )
    return tostring(number)
  elseif entry.type == 'boolean' then
    assert(
      value == true or value == false or value == 'true' or value == 'false',
      'Use true or false'
    )
    return tostring(value)
  elseif entry.type == 'array' then
    if type(value) == 'string' then
      assert(value:match('^%s*%['), 'Use a JSON array of strings')
      value = json.decode(value)
    end
    assert(type(value) == 'table', 'Use a JSON array of strings')
    for k, item in pairs(value) do
      assert(
        type(k) == 'number'
          and k >= 1
          and k <= #value
          and type(item) == 'string'
          and not item:find('[%z\r\n]'),
        'Use a JSON array of single-line strings'
      )
    end
    local items = {}
    for _, item in ipairs(value) do
      items[#items + 1] = json.encode(item):gsub('%s+$', '')
    end
    return '[' .. table.concat(items, ', ') .. ']'
  end
  assert(type(value) == 'string' and not value:find('[%z\r\n]'), 'Use single-line text')
  if entry.choices then
    local found = false
    for _, choice in ipairs(entry.choices) do
      found = found or value == choice.id
    end
    assert(found, 'Choose one of the listed values for ' .. entry.key)
  end
  return "'" .. value:gsub("'", "''") .. "'"
end
local manual = 'This YAML needs manual editing; choose Open YAML in the config editor. '
local function split_comment(value)
  local quote, i = nil, 1
  while i <= #value do
    local c = value:sub(i, i)
    if quote then
      if c == '\\' and quote == '"' then
        i = i + 1
      elseif c == quote then
        if quote == "'" and value:sub(i + 1, i + 1) == "'" then
          i = i + 1
        else
          quote = nil
        end
      end
    elseif c == "'" or c == '"' then
      quote = c
    elseif c == '#' and (i == 1 or value:sub(i - 1, i - 1):match('%s')) then
      return value:sub(1, i - 1):gsub('%s+$', ''), value:sub(i)
    end
    i = i + 1
  end
  assert(not quote, manual .. 'Multiline quoted scalars are not supported.')
  return value:gsub('%s+$', ''), ''
end
local function parse(text)
  local lines, nodes, stack = {}, {}, {}
  if text == '' then
    return lines, nodes
  end
  assert(not text:find('\r'), manual .. 'CRLF files are preserved by the manual editor.')
  for line in (text:gsub('\n$', '') .. '\n'):gmatch('(.-)\n') do
    lines[#lines + 1] = line
    if line:match('%S') and not line:match('^%s*#') then
      assert(
        not line:match('^%s*%-%-%-') and not line:match('^%s*%.%.%.'),
        manual .. 'Multiple YAML documents are not edited automatically.'
      )
      assert(not line:match('^%s*\t'), manual .. 'Tab indentation is unsupported.')
      local spaces, key, value = line:match('^( *)([%w_.%-]+):%s*(.*)$')
      if not spaces then
        assert(line:match('^ *%- '), manual .. 'Complex mappings require manual editing.')
      else
        value = split_comment(value)
        assert(
          not value:match('^[&*!|>]') and key ~= '<<',
          manual .. 'YAML aliases, tags, and block scalars require manual editing.'
        )
        local indent = #spaces
        while #stack > 0 and stack[#stack].indent >= indent do
          stack[#stack].stop = #lines - 1
          table.remove(stack)
        end
        local parent = stack[#stack]
        assert(
          not parent or parent.value == '',
          manual .. 'Nested content below a scalar is unsupported.'
        )
        local node = {
          key = key,
          value = value,
          indent = indent,
          start = #lines,
          stop = nil,
          children = {},
          parent = parent,
        }
        local siblings = parent and parent.children or nodes
        assert(not siblings[key], manual .. 'Duplicate key: ' .. key)
        siblings[key] = node
        stack[#stack + 1] = node
      end
    end
  end
  for _, node in ipairs(stack) do
    node.stop = #lines
  end
  return lines, nodes
end
local function update(text, path, value)
  local lines, nodes = parse(text)
  local parent, node
  for index, key in ipairs(path) do
    node = nodes[key]
    if not node then
      local insert = parent and parent.stop + 1 or #lines + 1
      local indent = parent and parent.indent + 2 or 0
      local added = {}
      for i = index, #path do
        added[#added + 1] = string.rep(' ', indent)
          .. path[i]
          .. ':'
          .. (i == #path and ' ' .. value or '')
        indent = indent + 2
      end
      for i = #added, 1, -1 do
        table.insert(lines, insert, added[i])
      end
      return table.concat(lines, '\n'):gsub('^\n', '') .. '\n'
    end
    if index < #path then
      assert(
        node.value == '' or node.value == '{}',
        manual .. 'The setting’s parent is an inline value.'
      )
      if node.value == '{}' then
        local _, comment = split_comment(lines[node.start]:match('^[^:]+:%s*(.*)$'))
        lines[node.start] = string.rep(' ', node.indent)
          .. node.key
          .. ':'
          .. (comment ~= '' and ' ' .. comment or '')
      end
      parent, nodes = node, node.children
    end
  end
  assert(
    next(node.children) == nil,
    manual .. 'Replacing an existing mapping would discard settings.'
  )
  assert(
    not node.value:match('^%{'),
    manual .. 'Replacing an inline mapping would discard settings.'
  )
  local _, comment = split_comment(lines[node.start]:match('^[^:]+:%s*(.*)$'))
  for i = node.stop, node.start + 1, -1 do
    if lines[i]:match('%S') and not lines[i]:match('^%s*#') then
      assert(lines[i]:match('^%s*%- '), manual .. 'Complex setting values require manual editing.')
      local _, sequence_comment = split_comment(lines[i]:match('^%s*%- (.*)$'))
      if sequence_comment ~= '' then
        lines[i] = string.rep(' ', node.indent + 2) .. sequence_comment
      else
        table.remove(lines, i)
      end
    end
  end
  lines[node.start] = string.rep(' ', node.indent)
    .. node.key
    .. ': '
    .. value
    .. (comment ~= '' and ' ' .. comment or '')
  return table.concat(lines, '\n') .. '\n'
end
function M.current(root, name, key)
  local tool = M.tool(name)
  local _, path = setting(name, key)
  local _, nodes = parse(rt.read(rt.confined(root, tool.path)) or '')
  local node
  for _, part in ipairs(path) do
    node = nodes[part]
    if not node then
      return nil
    end
    nodes = node.children
  end
  return node.value ~= '' and node.value or nil
end
function M.validate(name, text)
  local tool = M.tool(name)
  local executable = rt.executable('/opt/homebrew/opt/llvm/bin/' .. tool.id)
    or rt.executable('/usr/local/opt/llvm/bin/' .. tool.id)
    or rt.executable(tool.id)
  if not executable then
    return 'Tool validation unavailable: install ' .. tool.id .. ' to validate with its version.'
  end
  local created = rt.run({ 'mktemp', '-d' })
  assert(created.code == 0, created.stderr)
  local directory = created.stdout:gsub('%s+$', '')
  local path, source = rt.join(directory, tool.path), rt.join(directory, 'rivet_config_check.cpp')
  local ok, result = pcall(function()
    rt.write(path, text)
    rt.write(source, 'int main() { return 0; }\n')
    local argv
    if tool.id == 'clang-format' then
      argv =
        { executable, '--style=file:' .. path, '--dump-config', '--assume-filename=' .. source }
    elseif tool.id == 'clang-tidy' then
      argv = { executable, '--config-file=' .. path, '--verify-config' }
    else
      argv = { executable, '--check=' .. source, '--enable-config', '--log=info' }
    end
    local process = rt.run(argv, { cwd = directory, stdin = '', timeout = 15000 })
    local output = process.stdout .. process.stderr
    assert(
      process.code == 0 and not output:find('config error:') and not output:find('config warning:'),
      tool.id .. ' rejected the configuration:\n' .. output
    )
    return 'Validated with '
      .. executable
      .. '. Advanced settings may depend on the project/tool version.'
  end)
  os.remove(path)
  os.remove(source)
  rt.run({ 'rmdir', directory })
  assert(ok, result)
  return result
end
function M.plan(root, name, key, value)
  local project = require('rivet.project')
  root = project.canonical(root)
  local spec, tool = project.inspect(root), M.tool(name)
  local entry, path = setting(name, key)
  local before = rt.read(rt.confined(root, tool.path))
  local after = update(before or '', path, encode(entry, value))
  return {
    root = root,
    spec = spec,
    files = { [tool.path] = after },
    expected = { [tool.path] = before or false },
    notes = {
      tool.id .. ': ' .. key,
      entry.description,
      M.validate(name, after),
      'Reference: ' .. tool.url,
    },
  }
end
return M
