-- Project-local support for the separately opted-in standard-library modules.
-- UUIDs verified in Kitware/CMake v4.4.0, v4.4.1, v4.4.2, v4.4.3, v4.4.4:
-- https://github.com/Kitware/CMake/blob/v4.4.4/Help/dev/experimental.rst
return [[# Included before project(): CMake discovers import-std capability with CXX.
# Rivet verifies this experimental gate per release; do not guess future UUIDs.
if(NOT CMAKE_VERSION MATCHES "^4[.]4[.][0-4]$")
  message(FATAL_ERROR
    "Rivet standard-library modules currently support verified CMake versions "
    "4.4.0 through 4.4.4; found ${CMAKE_VERSION}. Use a verified release, update "
    "Rivet's gate support, or create a project with standard-library modules disabled.")
endif()
if(NOT CMAKE_GENERATOR STREQUAL "Ninja")
  message(FATAL_ERROR "Rivet standard-library modules require the Ninja generator.")
endif()
set(CMAKE_EXPERIMENTAL_CXX_IMPORT_STD "f35a9ac6-8463-4d38-8eec-5d6008153e7d")
set(_rivet_std_metadata_override FALSE)
if(DEFINED CMAKE_CXX_STDLIB_MODULES_JSON AND NOT CMAKE_CXX_STDLIB_MODULES_JSON STREQUAL "")
  set(_rivet_std_metadata_override TRUE)
endif()

# Validate relative paths before treating discovered metadata as usable.
function(_rivet_std_metadata_usable path output)
  set(${output} FALSE PARENT_SCOPE)
  if(NOT EXISTS "${path}" OR IS_DIRECTORY "${path}")
    return()
  endif()
  file(READ "${path}" _json)
  string(JSON _count ERROR_VARIABLE _error LENGTH "${_json}" modules)
  if(_error OR _count LESS 1)
    return()
  endif()
  get_filename_component(_base "${path}" DIRECTORY)
  math(EXPR _last "${_count} - 1")
  foreach(_index RANGE 0 ${_last})
    string(JSON _source ERROR_VARIABLE _error GET "${_json}" modules ${_index} source-path)
    if(_error)
      return()
    endif()
    if(NOT IS_ABSOLUTE "${_source}")
      get_filename_component(_source "${_source}" ABSOLUTE BASE_DIR "${_base}")
    endif()
    if(NOT EXISTS "${_source}")
      return()
    endif()
  endforeach()
  set(${output} TRUE PARENT_SCOPE)
endfunction()

# Called after project(): inspect the actual compiler, including toolchain selection.
macro(rivet_check_std_modules standard)
  if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    if(CMAKE_CXX_COMPILER_VERSION VERSION_LESS "18.1.2")
      message(FATAL_ERROR "Standard-library modules require Clang 18.1.2 or newer; selected ${CMAKE_CXX_COMPILER_VERSION}.")
    endif()
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    if(CMAKE_CXX_COMPILER_VERSION VERSION_LESS "15")
      message(FATAL_ERROR "Standard-library modules require GCC 15 or newer; selected ${CMAKE_CXX_COMPILER_VERSION}.")
    endif()
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    if(CMAKE_CXX_COMPILER_VERSION VERSION_LESS "19.36")
      message(FATAL_ERROR "Standard-library modules require MSVC 19.36 or newer; selected ${CMAKE_CXX_COMPILER_VERSION}.")
    endif()
  else()
    message(FATAL_ERROR
      "Standard-library modules are unavailable for selected compiler ${CMAKE_CXX_COMPILER_ID} "
      "${CMAKE_CXX_COMPILER_VERSION}. Select a compatible LLVM Clang, GCC, or MSVC "
      "toolchain in CMakeUserPresets.json; on macOS select Homebrew LLVM rather than AppleClang.")
  endif()

  # Debian/Ubuntu may copy libc++.modules.json into a multiarch directory
  # without adjusting its relative source paths. Prefer valid native discovery;
  # otherwise try metadata beside the selected compiler. Never replace an
  # explicit user override or metadata for a different standard library.
  # On reconfigure CMake restores the metadata path without the library name;
  # libc++.modules.json still identifies that library unambiguously.
  if(NOT _rivet_std_metadata_override
      AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang"
      AND (CMAKE_CXX_STANDARD_LIBRARY STREQUAL "libc++"
        OR (NOT DEFINED CMAKE_CXX_STANDARD_LIBRARY
          AND CMAKE_CXX_STDLIB_MODULES_JSON MATCHES "(^|/)libc[+][+][.]modules[.]json$")))
    _rivet_std_metadata_usable("${CMAKE_CXX_STDLIB_MODULES_JSON}" _rivet_std_valid)
    if(NOT _rivet_std_valid)
      file(REAL_PATH "${CMAKE_CXX_COMPILER}" _rivet_std_compiler)
      get_filename_component(_rivet_std_bindir "${_rivet_std_compiler}" DIRECTORY)
      foreach(_rivet_std_relative IN ITEMS "../lib/c++/libc++.modules.json" "../lib/libc++.modules.json")
        get_filename_component(_rivet_std_candidate
          "${_rivet_std_bindir}/${_rivet_std_relative}" ABSOLUTE)
        _rivet_std_metadata_usable("${_rivet_std_candidate}" _rivet_std_valid)
        if(_rivet_std_valid)
          set(CMAKE_CXX_STDLIB_MODULES_JSON "${_rivet_std_candidate}")
          break()
        endif()
      endforeach()
    endif()
  endif()

  if(NOT "${standard}" IN_LIST CMAKE_CXX_COMPILER_IMPORT_STD)
    message(FATAL_ERROR
      "The selected compiler and standard library do not advertise C++${standard} import std support. "
      "Available standards: ${CMAKE_CXX_COMPILER_IMPORT_STD}. "
      "${CMAKE_CXX_COMPILER_IMPORT_STD_ERROR_MESSAGE}")
  endif()
  if(NOT CMAKE_CXX_STDLIB_MODULES_JSON OR NOT EXISTS "${CMAKE_CXX_STDLIB_MODULES_JSON}")
    message(FATAL_ERROR
      "Standard-library module metadata was not found for ${CMAKE_CXX_COMPILER}. "
      "Set CMAKE_CXX_STDLIB_MODULES_JSON in CMakeUserPresets.json to this toolchain's "
      "installed module metadata file. Current value: ${CMAKE_CXX_STDLIB_MODULES_JSON}")
  endif()
  message(STATUS "Standard-library module metadata: ${CMAKE_CXX_STDLIB_MODULES_JSON}")
endmacro()
]]
