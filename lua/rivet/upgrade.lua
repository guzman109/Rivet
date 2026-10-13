-- Upgrade only provider-declared supplementary templates with known provenance.
-- Source files are never regenerated, and local edits retain their old baseline.
local M = {}
local rt = require('rivet.runtime')
local json = require('rivet.json')

local function source_paths(spec)
  local paths = {}
  for _, target in ipairs(spec.targets or {}) do
    for _, kind in ipairs({ 'sources', 'headers', 'modules', 'resources' }) do
      for _, path in ipairs(target[kind] or {}) do
        paths[path] = true
      end
    end
  end
  return paths
end

local function collision(root, path)
  local full = rt.confined(root, path)
  if rt.is_dir(full) then
    return 'the destination is a directory'
  end
  local parent = rt.dirname(full)
  while parent ~= root do
    if rt.exists(parent) and not rt.is_dir(parent) then
      return 'a parent path is not a directory'
    end
    parent = rt.dirname(parent)
  end
  if rt.exists(full) then
    -- Do not read FIFOs or other special destinations while building a preview.
    if rt.run({ 'test', '-f', full }).code ~= 0 then
      return 'the destination is not a regular file'
    end
    if rt.read(full) == nil then
      return 'the destination is not a readable file'
    end
  end
end

function M.plan(root)
  local project, model = require('rivet.project'), require('rivet.model')
  root = project.canonical(root)
  local previous, raw = project.load(root)
  local provider = model.provider(previous)
  assert(provider.upgrade_files, 'This provider does not support supplementary template upgrades')
  assert(
    previous.template_baselines == nil or type(previous.template_baselines) == 'table',
    'Invalid supplementary template snapshots'
  )
  assert(
    previous.generated == nil or type(previous.generated) == 'table',
    'Invalid generated snapshots'
  )

  -- Work on a separate manifest so provider normalization and preview never
  -- advance the recorded baseline before the reviewed plan is applied.
  local spec = json.decode(raw)
  local normalized = model.normalize(previous)
  local latest = provider.upgrade_files(normalized)
  assert(type(latest) == 'table', 'Provider upgrades must return a supplementary file map')
  local plan = { root = root, spec = spec, files = {}, expected = {}, notes = {} }
  local version = require('rivet.version')
  plan.notes[#plan.notes + 1] = 'Supplementary templates: Rivet '
    .. (previous.rivet_version or 'version not recorded')
    .. ' → '
    .. version
    .. '.'
  if not previous.template_baselines then
    plan.notes[#plan.notes + 1] =
      'Original supplementary template provenance is unavailable. Existing files are adopted only when they exactly match a current template or a recorded managed snapshot.'
  end

  local paths = {}
  for path, content in pairs(latest) do
    rt.safe_relative(path)
    assert(
      path ~= '.rivet.json' and path ~= '.rivet.local.json',
      'Provider upgrade includes Rivet metadata'
    )
    assert(type(content) == 'string', 'Invalid supplementary template: ' .. path)
    paths[#paths + 1] = path
  end
  table.sort(paths)
  local sources, tools = source_paths(previous), nil
  local inventory = {}
  for _, path in ipairs(spec.files or {}) do
    inventory[path] = true
  end
  spec.template_baselines = spec.template_baselines or {}

  for _, path in ipairs(paths) do
    local reason = sources[path] and 'application sources and tests are preserved'
      or collision(root, path)
    if reason then
      plan.notes[#plan.notes + 1] = 'Skipped ' .. path .. ': ' .. reason .. '.'
    else
      local content = latest[path]
      if provider.formatter then
        tools = tools or rt.detect_tools()
        local argv = provider.formatter(normalized, path, tools)
        if argv then
          local result = rt.run(argv, { stdin = content })
          assert(result.code == 0, 'Formatting failed: ' .. result.stderr)
          content = result.stdout
        end
      end
      local current = rt.read(rt.confined(root, path))
      local managed = (previous.generated or {})[path]
      local baseline = (previous.template_baselines or {})[path]
      if baseline == nil then
        baseline = managed
      end
      assert(baseline == nil or type(baseline) == 'string', 'Invalid template snapshot: ' .. path)
      assert(managed == nil or type(managed) == 'string', 'Invalid generated snapshot: ' .. path)
      if current == nil or current == content or current == baseline then
        -- An identical file is included when adopting its snapshot: shared
        -- apply must reject edits made after preview before claiming ownership.
        if
          current ~= content
          or spec.template_baselines[path] ~= content
          or (managed ~= nil and managed ~= content)
        then
          plan.files[path], plan.expected[path] = content, current or false
        end
        spec.template_baselines[path] = content
        if managed ~= nil then
          spec.generated[path] = content
        end
        if not inventory[path] then
          spec.files = spec.files or json.array()
          spec.files[#spec.files + 1] = path
          inventory[path] = true
        end
      elseif baseline then
        plan.notes[#plan.notes + 1] = 'Skipped '
          .. path
          .. ': local edits conflict with the recorded template; the file and its baseline are preserved.'
      else
        plan.notes[#plan.notes + 1] = 'Skipped '
          .. path
          .. ': original template provenance is unavailable; the existing file is preserved.'
      end
    end
  end
  spec.rivet_version = version
  plan.files['.rivet.json'], plan.expected['.rivet.json'] = json.encode(spec), raw
  return plan
end

return M
