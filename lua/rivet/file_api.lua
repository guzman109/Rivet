local rt, json = require('rivet.runtime'), require('rivet.json')
local M = {}
function M.query(binary)
  local dir = rt.confined(binary, '.cmake/api/v1/query/client-rivet')
  rt.mkdir(dir)
  rt.write(
    rt.confined(binary, '.cmake/api/v1/query/client-rivet/query.json'),
    json.encode({
      requests = {
        { kind = 'codemodel', version = 2 },
        { kind = 'toolchains', version = 1 },
        { kind = 'cache', version = 2 },
      },
    })
  )
end
function M.read(binary)
  local directory = rt.confined(binary, '.cmake/api/v1/reply')
  if not rt.is_dir(directory) then
    return nil, 'No File API reply; configure through Rivet first'
  end
  local files = rt.run({ 'find', directory, '-maxdepth', '1', '-type', 'f', '-name', '*.json' })
  assert(files.code == 0, files.stderr)
  local latest, stamp, failed
  for filename in files.stdout:gmatch('[^\r\n]+') do
    local name = filename:match('[^/]+$')
    local key = name:match('^index%-(.+)$') or name:match('^error%-(.+)$')
    if key and (not stamp or key > stamp) then
      latest, stamp, failed = filename, key, name:match('^error%-')
    end
  end
  if not latest then
    return nil, 'No CMake File API index'
  end
  if failed then
    return nil, 'The latest CMake configure failed; its older File API reply is stale'
  end
  ---@return any
  local function read(name)
    return json.decode(
      assert(rt.read(rt.confined(directory, name)), 'CMake reply changed; configure again')
    )
  end
  local index = read(latest:match('[^/]+$'))
  local result = { index = index, read = read }
  local reply = ((index.reply or {})['client-rivet'] or {})['query.json']
  if not reply or reply.error then
    return nil, 'No Rivet File API response; configure through Rivet first'
  end
  for _, entry in ipairs(reply.responses or {}) do
    if entry.jsonFile then
      result[entry.kind] = read(entry.jsonFile)
    end
  end
  return result
end
function M.configuration(reply, name)
  local choices = (reply.codemodel or {}).configurations or {}
  if name then
    for _, choice in ipairs(choices) do
      if choice.name == name then
        return choice
      end
    end
    if #choices == 1 and choices[1].name == '' then
      return choices[1]
    end
    error('CMake configuration is unavailable: ' .. name)
  end
  assert(
    #choices == 1,
    'Choose a build preset with a configuration for this multi-config generator'
  )
  return choices[1]
end
function M.executable(root, binary, name, configuration)
  local reply, err = M.read(binary)
  assert(reply, err)
  local config = M.configuration(reply, configuration)
  for _, target in ipairs(config.targets or {}) do
    if target.name == name then
      local data = reply.read(target.jsonFile)
      assert(data.type == 'EXECUTABLE', 'Target is not an executable: ' .. name)
      local artifact = assert((data.artifacts or {})[1], 'No executable artifact for ' .. name).path
      local path = rt.absolute(artifact:sub(1, 1) == '/' and artifact or rt.join(binary, artifact))
      assert(
        path:sub(1, #root + 1) == root .. '/',
        'Executable artifact is outside the project: ' .. path
      )
      return rt.confined(root, path:sub(#root + 2))
    end
  end
  error('Target is absent from the configured build: ' .. name)
end
function M.targets(binary, configuration)
  local reply, err = M.read(binary)
  assert(reply, err)
  local result = {}
  for _, target in ipairs(M.configuration(reply, configuration).targets or {}) do
    local data = reply.read(target.jsonFile)
    result[#result + 1] =
      { name = target.name, type = data.type == 'EXECUTABLE' and 'executable' or data.type:lower() }
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end
return M
