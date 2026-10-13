-- Pure questionnaire data. Both editor and optional CLI can consume these steps.
local M = {}
local catalog = require('rivet.catalog')
local function choice(key, title, items, when)
  return { key = key, title = title, items = items, when = when }
end
function M.new(_, context)
  return {
    choice('standard', 'C++ standard', {
      {
        id = 26,
        label = 'C++26',
        description = 'Current Rivet default. Requires a compiler accepting C++26; individual features vary.',
      },
      {
        id = 23,
        label = 'C++23',
        description = 'Supports named modules and opt-in import std with a compatible toolchain.',
      },
      {
        id = 20,
        label = 'C++20',
        description = 'A useful starting point for portable HPC work. Named modules are optional; the standard library uses headers.',
      },
      {
        id = 17,
        label = 'C++17',
        description = 'Conventional headers and sources for older libraries and toolchains.',
      },
    }),
    choice('profile', 'Workload profile', require('rivet.languages.cpp_profiles').items),
    {
      key = 'cuda_standard',
      title = 'CUDA standard (separate from host C++)',
      items = {
        { id = 20, label = 'CUDA C++20' },
        { id = 23, label = 'CUDA C++23' },
        {
          id = 17,
          label = 'CUDA C++17',
        },
      },
      when = function(s)
        return s.profile == 'cuda'
      end,
    },
    {
      key = 'cuda_architectures',
      title = 'CUDA GPU architectures (native, all-major, or 80;90)',
      input = true,
      default = 'native',
      when = function(s)
        return s.profile == 'cuda'
      end,
    },
    choice('kind', 'Project kind', catalog.kinds),
    choice('modules', 'C++ interface', {
      {
        id = true,
        label = 'Named modules',
        description = 'C++20 and newer. Requires a compatible compiler, scanner, CMake, and Ninja.',
        preview = 'export module math;\nexport int add(int a, int b) { return a + b; }\n\n// Consumer:\nimport math;\n\nAn interface can contain declarations and definitions. Choose its file arrangement next.',
      },
      {
        id = false,
        label = 'Headers and source files',
        preview = '// math.hpp\n#pragma once\nint add(int a, int b);\n\n// math.cpp\n#include "math.hpp"\nint add(int a, int b) { return a + b; }',
      },
    }, function(s)
      if s.standard < 20 then
        s.modules = false
        return false
      end
      return true
    end),
    choice('module_layout', 'Module files', {
      {
        id = 'split',
        label = 'Interface + implementation',
        description = 'Keep exported declarations and definitions in separate compiled files.',
        preview = '// math.cppm\nexport module math;\nexport int add(int, int);\n\n// math.cpp\nmodule math;\nint add(int a, int b) { return a + b; }',
      },
      {
        id = 'single',
        label = 'Single-file module',
        description = 'Keep declarations and definitions together in one interface. No matching header or implementation file is needed.',
        preview = '// math.cppm\nexport module math;\nexport int add(int a, int b) { return a + b; }\n\n// CMake compiles the interface and consumers link its library.',
      },
    }, function(s)
      return s.modules
    end),
    choice('std_modules', 'Standard library', {
      {
        id = false,
        label = 'Standard-library headers',
        description = 'Default. Independent of whether your own interfaces use modules.',
        preview = '#include <iostream>\n#include <vector>\n\n// Available in every supported language mode.',
      },
      {
        id = true,
        label = 'import std (opt-in)',
        description = 'C++23 and newer; requires verified compiler, standard-library and CMake support.',
        preview = 'import std;\n\nint main() {\n  std::vector<int> values{1, 2, 3};\n  std::cout << values.size() << "\\n";\n}\n\nConfigure checks the selected language mode and toolchain. Build once to prepare module artifacts for clangd.',
      },
    }, function(s)
      if s.standard < 23 then
        s.std_modules = false
        return false
      end
      return true
    end),
    choice('layout', 'Project layout', catalog.layouts),
    choice('style', 'Formatting style', context.styles or catalog.styles),
    choice('header_guard', 'Header protection', {
      { id = 'pragma', label = '#pragma once', preview = '#pragma once\n\nint answer();' },
      {
        id = 'ifndef',
        label = '#ifndef / #define',
        preview = '#ifndef PROJECT_ANSWER_HPP\n#define PROJECT_ANSWER_HPP\n\nint answer();\n\n#endif // PROJECT_ANSWER_HPP',
      },
    }),
    choice('generator', 'Build generator', {
      { id = 'Ninja', label = 'Ninja' },
      { id = 'Unix Makefiles', label = 'Unix Makefiles' },
    }, function(s)
      if s.modules or s.std_modules then
        s.generator = 'Ninja'
        return false
      end
      return true
    end),
    {
      key = 'compiler',
      title = 'C++ compiler',
      input = true,
      default = (context.tools or {}).clangxx or 'clang++',
      validate = function(value)
        assert(value ~= '', 'A compiler command or path is required')
      end,
    },
  }
