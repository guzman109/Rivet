-- Files in another language are tracked without changing the host build.
local helpers = require('rivet.languages.cpp_spec')
local M = {}
local extensions =
  { cpp = 'cpp', c = 'c', python = 'py', rust = 'rs', swift = 'swift', lua = 'lua' }
local function header_options(headers, value)
  if not value or not value.style or not headers.styles then
    return value
  end
  local compact = false
  for _, style in ipairs(headers.styles) do
    if style.id == value.style then
      return value
    end
    compact = compact or style.id == 'compact'
  end
  if not compact then
    return value
  end
  -- Python has line-comment headers; keep the project identity in its supported syntax.
  local adapted = helpers.copy(value)
  adapted.style = 'compact'
  return adapted
end
function M.infer(name)
  local ext = type(name) == 'string' and name:match('%.([%w]+)$')
  if ext == 'h' then
    return 'c'
  end
  if ext == 'hpp' or ext == 'cc' or ext == 'cxx' or ext == 'cppm' then
    return 'cpp'
  end
  for language, suffix in pairs(extensions) do
    if ext == suffix then
      return language
    end
  end
end
function M.with_header_previews(steps, spec, language)
  local output = helpers.copy(steps)
  local model = require('rivet.model')
  if not model.supports(language) then
    return output
  end
  local service = model.provider({ language = language }).services
  local headers = service and service.headers
  headers = type(headers) == 'string' and require(headers) or headers
  if not headers then
    return output
  end
  local has_kind = false
  for _, step in ipairs(output) do
    has_kind = has_kind or step.key == 'kind'
  end
  if not has_kind then
    table.insert(output, 1, {
      key = 'kind',
      title = 'New source file',
      items = { { id = 'source', label = 'Source file' } },
    })
  end
  local function decorate(items)
    items = helpers.copy(items)
    for _, item in ipairs(items) do
      local kind = item.id
      local ext = extensions[language] or 'cpp'
      if kind == 'header' or kind == 'pair' or kind == 'class' then
        ext = language == 'c' and 'h' or 'hpp'
      end
      if kind == 'c_header' or kind == 'c_pair' then
        ext = 'h'
      end
      if kind == 'c_source' then
        ext = 'c'
      end
      if language == 'cpp' and (kind == 'module' or kind == 'module_pair') then
        ext = 'cppm'
      end
      local options = header_options(headers, spec.comment_header)
      local header = headers.render(options, { filename = 'example.' .. ext, project = spec.name })
      local prefix = (
        header ~= '' and header
        or (
          'No file comment header is configured.'
          .. (spec.external and '' or ' Use :RivetHeaderDefaults to set one.')
          .. '\n\n'
        )
      )
      local original = item.preview
      local function combine(body)
        body = body or item.description or item.label or item.id or item.name or ''
        if type(body) == 'table' then
          body = table.concat(body, '\n')
        end
        return prefix
          .. body
          .. (options ~= spec.comment_header and '\n\nThe project header style is adapted to this language’s line-comment syntax.' or '')
          .. '\n\nThe final review shows the complete files with their actual filenames and headers.'
      end
      item.preview = type(original) == 'function'
          and function(choice)
            return combine(original(choice))
          end
        or combine(original)
    end
    return items
  end
  for _, step in ipairs(output) do
    if step.key == 'kind' and step.items then
      if type(step.items) == 'function' then
        local original = step.items
        step.items = function(values)
          return decorate(original(values))
        end
      else
        step.items = decorate(step.items)
      end
    end
  end
  return output
