# Changelog

## 0.1.0 — 2026-10-13

First public release of Rivet.nvim, formerly Outset.

### Added

- Reviewed project creation and native tasks for C++, C, Python, Rust, SwiftPM, and Lua, from Neovim or the optional Lua CLI.
- C++17–26 projects with separate choices for headers, named modules, module layout, and standard-library modules; optional HPC and graphics workload starters.
- File creation asks for the language and template. Source/header pairs, module interface/implementation pairs, mixed C files, and foreign-language files have explicit reviewed plans.
- Lua applications, libraries, and Neovim plugins with Lua, LuaJIT, or Neovim runtime selection, syntax checks, tests, optional formatting/linting, and script/module templates.
- Opt-in Lua embedding examples for C/C++ and Rust, with reviewed host build/dependency changes. Files-only Lua scripting adds no runtime dependency.
- `:RivetConfig` / `rivet config`: explained common clang-format, clang-tidy, and clangd settings, installed-tool validation, and YAML access for advanced options.
- `:RivetUpgrade` / `rivet upgrade`: supplementary template updates using recorded baselines, local-edit preservation, missing-file restoration, and reviewed version metadata.
- Retained output per project, visible task controls, Enter to close completed output, `:RivetOutput`, `:RivetStop`, and optional `task_output = 'close-on-success'`.
- Neovim help, provider interfaces, documentation, license templates, and reviewed Outset migration.

### Fixed

- Preserve private/executable file permissions during replacements and moves.
- Prevent project modules from shadowing Python test/syntax-check tools and falsely reporting success.
- Preserve C++ raw-string contents during module renames.
- Keep another project's running output and stop controls available.
- Pass the selected configuration to multi-configuration CTest fallback tasks.
- Reject unknown C/Swift file targets and conflicting scaffold names.
- Format added C++ files using the current project `.clang-format`.
- Recognize quoted/commented clangd database paths.

### Compatibility and updates

- Neovim 0.11+; built-in `vim.pack` installation needs Neovim 0.12+. macOS and Linux are supported.
- The optional CLI needs Lua 5.1+ or LuaJIT. Release assets contain portable source, not a compiled executable.
- Install language tools explicitly. Lua embedding requires Lua development libraries for C/C++; Rust's pinned vendored `mlua` dependency may download crates during the first build.
- GPU examples need their matching SDK/hardware; CI does not certify GPU runtime support.
- Update Rivet through the plugin manager, restart Neovim, then review `:RivetUpgrade` separately in each project. Older manifests without baselines retain unverifiable local files.
- `require('outset')` and `bin/outset` remain deprecated compatibility shims until 0.3.0. Legacy projects use `:RivetMigrate` before normal Rivet operations.
