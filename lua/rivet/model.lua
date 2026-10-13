-- The core intentionally has no Neovim or filesystem dependency.
local M = {}
---@type table<string, string|rivet.Provider>
local languages = {
  cpp = 'rivet.languages.cpp',
  c = 'rivet.languages.c',
  python = 'rivet.languages.python',
  rust = 'rivet.languages.rust',
  swift = 'rivet.languages.swift',
}

function M.supports(language)
  return languages[language] ~= nil
end
function M.list_languages()
  local result = {}
  for name in pairs(languages) do
    result[#result + 1] = name
  end
  table.sort(result)
  return result
end

---@param language string
---@param adapter rivet.Provider
function M.register(language, adapter)
  assert(type(language) == 'string' and language:match('^[a-z][a-z0-9_]*$'), 'invalid language id')
  assert(type(adapter) == 'table', 'language adapter must be a table')
  for _, name in ipairs({ 'normalize', 'plan', 'add_file', 'add_target', 'add_dependency' }) do
    assert(type(adapter[name]) == 'function', 'language adapter needs ' .. name)
  end
  assert(not languages[language], 'language already registered: ' .. language)
  languages[language] = adapter
end

---@param opts table
---@return rivet.Provider
local function adapter(opts)
  local language = opts.language or 'cpp'
  local result = languages[language]
  assert(result, 'unsupported language: ' .. tostring(language))
  if type(result) == 'string' then
    return require(result)
  end
  return result
end
M.provider = adapter

function M.questions(kind, spec, context)
  local provider = adapter(spec)
  assert(
    provider.questions,
    'This provider has no ' .. kind .. ' questionnaire; use its explicit options'
  )
  return provider.questions(kind, spec, context or {})
end

function M.profile(spec)
  local result = { language = spec.language or 'cpp' }
  for _, key in ipairs(adapter(spec).profile_fields or {}) do
    result[key] = spec[key]
  end
  return result
end

function M.normalize(opts)
  local options = require('rivet.licenses').options(opts or {})
  return adapter(options).normalize(options)
end
function M.default_name(folder, language)
  local provider = adapter({ language = language })
  return provider.default_name and provider.default_name(folder) or folder
end
function M.plan(opts)
  local options = require('rivet.licenses').options(opts or {})
  local provider = adapter(options)
  local plan = provider.plan(options)
  plan.spec.license = options.license
  for path, content in pairs(require('rivet.licenses').files(options.license)) do
    assert(not plan.files[path], 'Provider already generated ' .. path)
    plan.files[path] = content
    if plan.spec.files then
      plan.spec.files[#plan.spec.files + 1] = path
    end
    if plan.spec.language == 'rust' and plan.spec.kind == 'workspace' then
      local member = 'crates/' .. plan.spec.name .. '/' .. path
      plan.files[member] = content
      plan.spec.files[#plan.spec.files + 1] = member
    end
  end
  if provider.ignore_rules and not plan.files['.gitignore'] then
    plan.files['.gitignore'] = provider.ignore_rules(plan.spec)
      .. '\n# Local Rivet run settings\n/.rivet.local.json\n'
    if plan.spec.files then
      plan.spec.files[#plan.spec.files + 1] = '.gitignore'
      table.sort(plan.spec.files)
    end
  end
  return plan
end
function M.add_file(spec, opts)
  return adapter(spec).add_file(spec, opts or {})
end
function M.add_target(spec, opts)
  return adapter(spec).add_target(spec, opts or {})
end
function M.add_dependency(spec, opts)
  return adapter(spec).add_dependency(spec, opts or {})
end

return M
