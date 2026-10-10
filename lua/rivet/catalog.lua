local M = {}
M.style_sample = [[#include <vector>
namespace render {
class FrameQueue {
public:
  int submit(const std::vector<int>& work) {
    if (work.empty()) { return 0; }
    int total = 0;
    for (int item : work) { total += item; }
    return total;
  }
};
}
]]

M.styles = {
  {
    id = 'LLVM',
    label = 'LLVM',
    description = 'LLVM/Clang compiler and systems projects; compact two-space indentation. A useful general starting point; style does not determine application domain.',
    preview = 'if (ready) {\n  process(items);\n}\n',
  },
  {
    id = 'Google',
    label = 'Google',
    description = "Google C++ projects and many services/libraries; two-space indentation. clang-format applies formatting, not Google's broader coding rules.",
    preview = 'if (ready) {\n  process(items);\n}\n',
  },
  {
    id = 'Chromium',
    label = 'Chromium',
    description = 'Chromium browser and infrastructure code; Google-derived formatting with project-specific defaults. Browser code spans systems, graphics, and networking.',
    preview = 'if (ready) {\n  process(items);\n}\n',
  },
  {
    id = 'Mozilla',
    label = 'Mozilla',
    description = 'Mozilla browser/platform code; two-space indentation with distinctive function braces. Relevant examples include systems, rendering, and application code.',
    preview = 'int\nprocess()\n{\n  return 0;\n}\n',
  },
  {
    id = 'WebKit',
    label = 'WebKit',
    description = 'WebKit browser/rendering engine; four-space indentation. A rendering-engine reference, not a universal graphics or game-development standard.',
    preview = 'int process()\n{\n    return 0;\n}\n',
  },
  {
    id = 'Microsoft',
    label = 'Microsoft',
    description = 'Microsoft-style formatting; four spaces and expanded braces. Familiar in Windows and some game/tooling code; individual engine conventions differ.',
    preview = 'if (ready)\n{\n    process(items);\n}\n',
  },
  {
    id = 'GNU',
    label = 'GNU',
    description = 'GNU projects and tools; indented braces and space before call parentheses. Best when matching an existing GNU-oriented codebase.',
    preview = 'if (ready)\n  {\n    process (items);\n  }\n',
  },
}
M.layouts = {
  {
    id = 'feature',
    label = 'Folder by feature',
    description = "Recommended for systems, parallel, and graphics work. Keep a feature's implementation and interface together; grow render/, compute/, platform/ as real features appear.",
    preview = 'app/main.cpp\nsrc/core/core.cppm + core.cpp  (or core.hpp + core.cpp)\ntests/core_test.cpp\ncmake/RivetTargets.cmake\n',
  },
  {
    id = 'library',
    label = 'Public library',
    description = "Separate a reusable library's public headers from implementation. Modules live in modules/. Useful for reusable compute kernels, graphics utilities, and SDKs.",
    preview = 'app/main.cpp  (app projects)\ninclude/<name>/core.hpp  (headers mode)\nsrc/core.cpp\nmodules/core.cppm  (modules mode)\ntests/core_test.cpp\n',
  },
  {
    id = 'flat',
    label = 'Small experiment',
    description = 'Few files at the root; useful for learning, benchmarks, and isolated experiments. Refactor into features when responsibilities grow.',
    preview = 'main.cpp  (app projects)\ncore.cppm + core.cpp  (or core.hpp + core.cpp)\ncore_test.cpp\ncmake/RivetTargets.cmake\n',
  },
}
M.kinds = {
  {
    id = 'app',
    label = 'Application + reusable core',
    description = 'An executable, a reusable static core library, and an offline CTest check. A practical starting point for tools and graphics applications.',
    preview = 'application -> core library\ncore_test -> core library\n',
  },
  {
    id = 'library',
    label = 'Reusable library',
    description = 'A static library and an offline CTest check. Add executable targets later for demos or benchmarks.',
    preview = 'library\ncore_test -> library\n',
  },
}
return M
