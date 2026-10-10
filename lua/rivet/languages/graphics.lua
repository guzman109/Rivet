local M = {}
function M.apply(spec, target, add)
  local profile = require('rivet.languages.graphics.' .. spec.profile)
  local name = target.name
  add(target.source_dir .. '/main.cpp', profile.source, 'sources')
  for file, source in pairs(profile.shaders) do
    add('shaders/' .. file, source, 'resources')
  end
  local finish = profile.finish(name)
  local dir = '${CMAKE_CURRENT_BINARY_DIR}/shaders'
  if spec.profile == 'opengl' or spec.profile == 'webgpu' then
    -- Configure-time copying would leave edited shaders stale until reconfigure.
    finish = finish
      .. 'add_custom_target(rivet_shaders ALL COMMAND "${CMAKE_COMMAND}" -E copy_directory "${PROJECT_SOURCE_DIR}/shaders" "'
      .. dir
      .. '" VERBATIM)\nadd_dependencies('
      .. name
      .. ' rivet_shaders)\n'
  end
  finish = finish
    .. 'target_compile_definitions('
    .. name
    .. ' PRIVATE RIVET_SHADER_DIR="'
    .. dir
    .. '")\n'
  return profile.setup, finish
end
return M