end
function M.file(spec)
  local templates = {
    { id = 'c_source', label = 'C source for mixed C/C++' },
    { id = 'c_header', label = 'C header with extern C guards' },
    { id = 'c_pair', label = 'C source + header with extern C guards' },
    {
      id = 'source',
      label = 'Source file',
      preview = '// A .cpp file attached to the selected target.',
    },
    {
      id = 'pair',
      label = 'Source and header',
      preview = '// Matching .cpp and .hpp files with the selected header protection.',
    },
    { id = 'header', label = 'Header', preview = '#pragma once\n\n// Public declarations.' },
    {
      id = 'class',
      label = 'Class (source and header)',
      preview = 'class Renderer {\npublic:\n  Renderer();\n};',
    },
  }
  if spec.modules then
    templates[#templates + 1] = {
      id = 'module_pair',
      label = 'Module interface + implementation',
      preview = 'export module project.renderer;\nexport namespace project { int renderer(); }\n\n// Separate .cpp:\nmodule project.renderer;\nnamespace project { int renderer() { return 42; } }',
    }
    templates[#templates + 1] = {
      id = 'module',
      label = 'Module interface',
      preview = 'export module project.renderer;\n\nexport namespace project {\n  // Exported declarations and definitions.\n}',
    }
    templates[#templates + 1] = {
      id = 'module_impl',
      label = 'Module implementation',
      preview = 'module project.renderer;\n\n// Definitions for an existing module interface.',
    }
  end
  local modules = {}
  for name, entry in pairs(spec.module_names or {}) do
    modules[#modules + 1] =
      { id = name, label = name .. ' → ' .. entry.target, target = entry.target }
  end
  table.sort(modules, function(a, b)
    return a.id < b.id
  end)
  local targets = {}
  for _, target in ipairs(spec.targets) do
    if not target.external then
      targets[#targets + 1] = target
    end
  end
  return {
    choice('kind', 'New C++ file', templates),
    {
      key = 'module',
      title = 'Module to implement',
      items = modules,
      when = function(o)
        return o.kind == 'module_impl'
      end,
      apply = function(o, item)
        o.target = item.target
      end,
    },
    {
      key = 'target',
      title = 'Target',
      items = targets,
      when = function(o)
        return o.kind ~= 'module_impl'
      end,
    },
    {
      key = 'name',
      title = 'File/class name (without extension)',
      input = true,
      default = 'renderer',
    },
    {
      key = 'module',
      title = 'Exported module name',
      input = true,
      default = function(o)
        return spec.name .. '.' .. o.name:gsub('/', '.')
      end,
      when = function(o)
        return o.kind == 'module' or o.kind == 'module_pair'
      end,
    },
  }
end
function M.target(spec)
  local links = { { id = '', label = 'Leave unlinked for now' } }
  for _, target in ipairs(spec.targets or {}) do
    if not target.external then
      links[#links + 1] = { id = target.name, label = 'Link into ' .. target.name }
    end
  end
  return {
    choice('kind', 'New target', {
      { id = 'app', label = 'Application / executable' },
      { id = 'library', label = 'Reusable library' },
    }),
    { key = 'name', title = 'Target name', input = true },
    choice('link_to', 'Which target will use this library?', links, function(o)
      return o.kind == 'library'
    end),
  }
end
function M.dependency(spec)
  local targets = {}
  for _, target in ipairs(spec.targets) do
    if not target.external then
      targets[#targets + 1] = target
    end
  end
  return {
    { key = 'name', title = 'CPM package name', input = true, default = 'fmt' },
    {
      key = 'repository',
      title = 'GitHub repository (owner/repo)',
      input = true,
      default = 'fmtlib/fmt',
    },
    {
      key = 'tag',
      title = 'Pinned revision (full commit SHA preferred, or version tag)',
      input = true,
    },
    {
      key = 'target',
      title = 'Dependency CMake target to link',
      input = true,
      default = 'fmt::fmt',
    },
    choice('link_to', 'Target to link', targets),
  }
end
return M
