# Rivet.nvim

A Lua project scaffolder and Neovim front end for C++, C, Python, Rust, and
SwiftPM. The same project model drives file templates, the optional CLI, and
the editor. Projects use their native build and package tools, with previews
before generated file changes.

The C++ provider supports C++17, C++20, C++23, and C++26 with CMake, Ninja, and CPM. Named modules are an
explicit choice, as are conventional headers, include guards, formatting, and
directory layout. Standard-library modules (`import std;`) are a separate
opt-in, independent of how your own interfaces are organized. C++26 mode requests
the newest language dialect; individual language and standard-library features
still depend on the compiler.

## Documentation

The `docs/` site includes getting-started guides, Neovim and CLI references,
module and CMake examples, templates, dependencies, and provider authoring.
It uses TypeScript, SvelteKit, mdsvex, and Bun, with local search and copyable
code examples. See [the docs development guide](docs/README.md) for details.

```sh
cd docs
bun install --frozen-lockfile
bun run dev
```

## Renaming from Project Workbench

The project is now **Rivet** (`rivet.nvim`). Update your plugin setup to
`require('rivet').setup(...)`, commands to `:RivetNew` / `:RivetTask`, and
shell invocations to `rivet`. The launcher now uses `RIVET_LUA` for an alternate
Lua runtime. Adjust the checkout path in your Neovim configuration to its actual
location; renaming the plugin does not move an existing checkout.

New projects use `.rivet.json`, `cmake/RivetTargets.cmake`, and `RIVET_*`
CMake options. Existing Workbench-generated projects are not automatically
migrated; keep their original tooling until migrating their manifest and managed
CMake files together. Simply renaming the manifest is insufficient.

## Requirements

- Neovim 0.11+ for the editor interface.
- Lua 5.1+ or LuaJIT for the CLI. No LuaRocks packages are required.

Install the tools for the languages you use: Python 3.11+ (optionally uv), Rust
with Cargo, or Swift 6+ with SwiftPM. Ruff, Clippy, and Swift Format provide
their respective format/lint tasks. Graphics and HPC profiles have additional
SDK requirements listed in the documentation.

For generated C/C++ projects:

- CMake 3.30+ and a compiler that accepts your selected C++ mode (26 by default; feature support varies).
- Ninja 1.11+ for named modules. Unix Makefiles are available when both module
  options are disabled.
- `import std;` additionally requires a verified CMake experimental gate and a
  compiler/standard-library combination supporting it in the selected C++23 or C++26 mode. The current
  helper accepts CMake 4.4.0–4.4.4; LLVM 23.1.2 with Homebrew libc++ and CMake 4.4.4
  is a tested configuration. Linux testing also covers LLVM/libc++ 21.1.8 with CMake 4.4.4. Ninja is required even when your project uses headers.
- `clang-format` for actual style previews and source formatting.
- `just` is optional; generated recipes call the project's CMake presets.

On macOS, Homebrew LLVM is a useful choice for named modules because it includes
`clang-scan-deps`. The compiler and scanner need compatible versions. The tool
does not install or upgrade compilers or packages.

Lua is already executable through its interpreter. LuaJIT is an alternative Lua
runtime with a JIT compiler; it is not necessary to make a command-line tool.
LuaRocks distributes Lua packages and is not a runtime. Rivet deliberately
uses portable Lua and requires no extra Lua libraries.

## Obtain the development checkout

