-- Native CMake/Just entry points, usable without Rivet installed.
local M = {}
function M.files(spec)
  local recipes =
    { '# Optional native task shortcuts; resolve the local compiler on every invocation.' }
  for _, task in ipairs({ 'configure', 'build', 'test', 'fmt', 'run' }) do
    if task ~= 'run' or spec.kind == 'app' then
      recipes[#recipes + 1] = task
        .. ' preset="debug":\n    cmake -DRIVET_TASK='
        .. task
        .. ' -DRIVET_PRESET={{preset}} -P cmake/RivetJust.cmake\n'
    end
  end
  return {
    justfile = table.concat(recipes, '\n') .. '\n',
    ['cmake/RivetJust.cmake'] = [[# Generated native task runner for the debug/release starter presets.
cmake_minimum_required(VERSION 3.28)
if(NOT RIVET_PRESET MATCHES "^(debug|release)$")
  message(FATAL_ERROR "Just supports debug or release; use CMake directly for custom presets")
endif()
get_filename_component(root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(chosen "${RIVET_PRESET}")
set(build_preset "${RIVET_PRESET}")
set(binary "${root}/build/${RIVET_PRESET}")
if(EXISTS "${root}/CMakeUserPresets.json")
  file(READ "${root}/CMakeUserPresets.json" presets)
  string(JSON count ERROR_VARIABLE error LENGTH "${presets}" configurePresets)
  if(NOT error AND count GREATER 0)
    math(EXPR last "${count} - 1")
    foreach(i RANGE 0 ${last})
      string(JSON name GET "${presets}" configurePresets ${i} name)
      if(name STREQUAL "local-${RIVET_PRESET}")
        set(chosen "${name}")
        string(JSON dir ERROR_VARIABLE missing GET "${presets}" configurePresets ${i} binaryDir)
        if(NOT missing)
          string(REPLACE "\${sourceDir}" "${root}" binary "${dir}")
        endif()
      endif()
    endforeach()
  endif()
  string(JSON count ERROR_VARIABLE error LENGTH "${presets}" buildPresets)
  if(NOT error AND count GREATER 0)
    math(EXPR last "${count} - 1")
    foreach(i RANGE 0 ${last})
      string(JSON name GET "${presets}" buildPresets ${i} name)
      if(name STREQUAL "${chosen}")
        set(build_preset "${chosen}")
      endif()
    endforeach()
  endif()
endif()
function(run)
  execute_process(COMMAND ${ARGV} WORKING_DIRECTORY "${root}" COMMAND_ERROR_IS_FATAL ANY)
endfunction()
run("${CMAKE_COMMAND}" --preset "${chosen}")
if(RIVET_TASK STREQUAL "configure")
  return()
elseif(RIVET_TASK STREQUAL "fmt")
  run("${CMAKE_COMMAND}" --build --preset "${build_preset}" --target format)
  return()
endif()
run("${CMAKE_COMMAND}" --build --preset "${build_preset}")
if(RIVET_TASK STREQUAL "test")
  run("${CMAKE_CTEST_COMMAND}" --preset "${build_preset}")
elseif(RIVET_TASK STREQUAL "run")
  run("${binary}/]]
      .. spec.name
      .. [[")
endif()
]],
  }
end
return M
