-- CMake text generated for C++ projects: managed target registration, CPM
-- dependencies, project options, and presets.
local spec_helpers = require('rivet.languages.cpp_spec')
local M = {}

local function quoted_paths(lines, values, indent)
  for _, value in ipairs(values) do
    lines[#lines + 1] = (indent or '  ') .. '"${PROJECT_SOURCE_DIR}/' .. value .. '"'
  end
end

function M.targets_cmake(spec)
  local lines = {
    '# Generated from .rivet.json. Use Rivet or its Lua CLI to edit targets.',
    '# Put hand-written extensions in the root CMakeLists.txt after this include.',
    '',
  }
  if spec.c_standard then
    assert(
      spec.c_standard == 11 or spec.c_standard == 17 or spec.c_standard == 23,
      'Invalid C standard'
    )
    lines[#lines + 1] = 'enable_language(C)\nset(CMAKE_C_STANDARD '
      .. spec.c_standard
      .. ')\nset(CMAKE_C_STANDARD_REQUIRED ON)\nset(CMAKE_C_EXTENSIONS OFF)'
  end
  local format_files = {}
  for _, target in ipairs(spec.targets) do
    if target.test then
      lines[#lines + 1] = 'if(BUILD_TESTING)'
    end
    if target.type == 'executable' then
      lines[#lines + 1] = 'add_executable(' .. target.name .. ')'
    else
      lines[#lines + 1] = 'add_library(' .. target.name .. ' STATIC)'
    end
    lines[#lines + 1] = 'set_target_properties(' .. target.name .. ' PROPERTIES'
    lines[#lines + 1] = '  CXX_STANDARD '
      .. spec.standard
      .. ' CXX_STANDARD_REQUIRED YES CXX_EXTENSIONS NO'
    lines[#lines + 1] = '  CXX_SCAN_FOR_MODULES '
      .. ((spec.modules or spec.std_modules) and 'ON' or 'OFF')
    if spec.std_modules then
      lines[#lines + 1] = '  CXX_MODULE_STD ON'
    end
    lines[#lines + 1] = ')'
    if #target.sources + #target.headers > 0 then
      lines[#lines + 1] = 'target_sources(' .. target.name .. ' PRIVATE'
      quoted_paths(lines, target.sources)
      quoted_paths(lines, target.headers)
      lines[#lines + 1] = ')'
    end
    if #target.modules > 0 then
      lines[#lines + 1] = 'target_sources('
        .. target.name
        .. ' '
        .. (target.type == 'static' and 'PUBLIC' or 'PRIVATE')
      lines[#lines + 1] = '  FILE_SET cxx_modules TYPE CXX_MODULES'
      lines[#lines + 1] = '  BASE_DIRS "${PROJECT_SOURCE_DIR}"'
      lines[#lines + 1] = '  FILES'
      quoted_paths(lines, target.modules, '    ')
      lines[#lines + 1] = ')'
    end
    if #target.include_dirs > 0 then
      lines[#lines + 1] = 'target_include_directories('
        .. target.name
        .. ' '
        .. (target.type == 'static' and 'PUBLIC' or 'PRIVATE')
      quoted_paths(lines, target.include_dirs)
      lines[#lines + 1] = ')'
    end
    if #target.links > 0 then
      lines[#lines + 1] = 'target_link_libraries('
        .. target.name
        .. ' '
        .. (target.type == 'static' and 'PUBLIC' or 'PRIVATE')
        .. ' '
        .. table.concat(target.links, ' ')
        .. ')'
    end
    lines[#lines + 1] = 'rivet_target_options(' .. target.name .. ')'
    if target.test then
      lines[#lines + 1] = 'add_test(NAME ' .. target.name .. ' COMMAND ' .. target.name .. ')'
      lines[#lines + 1] = 'endif()'
    end
    lines[#lines + 1] = ''
    for _, field in ipairs({ 'sources', 'modules', 'headers' }) do
      for _, filename in ipairs(target[field]) do
        spec_helpers.add_unique(format_files, filename)
      end
    end
  end
  lines[#lines + 1] = 'find_program(RIVET_CLANG_FORMAT NAMES clang-format)'
  lines[#lines + 1] = 'if(RIVET_CLANG_FORMAT)'
  lines[#lines + 1] = '  add_custom_target(format'
  lines[#lines + 1] = '    COMMAND "${RIVET_CLANG_FORMAT}" -i --style=file'
  quoted_paths(lines, format_files, '      ')
  lines[#lines + 1] = '    WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}" VERBATIM)'
  lines[#lines + 1] = 'endif()'
  return table.concat(lines, '\n') .. '\n'
end

M.bootstrap = [[# CPM bootstrap pinned to upstream v0.43.1 (official release checksum).
set(CPM_SOURCE_CACHE "${PROJECT_SOURCE_DIR}/.cache/CPM" CACHE PATH "Project dependency source cache" FORCE)
set(_wb_cpm "${PROJECT_SOURCE_DIR}/.cache/CPM/CPM_0.43.1.cmake")
set(_wb_cpm_sha "1c40fc102ce9625d7de7eb14f541cab30cc3138dca627f0b0ec40293ce6c2934")
file(MAKE_DIRECTORY "${PROJECT_SOURCE_DIR}/.cache/CPM")
if(EXISTS "${_wb_cpm}")
  file(SHA256 "${_wb_cpm}" _wb_actual_sha)
  if(NOT _wb_actual_sha STREQUAL _wb_cpm_sha)
    message(FATAL_ERROR "CPM checksum mismatch: ${_wb_cpm}. Remove the corrupt cache file and configure again.")
  endif()
else()
  file(DOWNLOAD
    "https://github.com/cpm-cmake/CPM.cmake/releases/download/v0.43.1/CPM.cmake"
    "${_wb_cpm}.tmp"
    STATUS _wb_download_status TLS_VERIFY ON TIMEOUT 120)
  list(GET _wb_download_status 0 _wb_download_code)
  if(NOT _wb_download_code EQUAL 0)
    file(REMOVE "${_wb_cpm}.tmp")
    message(FATAL_ERROR "CPM download failed: ${_wb_download_status}")
  endif()
  file(SHA256 "${_wb_cpm}.tmp" _wb_actual_sha)
  if(NOT _wb_actual_sha STREQUAL _wb_cpm_sha)
    file(REMOVE "${_wb_cpm}.tmp")
    message(FATAL_ERROR "Downloaded CPM checksum does not match the pinned release")
  endif()
  file(RENAME "${_wb_cpm}.tmp" "${_wb_cpm}")
endif()
include("${_wb_cpm}")
]]

function M.dependencies_cmake(spec)
  local lines = {
    '# Generated from .rivet.json; explicitly versioned CPM dependencies.',
    '# Empty projects configure and build without accessing the network.',
  }
  if #spec.dependencies > 0 then
    lines[#lines + 1] = 'include("${CMAKE_CURRENT_LIST_DIR}/CPM.cmake")'
    for _, dep in ipairs(spec.dependencies) do
      lines[#lines + 1] = 'CPMAddPackage('
      lines[#lines + 1] = '  NAME ' .. dep.name
      lines[#lines + 1] = '  GITHUB_REPOSITORY "' .. dep.repository .. '"'
      lines[#lines + 1] = '  GIT_TAG "' .. dep.tag .. '"'
      lines[#lines + 1] = ')'
      lines[#lines + 1] = 'if(NOT TARGET ' .. dep.target .. ')'
      lines[#lines + 1] = '  message(FATAL_ERROR "Dependency '
        .. dep.name
        .. ' did not define expected target '
        .. dep.target
        .. '")'
      lines[#lines + 1] = 'endif()'
    end
  end
  return table.concat(lines, '\n') .. '\n'
end

M.cmake_options = [[# User-editable project-wide options; scoped to this project's targets.
option(RIVET_WARNINGS "Enable useful compiler warnings" ON)
option(RIVET_SANITIZERS "Enable address and undefined behavior sanitizers" OFF)

function(rivet_target_options target)
  if(RIVET_WARNINGS)
    if(MSVC)
      target_compile_options(${target} PRIVATE /W4)
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(${target} PRIVATE "$<$<COMPILE_LANGUAGE:C,CXX,OBJCXX>:-Wall;-Wextra;-Wpedantic>")

    endif()
  endif()
  if(RIVET_SANITIZERS)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
      target_compile_options(${target} PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
      target_link_options(${target} PRIVATE -fsanitize=address,undefined)
    else()
      message(FATAL_ERROR "This sanitizer preset requires Clang or GCC")
    endif()
  endif()
endfunction()
]]

function M.presets(spec)
  local minimum = spec.std_modules and '"major": 4, "minor": 4' or '"major": 3, "minor": 30'
  return [[{
  "version": 6,
  "cmakeMinimumRequired": { ]] .. minimum .. [[, "patch": 0 },
  "configurePresets": [
    {
      "name": "debug", "displayName": "Debug",
      "generator": "]] .. spec.generator .. [[",
      "binaryDir": "${sourceDir}/build/debug",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Debug", "CMAKE_EXPORT_COMPILE_COMMANDS": true, "BUILD_TESTING": true }
    },
    {
      "name": "release", "displayName": "Release", "inherits": "debug",
      "binaryDir": "${sourceDir}/build/release",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Release" }
    }
  ],
  "buildPresets": [
    { "name": "debug", "configurePreset": "debug" },
    { "name": "release", "configurePreset": "release" }
  ],
  "testPresets": [
    { "name": "debug", "configurePreset": "debug", "output": { "outputOnFailure": true } },
    { "name": "release", "configurePreset": "release", "output": { "outputOnFailure": true } }
  ]
}
]]
end

return M