Clone [guzman109/Rivet](https://github.com/guzman109/Rivet):

```sh
git clone https://github.com/guzman109/Rivet.git rivet.nvim
cd rivet.nvim
```

This is the development version; no compiled standalone binary is distributed. The plugin contains `lua/rivet/init.lua`, `plugin/rivet.lua`, and `bin/rivet`.

The website's [installation and language chooser](docs/src/content/start-here.svx)
links to first-run walkthroughs for C++, C, Python, Rust, and SwiftPM. The editor
uses its bundled Lua; installing a separate Lua interpreter is only necessary
for the optional CLI. The supported filesystem/process workflow is macOS/Linux.

## Neovim

With lazy.nvim:

```lua
{
  'guzman109/Rivet',
  name = 'rivet.nvim',
  main = 'rivet',
  opts = { default_preset = 'debug' },
}
```

For a local checkout, add it to `runtimepath` and initialize the front end:

```lua
vim.opt.runtimepath:prepend(vim.fn.expand('/path/to/rivet.nvim'))
require('rivet').setup({
  default_preset = 'debug',
})
```

Replace `/path/to/rivet.nvim` with your checkout. New folders start in Neovim's
working directory unless you set `projects_dir` to a location you choose.
`:RivetNew` offers **New folder** or **Current folder**. Current-folder mode
uses `:pwd`, suggests a C++-compatible version of the folder name, and lets you
edit that name without creating an extra directory.

The wizard also offers Git initialization. The review shows whether it will
initialize a repository or reuse an existing one, including an enclosing repo
or worktree. Initialization runs after saving the files and never stages or
commits them. Each provider generates a language-appropriate `.gitignore` for
build outputs, caches, and local settings. Existing ignore rules are
preserved after the generated rules so their exceptions retain priority.

| Command | Purpose |
| --- | --- |
| `:RivetNew` | Choose project options, compare previews, and create a project. |
| `:RivetFile` | Add a source, header, pair, class, module interface, or implementation. |
| `:RivetHeader` | Preview an addition, edit, or removal of the current file's comment header. |
| `:RivetHeaderDefaults` | Review comment header defaults for future project files. |
| `:RivetTarget` | Add an executable or static library target. |
| `:RivetDependency` | Add a CPM dependency and link an exported target. |
| `:RivetCMake` | Inspect and edit configured CMake cache options. |
| `:RivetPreset` | Change the remembered configure preset. |
| `:RivetBuildPreset` / `:RivetTestPreset` | Select associated build/test presets. |
| `:RivetBuildTarget` | Choose a Build target or use preset defaults. |
| `:RivetStatus` | Show active task choices. |
| `:RivetProfile` | Review and save reusable creation choices. |
| `:RivetIdentity` | Preview and save optional local header details. |
| `:RivetRunTarget` | Change the remembered application target. |
| `:RivetTask` | Choose a project task. |
| `:RivetTask build` | Run a particular task (`configure`, `build`, `test`, `run`, or `format`). |
| `:RivetTask repeat` | Repeat the previous task using current build choices. |
| `:RivetDoctor` | Inspect the selected preset, actual toolchain, and clangd database. |

Wizard previews use Backspace to return to earlier answers; text prompts accept
`:back`. `:RivetProfile` saves reusable choices, and `:RivetIdentity` saves
optional header details after review. See the docs configuration reference.

Preview lists follow `j`/`k`. Press Enter to select, Tab to move between the list
and its scrollable preview, and `q` or Escape to cancel. The final review shows
every planned file and its content. Press `c` or Ctrl-S to apply that reviewed
plan. Project files are not written before this step.

Choose **Personalize and preview styles** in the creation wizard to add file
comment headers. Enter optional author, email, organization, date, copyright,
license expression, and description first; then compare compact, Xcode-style,
documentation, and SPDX styles with those details. Blank fields are omitted;
SPDX is offered when you supply a license expression. `today` resolves to each
new file's creation date. Defaults are saved in `.rivet.json` and used by new
source, header, module, and target templates in both interfaces.

`:RivetHeader` edits the current C/C++ buffer after a diff and full-file review.
An existing leading comment can be replaced or kept. Apply with `c`, save with
`:write`, or undo with `u`; a changed buffer invalidates its pending preview.
`:RivetHeaderDefaults` reviews a manifest-only change for future files without
rewriting existing sources. See the docs site's **File comment headers** guide
and **Your first project** walkthrough.

The wizard asks separately about **C++ interfaces** (your named modules or
headers) and the **standard library** (headers or `import std;`). Standard-library
headers remain the default. After creating an `import std;` project, a final
choice offers an asynchronous Debug configure/build to create the module
artifacts clangd needs. Choosing Later leaves the project ready for
`:RivetTask build`; a configure failure stops the build and keeps the
generated files for correction.

The CMake editor works with a configured build directory. Configure the project
first; then use the cache view to inspect help text, types, and values. Changing
a cache option writes a local preset and reconfigures. Selecting a
different compiler or generator is better handled with a separate build preset
and directory than by reusing an incompatible cache.

For CMake, Build configures first. Test and Run configure and build first, and
stop on a failed or canceled step. Output streams into a reused window; Ctrl-C
stops the local process group (including compiler/application children), and
`q` closes its output without stopping it. Other language tasks use their
native tools; Python Build checks syntax. Remote scheduler jobs need an
explicit cancel hook.
GCC/Clang-style file errors, warnings, and notes populate quickfix as they arrive;
use `:copen`, Enter, `:cnext`, and `:cprevious` to navigate. Each workflow gets
one list, preserving diagnostics across its steps. Save sources before building.

Run selects an application when several exist; recorded starter tests are
excluded. Existing CMake products can include test programs, so choose the
intended application.
Preset, application, and last task are remembered per project across editor
restarts under `stdpath('state')/rivet/tasks/`. Use `:RivetPreset` and
`:RivetRunTarget` to change the choices, or `:RivetTask repeat` to run again.
Custom configure/build/test presets use CMake’s native includes, inheritance,
conditions, environments, and toolchain settings. Executables are located through
the CMake File API. `:RivetStatus` and `require("rivet").statusline()` expose choices.
The CLI keeps its explicit flags and defaults. The new-library wizard can also
link the library to an existing target.

## CLI

Use `bin/rivet` directly or place this checkout's `bin` directory on your
`PATH`. The first runtime is portable Lua; the core also runs under LuaJIT.
The initial filesystem/process adapter supports macOS and Linux.

```sh
rivet new ./engine \
  --name engine --modules true --layout feature --style LLVM \
  --generator Ninja --git true --preview

# Omit --preview to create the reviewed project.
rivet new ./engine \
  --name engine --modules true --layout feature --style LLVM \
  --generator Ninja --git true

rivet configure --root ./engine --preset debug
rivet build --root ./engine --preset debug
rivet test --root ./engine --preset debug
rivet run --root ./engine --preset debug
rivet format --root ./engine
```

To create everything in the current folder, use
`rivet new . --git true --preview`, then repeat without `--preview`. The folder supplies the default
project name; `--name` overrides it. Spaces and punctuation become underscores;
leading digits and reserved names receive a `project_` prefix. Git initialization
is opt-in (`--git true|false`); ignore rules are generated either way.

Choose `--standard 17|20|23|26`; C++26 remains the default. C++17 defaults to
headers, named modules require C++20+, and `import std` requires C++23+.

For conventional headers choose `--modules false --header-guard ifndef` or
`--header-guard pragma`. `--kind library` starts a library; `--kind app` starts
an application. Layout choices are `flat`, `feature`, and `library`. Compiler
paths belong in local user presets, keeping shared presets portable.

To use standard-library modules and build the new project immediately:

```sh
rivet new ./compute \
  --name compute --modules true --std-modules true --build
```

`--modules false --std-modules true` uses headers for your own interfaces and
`import std;` in source files. `--std-modules false` keeps standard-library
includes. Both values are explicit booleans. `--build` is optional and applies
only to `new`; it configures and builds after writing the project, returns a
failed tool's exit status, and stops when configure fails. `--preview --build`
only displays the plan. The default first build is Debug; `--preset release`
builds Release. After configure, `.clangd` follows the selected database through
`.cache/rivet/compile_commands.json`; custom `.clangd` settings are preserved.

Inside a generated project, these commands add files and target registration:

```sh
rivet file src/memory/page --kind pair --target engine_core --preview
rivet file src/memory/page --kind pair --target engine_core
rivet file src/memory/pool --kind module --module engine.memory.pool --target engine_core
rivet file src/memory/pool_impl --kind module_impl --module engine.memory.pool --target engine_core
rivet target renderer --kind library
rivet dependency fmt --repository fmtlib/fmt --version 11.2.0 \
  --target fmt::fmt --link-to engine_core --preview
rivet cache --preset debug
rivet cache BUILD_TESTING OFF --preset debug
rivet styles
rivet layouts
rivet doctor
```

Use the actual target name shown in the generated CMake fragment when adding
files or dependencies. `--root` selects a project explicitly; commands otherwise
discover an Rivet manifest or supported native project. Preview mode is also available for file,
target, and dependency mutations.

For C++, a bare filename, such as `page`, goes in the selected target's source directory.
A name containing `/`, such as `src/memory/page`, is relative to the project root.
File extensions are optional. A generated application has `<name>_core`,
`<name>`, and `<name>_test` targets; a library uses `<name>` and `<name>_test`.
`rivet new PATH --interactive` offers a terminal questionnaire with previews.
In the public-library layout, a bare header/pair/class name puts its public
header under `include/<project>/` and its implementation in the target source
directory. Additional libraries use `include/<project>/<target>/`.

Creating a project refuses existing destination files, except for a reviewed
merge that preserves an existing `.gitignore`. Later mutations update
only Rivet's owned files and refuse conflicts or changes made since the
plan was generated. This prevents a stale preview from replacing newer work.

## Why these defaults

Feature folders are a reasonable C++ structure: a renderer, scheduler, or memory
allocator can keep its sources together. Public library headers and module
interfaces still need deliberate API boundaries. A directory does not have to
become a CMake target: create a separate target when a component needs independent
dependencies, compiler settings, reuse, or tests.

Formatting presets describe established codebase conventions, not language
capabilities. LLVM is a natural starting point for compiler and systems work;
Google is familiar in large application and infrastructure codebases; Chromium,
Mozilla, and WebKit come from browser projects; Microsoft is familiar in Windows
codebases; GNU comes from GNU projects. Graphics, games, GPU, HPC, and embedded
projects can use any of them. Formatting alone does not select ownership rules,
error handling, naming conventions, or a concurrency model.

Projects use explicit source lists. Adding a file through Rivet updates the
managed CMake target registration together with the source template. Custom
CMake remains ordinary CMake; the managed fragment is the boundary between
generation and hand editing.

## Modules, headers, and CMake

A named module interface is compiled source, not a header. It can contain both
exported declarations and their definitions in one `.cppm` file:

```cpp
export module engine.memory;
export int page_size() { return 4096; }
```

Consumers use `import engine.memory;` and link the module’s compiled code. No
matching header or separate implementation file is required. Rivet’s starter
offers single-file or split interface/implementation layouts (`--module-layout single|split`); a new `module` template can
contain definitions directly, and `module_impl` is optional. See the
[modules guide](docs/src/content/modules.svx) for both arrangements and sources.

For the alternative split layout, the interface exports declarations:

```cpp
export module engine.memory;

export namespace engine {
int page_size();
}
```

A separate implementation uses `.cpp` and the same module name:

```cpp
module engine.memory;

namespace engine {
int page_size() { return 4096; }
}
```

Consumers write `import engine.memory;`. CMake registers the interface in a
`FILE_SET` of type `CXX_MODULES`; the implementation is an ordinary source file.
The file-set name, module name, target name, and filename are different concepts.

For traditional includes inside a module, place them in its global module
fragment before the named module declaration:

```cpp
module;
#include <cstddef>

export module engine.memory;
```

Rivet defaults to project modules and conventional standard-library includes.
With `--std-modules true`, application sources use `import std;`, including newly
added source and application templates. Module interfaces and implementations
put that import after their own module declaration:

```cpp
export module engine.memory;
import std;

export std::size_t page_size();
```

Headers remain textually includable and should include the headers needed by
their own public declarations. Imports do not provide preprocessor macros; use
the relevant headers when macros are required. A standard-library module and a
header unit such as `import <vector>;` are distinct features. Rivet does not
generate header units.

The opt-in generates `cmake/StandardModules.cmake`. Its experimental gate is
included before `project()` discovers the compiler. After discovery, it checks
that the selected toolchain supports `import std;` for the selected standard, locates a missing
libc++ module manifest relative to that compiler when possible, and enables
module scanning and `CXX_MODULE_STD` on project targets. Host-specific compiler
paths stay in ignored `CMakeUserPresets.json`; discovered library paths stay in
the build configuration. Unsupported CMake or compiler/library combinations
produce an actionable configure error. Rivet does not silently switch back
to includes.
If automatic manifest discovery is unavailable, set
`CMAKE_CXX_STDLIB_MODULES_JSON` in the local user preset to the selected toolchain's
installed manifest. A manifest from an unrelated compiler/standard-library
installation is not interchangeable.

CMake still gates `import std;` experimentally. Its gate can change between
versions, so support is limited to verified versions rather than guessing an
identifier for an unknown release. Either project modules or standard-library
modules require Ninja in this implementation; Make is available when both are
disabled. Existing manifests without `std_modules` retain include behavior;
editing that manifest flag alone does not migrate existing source/build files.

Clangd's module support remains experimental. Configure and build the selected
preset so it has a compile database and module artifacts, and enable
`--experimental-modules-support` when starting clangd. Rivet generates
project-local clangd settings; it does not replace your LSP client.
For `import std;`, the first Debug build also compiles the standard-library
module. A successful compiler build and a working clangd version are separate
requirements; restart clangd after generating previously missing artifacts if
its existing diagnostics persist.
The starter uses `std::cout`; that is not a general restriction on `std::println`.
Compare editor diagnostics with a real build, since experimental language-server
support and compiler/library feature support can differ.

References: [CMake modules](https://cmake.org/cmake/help/latest/manual/cmake-cxxmodules.7.html),
[Clang named modules](https://clang.llvm.org/docs/StandardCPlusPlusModules.html),
[Clang C++ status](https://clang.llvm.org/cxx_status.html),
[libc++ modules](https://libcxx.llvm.org/Modules.html),
[clangd module support](https://clangd.llvm.org/features#experimental-c20-modules-support),
[clang-format styles](https://clang.llvm.org/docs/ClangFormatStyleOptions.html).

## Dependency management

CPM fits a CMake-first source dependency workflow. Use explicit versions or,
preferably, immutable Git commit IDs and link the dependency's exported CMake
target. Keep dependencies in the project, keep downloads/cache inside its
sandbox, and commit the dependency declarations. A dependency-free starter can
configure and build without network access.

Tags are convenient, but upstream can move them. A pinned CPM downloader protects
the bootstrap file; it does not prove that all transitive dependency revisions
are immutable. For system-provided libraries, `find_package` remains useful.
Conan or vcpkg may become appropriate when binary packages, ABI profiles, or large
cross-compilation dependency graphs become important; neither is needed merely
to start a C++ project.

Reference: [CPM.cmake](https://github.com/cpm-cmake/CPM.cmake).

## Development

The core is independent of `vim`. The Neovim layer asks questions, renders
previews, and invokes the same planning and project services as the CLI. Keep
language-specific templates and validation inside a provider; keep filesystem
boundaries, preview/apply behavior, and CLI/editor adapters shared.

```
lua/rivet/
  model.lua                 provider registry and dispatch
  languages/cpp.lua         C++ schema, templates, CMake rendering, mutations
  catalog.lua               documented style/layout choices
  project.lua               manifest, conflict detection, confined writes
  runtime.lua               filesystem and process adapter
  cmake.lua                 tasks, presets, typed cache editing
  cli.lua                   terminal commands
  init.lua                  Neovim commands and questionnaire
  ui.lua                    preview panels and task output
```

Additional language providers use a Lua module, which can have a neighboring
directory of template resources when it grows. TOML alone cannot express
validation and build-file updates; a Lua provider keeps those behaviors in one
testable interface. Register a provider before using it:

```lua
local model = require('rivet.model')
model.register('example', require('my_rivet.languages.example'))
local plan = model.plan({ language = 'example', name = 'experiment' })
```

Each provider implements these pure functions:

| Function | Result |
| --- | --- |
| `normalize(options)` | Validated specification; reject unsafe or unsupported inputs. |
| `plan(options)` | `{ spec = specification, files = { [relative_path] = text } }` for a new project. |
| `add_file(spec, options)` | A new specification and the files required for the mutation. |
| `add_target(spec, options)` | A new specification and target-related changes. |
| `add_dependency(spec, options)` | A new specification and dependency-related changes. |

Do not mutate the caller's specification, execute processes, or write files from
a provider. Every path is relative to the project. Returned text includes its
final newline. The manifest carries `schema_version = 1` and the provider's
`language` ID. Unsupported operations should raise an actionable error.

For generated files that later operations may replace, the plan also supplies
`managed = { ['build.recipe'] = true }`. Declare these paths in the initial plan
and repeat affected keys in each mutation. The project service stores their
previous generated content and refuses an update when a user edited it. Ordinary
source files are created without overwriting existing files. Provider
registration must happen in the running process before `--language <id>` is
used; project files never automatically execute a Lua provider.

Register a new language ID: bundled IDs such as `rust` cannot be replaced.

Bundled providers cover C++, C, Python, Rust, and SwiftPM. C++ offers general,
CPU/OpenMP/MPI/CUDA, and Metal/WebGPU/Vulkan/OpenGL profiles. Existing CMake and
native ecosystem projects are discovered without taking over source lists.

New commands include `:RivetFiles`, `:RivetModuleRename`, `:RivetRepair`, and
`:RivetRunOptions`. Local argv/environment/parallel settings and explicit
profiler or cluster hooks live in `.rivet.local.json`; no jobs are submitted in
the background. Package managers keep ownership of dependencies and lockfiles.

See the documentation site for provider walkthroughs, runtime settings, and the
exact compatibility matrix. CPU/OpenMP, Metal, Dawn, and OpenGL have local runtime
checks; CUDA/MPI runtime and the full Vulkan SDK remain unverified here.

## Verify changes

```sh
lua tests/run.lua
luajit tests/run.lua
lua tests/integration.lua
lua tests/batches.lua
nvim --headless -u NONE -i NONE -l tests/nvim_process.lua
nvim --headless -u NONE -i NONE -l tests/nvim_lifecycle.lua
```

Run the other `tests/nvim*.lua` scripts the same way for wizard, task, and header
coverage. Integration tests use disposable temporary projects and installed
toolchains. `tests/batches.lua` reports passed, failed, and skipped checks
separately. Optional GPU checks use `RIVET_METAL_CPP_DIR`, `RIVET_DAWN_DIR`,
`RIVET_GLFW_DIR`, and `RIVET_VULKAN_HEADERS` (the include directory). The uv
installation test requires the explicit `RIVET_TEST_UV=1` opt-in.

A generated GPU executable returning 77 becomes a skipped CTest; CTest itself
can exit 0. A skip is not a passing hardware check. The batch runner also
reports skipped CTest runtime checks separately. See the docs development
guide for the website's type, formatting, highlighting, navigation, and link
checks.

## Licenses and release status

Rivet.nvim is licensed under MIT, copyright 2026 Carlos Guzman; see [LICENSE](LICENSE). Project creation offers MIT, Apache-2.0, BSD-3-Clause, GPL-3.0-only, or no license yet. Selected licenses include the full text, with an explicit copyright holder and a final preview. See the [license guide](docs/src/content/licenses.svx).

The optional `bin/rivet` is a relocatable launcher for the portable Lua CLI, not a compiled standalone binary. `RIVET_LUA=luajit` selects LuaJIT. The Neovim plugin needs no external Lua interpreter. Other products also use the command name `rivet`; use this checkout's path or an explicit symlink rather than replacing another installed command.

`bin/outset` and `require('outset')` remain compatibility entry points. Editor commands now use `:Rivet…`. For an existing Outset project, open it and run `:RivetMigrate`, or inspect `bin/rivet migrate --root /path/to/project --preview` before applying without `--preview`. Migration updates generated configuration references and local settings, keeps changed originals in `.rivet-recovery/`, and leaves application identifiers intact. Reconfigure afterward. Saved editor profiles and task selections are read from their former location until next saved.

See [RELEASING.md](RELEASING.md) for publication gates and packaging. The website has a Bun/Wrangler deployment workflow in [docs/README.md](docs/README.md).