end
function M.questions(spec, language)
  local kinds = { { id = 'source', label = 'Source file' } }
  if language == 'c' or language == 'cpp' then
    kinds[#kinds + 1] = { id = 'header', label = 'Header' }
    kinds[#kinds + 1] = { id = 'pair', label = 'Source + header' }
    if language == 'cpp' then
      kinds[#kinds + 1] = { id = 'module', label = 'Module interface (C++20+)' }
      kinds[#kinds + 1] =
        { id = 'module_pair', label = 'Module interface + implementation (C++20+)' }
    end
  elseif language == 'lua' then
    kinds = {
      {
        id = 'script',
        label = 'Lua script · files only',
        description = 'Use a Lua interpreter or your existing scripting integration. No host dependency is added.',
      },
      { id = 'module', label = 'Reusable Lua module · files only' },
    }
    if spec.language == 'c' or spec.language == 'cpp' or spec.language == 'rust' then
      kinds[#kinds + 1] = {
        id = 'embedded',
        label = 'Lua + host example · embed a runtime',
        description = 'Review a new example executable and dependency/build changes. Existing application entrypoints stay yours to integrate.',
      }
    end
  end
  return {
    { key = 'kind', title = 'What do you want to create?', items = kinds },
    {
      key = 'name',
      title = language == 'lua' and 'Name or project-relative path (embedding: example name)'
        or 'Project-relative file path (extension optional)',
      input = true,
      default = language == 'lua' and 'helper' or 'src/helper',
    },
    {
      key = 'module',
      title = 'Exported C++ module name',
      input = true,
      default = function(o)
        return helpers.default_name(spec.name or 'project')
          .. '.'
          .. (o.name:match('[^/]+$'):gsub('%.%w+$', ''))
      end,
      when = function(o)
        return o.kind == 'module' and language == 'cpp' or o.kind == 'module_pair'
      end,
    },
  }
end
function M.plan(existing, opts, language)
  language = language or opts.language or M.infer(opts.name) or existing.language
  assert(
    extensions[language] or language == 'text',
    'Unsupported file language: ' .. tostring(language)
  )
  local spec, files = helpers.copy(existing), {}
  spec.files, spec.file_languages = spec.files or {}, spec.file_languages or {}
  local kind = opts.kind or (language == 'lua' and 'module' or 'source')
  local raw = helpers.path(assert(opts.name, 'File name required'))
  local headers
  if language ~= 'text' then
    headers = require('rivet.tasks').service({ language = language }, 'headers')
  end
  local function add(path, body)
    helpers.path(path)
    for _, old in ipairs(spec.files) do
      assert(old:lower() ~= path:lower(), 'File already registered: ' .. path)
    end
    spec.files[#spec.files + 1], spec.file_languages[path], files[path] =
      path,
      language,
      (headers and headers.render(
        header_options(headers, spec.comment_header),
        { filename = path, project = spec.name }
      ) or '') .. body
  end
  if language == 'lua' then
    local path, body = require('rivet.languages.lua').file_template(
      opts,
      { name = require('rivet.languages.lua').default_name(spec.name or 'project') }
    )
    add(path, body)
  elseif language == 'text' then
    assert(kind == 'source', 'Blank files use kind=source')
    add(raw, '\n')
  elseif language == 'c' or language == 'cpp' then
    local stem = raw
      :gsub('%.cppm$', '')
      :gsub('%.hpp$', '')
      :gsub('%.cpp$', '')
      :gsub('%.cc$', '')
      :gsub('%.cxx$', '')
      :gsub('%.c$', '')
      :gsub('%.h$', '')
    local base = helpers.identifier(stem:match('[^/]+$'), 'file name')
    local header = language == 'c' and '.h' or '.hpp'
    if kind == 'source' then
      add(stem .. '.' .. extensions[language], '// Add implementation here.\n')
    elseif kind == 'header' or kind == 'pair' then
      add(
        stem .. header,
        '#pragma once\n\n'
          .. (language == 'c' and '#ifdef __cplusplus\nextern "C" {\n#endif\n\n' or '')
          .. 'int '
          .. base
          .. '(void);\n'
          .. (language == 'c' and '\n#ifdef __cplusplus\n}\n#endif\n' or '')
      )
      if kind == 'pair' then
        add(
          stem .. '.' .. extensions[language],
          '#include "' .. base .. header .. '"\n\nint ' .. base .. '(void) { return 42; }\n'
        )
      end
    elseif language == 'cpp' and (kind == 'module' or kind == 'module_pair') then
      local name = helpers.module_name(
        opts.module or helpers.default_name(spec.name or 'project') .. '.' .. base
      )
      add(
        stem .. '.cppm',
        'export module '
          .. name
          .. ';\n\nexport int '
          .. base
          .. '()'
          .. (kind == 'module_pair' and ';\n' or ' { return 42; }\n')
      )
      if kind == 'module_pair' then
        add(stem .. '.cpp', 'module ' .. name .. ';\n\nint ' .. base .. '() { return 42; }\n')
      end
    else
      error('Choose source, header, pair, module, or module_pair')
    end
  else
    assert(kind == 'source', 'This language uses kind=source')
    local suffix = '.' .. extensions[language]
    local path = raw:sub(-#suffix) == suffix and raw or raw .. suffix
    add(
      path,
      language == 'python' and '# Add implementation here.\n' or '// Add implementation here.\n'
    )
  end
  table.sort(spec.files)
  return {
    spec = spec,
    files = files,
    managed = {},
    notes = {
      'Files are created in the selected language. Host build targets and dependencies are unchanged; integrate these files with your existing build or scripting workflow.',
    },
  }
end
function M.lifecycle(existing, opts, contents)
  local spec = helpers.copy(existing)
  local old, new = assert(opts.from, 'File path required'), opts.to
  local language = assert((spec.file_languages or {})[old], 'Unknown loose file')
  assert(opts.action == 'move' or opts.action == 'remove', 'Choose move or remove')
  local body = assert(contents[old], 'File is missing: ' .. old)
  local plan = {
    spec = spec,
    files = { [old] = false },
    replace = { [old] = true },
    original = contents,
    notes = { 'Update imports and script paths that refer to this file separately.' },
  }
  if opts.action == 'move' then
    helpers.path(assert(new, 'Destination required'))
    assert(
      new:match('%.([^%.]+)$') == old:match('%.([^%.]+)$'),
      'Keep the extension when moving a file'
    )
    for _, path in ipairs(spec.files) do
      assert(path:lower() ~= new:lower(), 'Destination already registered: ' .. new)
    end
    plan.files[new], plan.moves, spec.file_languages[new] = body, { [old] = new }, language
  end
  for i, path in ipairs(spec.files) do
    if path == old then
      table.remove(spec.files, i)
      break
    end
  end
  if new then
    spec.files[#spec.files + 1] = new
  end
  spec.file_languages[old] = nil
  table.sort(spec.files)
  return plan
end
return M
