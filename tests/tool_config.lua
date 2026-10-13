-- lua tests/tool_config.lua; validates native tools when installed.
local repo = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/tests/tool_config%.lua$') or '.'
package.path = repo .. '/lua/?.lua;' .. package.path
local rt, config, project =
  require('rivet.runtime'), require('rivet.tool_config'), require('rivet.project')
local result = rt.run({ 'mktemp', '-d' })
assert(result.code == 0, result.stderr)
local root = project.canonical(result.stdout:gsub('%s+$', ''))
rt.write(
  root .. '/CMakeLists.txt',
  'cmake_minimum_required(VERSION 3.30)\nproject(sample LANGUAGES CXX)\n'
)
local function rejects(fn, message)
  local ok, err = pcall(fn)
  assert(not ok, message or 'Expected rejection')
  return tostring(err)
end
local function apply(tool, key, value)
  local plan = config.plan(root, tool, key, value)
  assert(
    not plan.files['.rivet.json'],
    'Config edits must not claim ownership of an external project'
  )
  project.apply(root, plan)
  return plan.files[config.tool(tool).path]
end
-- Both initial defaults and every offered scalar choice must pass installed tools.
local generated = require('rivet.model').plan({ name = 'sample', standard = 17, modules = false })
for _, tool in ipairs(config.tools()) do
  assert(config.validate(tool.id, generated.files[tool.path]))
end
rt.write(
  root .. '/.clang-format',
  '# Keep this note\nBasedOnStyle: LLVM # team choice\nTabWidth: 4\n'
)
local before = rt.read(root .. '/.clang-format')
local plan = config.plan(root, 'format', 'IndentWidth', '4')
assert(rt.read(root .. '/.clang-format') == before, 'Planning wrote project files')
project.apply(root, plan)
local text = apply('format', 'BasedOnStyle', 'Google')
assert(text:find("BasedOnStyle: 'Google' # team choice", 1, true))
assert(text:find('# Keep this note', 1, true) and text:find('TabWidth: 4', 1, true))
assert(text:find('IndentWidth: 4', 1, true))
for _, entry in ipairs(config.catalog('format')) do
  if entry.choices then
    for _, choice in ipairs(entry.choices) do
      assert(config.plan(root, 'format', entry.key, choice.id))
    end
  end
end
rejects(function()
  config.plan(root, 'format', 'ColumnLimit', '-1')
end)
rejects(function()
  config.plan(root, 'format', 'BasedOnStyle', 'Typo')
end)
rejects(function()
  config.plan(root, 'clangd', 'CompileFlags.Add', 'not an array')
end)
rejects(function()
  config.plan(root, 'format', 'ArbitraryKey', '1')
end)
-- Nested additions preserve neighboring sections, block-sequence comments, and quoted hashes.
rt.write(
  root .. '/.clangd',
  '# top\nCompileFlags:\n  CompilationDatabase: .cache/rivet # follow selection\n  Add:\n    # keep this comment\n    - -DOLD # explain flag\nIndex:\n  Background: Build # indexing\n'
)
text = apply('clangd', 'CompileFlags.Add', '["-DNAME=#value", "-Wall"]')
assert(text:find('Add: ["-DNAME=#value", "-Wall"]', 1, true))
assert(not text:find('-DOLD', 1, true))
assert(text:find('# explain flag', 1, true))
assert(
  text:find('# keep this comment', 1, true) and text:find('Background: Build # indexing', 1, true)
)
text = apply('clangd', 'Diagnostics.ClangTidy.FastCheckFilter', 'Strict')
assert(text:find("Diagnostics:\n  ClangTidy:\n    FastCheckFilter: 'Strict'", 1, true))
text = apply('clangd', 'Completion.AllScopes', false)
assert(text:find('AllScopes: false', 1, true))
text = apply(
  'clangd',
  'Diagnostics.ClangTidy.CheckOptions.readability-identifier-naming.VariableCase',
  'camelBack'
)
assert(text:find("readability-identifier-naming.VariableCase: 'camelBack'", 1, true))
rt.write(
  root .. '/.clang-tidy',
  "Checks: 'readability-identifier-naming'\nCheckOptions: {} # check overrides\n"
)
text = apply('tidy', 'CheckOptions.readability-identifier-naming.VariableCase', 'CamelCase')
assert(
  text:find(
    "CheckOptions: # check overrides\n  readability-identifier-naming.VariableCase: 'CamelCase'",
    1,
    true
  )
)
-- Refuse ambiguous advanced files without modifying them.
for _, content in ipairs({
  'ColumnLimit: 80\nColumnLimit: 90\n',
  '---\nColumnLimit: 80\n---\nLanguage: Cpp\nColumnLimit: 90\n',
  'BasedOnStyle: &base LLVM\n',
  'Unknown: |\n  ColumnLimit: 80\n',
  '"ColumnLimit": 80\n',
}) do
  rt.write(root .. '/.clang-format', content)
  rejects(function()
    config.plan(root, 'format', 'ColumnLimit', '100')
  end)
  assert(rt.read(root .. '/.clang-format') == content)
end
rt.write(root .. '/.clangd', 'CompileFlags: { Add: [-Wall] }\n')
rejects(function()
  config.plan(root, 'clangd', 'CompileFlags.Remove', '[]')
end)
-- A stale reviewed plan cannot replace subsequent edits.
rt.write(root .. '/.clang-format', 'BasedOnStyle: LLVM\n')
plan = config.plan(root, 'format', 'IndentWidth', '3')
rt.write(root .. '/.clang-format', 'BasedOnStyle: Google\n')
rejects(function()
  project.apply(root, plan)
end)
-- Unavailable executables leave a clear validation note, not an installation side effect.
local executable = rt.executable
rt.executable = function()
  return false
end
local ok, note = pcall(config.validate, 'format', 'BasedOnStyle: LLVM\n')
rt.executable = executable
assert(ok and note:find('unavailable', 1, true))
assert(not rt.exists(root .. '/.rivet.json'))
print(
  'Tool config plans, YAML preservation, native validation, and stale-preview checks passed: '
    .. root
)
