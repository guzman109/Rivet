-- Reviewed standalone Lua hosts. Existing entry points and native ownership stay intact.
local rt, json = require('rivet.runtime'), require('rivet.json')
local M = {}
local script = [[-- Lua can call functions registered by the host program.
local answer = host_add(20, 22)
assert(answer == 42)
print("Lua says: " .. answer)
]]
local host = [[#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#ifdef __cplusplus
}
#endif

static int host_add(lua_State *state) {
  lua_Number a = luaL_checknumber(state, 1);
  lua_Number b = luaL_checknumber(state, 2);
  lua_pushnumber(state, a + b);
  return 1;
}

int main(int argc, char **argv) {
  lua_State *state = luaL_newstate();
  if (state == NULL) {
    fputs("Could not create Lua state\n", stderr);
    return 1;
  }
  luaL_openlibs(state);
  lua_register(state, "host_add", host_add);
  const char *path = argc > 1 ? argv[1] : RIVET_LUA_SCRIPT;
  if (luaL_dofile(state, path) != 0) {
    const char *error = lua_tostring(state, -1);
    fprintf(stderr, "%s\n", error != NULL ? error : "Lua execution failed");
    lua_close(state);
    return 1;
  }
  lua_close(state);
  return 0;
}
]]
local function append(before, text)
  return before .. (before:sub(-1) == '\n' and '' or '\n') .. '\n' .. text
end
local function name(value)
  assert(type(value) == 'string' and value ~= '', 'Choose a name for the Lua example')
  rt.safe_relative(value)
  assert(
    value:match('^[A-Za-z][A-Za-z0-9_/%-]*$')
      and not value:find('//', 1, true)
      and value:sub(-1) ~= '/',
    'Use an identifier or relative stem with letters, digits, underscores, hyphens, and directories'
  )
  for part in value:gmatch('[^/]+') do
    assert(
      part:match('^[A-Za-z][A-Za-z0-9_%-]*$'),
      'Each example path component must start with a letter'
    )
  end
  return value, value:gsub('[/%-]', '_'):gsub('_+', '_')
end
local function cargo_sections(text)
  assert(
    not text:find('"""', 1, true) and not text:find("'''", 1, true),
    'Cargo.toml has multiline strings; add the mlua dependency and example manually'
  )
  local package, workspace = false, false
  for line in (text .. '\n'):gmatch('(.-)\r?\n') do
    if line:match('^%s*%[package%]%s*#?') then
      package = true
    elseif line:match('^%s*%[workspace%]%s*#?') then
      workspace = true
    end
  end
  return package, workspace
end
local function cargo_package(root, spec, options, example)
  local path = 'Cargo.toml'
  local text = assert(rt.read(rt.confined(root, path)), 'Cargo.toml is missing')
  local package, workspace = cargo_sections(text)
  if not package then
    assert(workspace, 'Choose a Cargo package containing a [package] table')
    assert(
      not text:find('%f[%w_]mlua%f[^%w_]'),
      'The workspace already mentions mlua; review and reuse its dependency configuration manually'
    )
    local member = options.target
    if not member and not spec.external and spec.kind == 'workspace' then
      member = 'crates/' .. spec.name
    end
    assert(
      member and member ~= '',
      'For a virtual Cargo workspace, select its package directory with --target (for example crates/app), or open that package directly'
    )
    rt.safe_relative(member)
    path = member .. '/Cargo.toml'
    text = assert(rt.read(rt.confined(root, path)), 'Selected Cargo package is missing: ' .. path)
    assert(cargo_sections(text), 'Selected Cargo manifest must have a [package] table')
  end
  -- Deliberately refuse all existing references, including renamed/workspace/target
  -- dependencies. Guessing a second mlua version or Lua ABI would be unsafe.
  assert(
    not text:find('%f[%w_]mlua%f[^%w_]'),
    'Cargo.toml already mentions mlua; review its version, Lua feature, and dependency alias manually before adding another host'
  )
  assert(
    not text:match('[\r\n]%s*dependencies%s*=') and not text:match('^%s*dependencies%s*='),
    'Cargo.toml uses an inline dependencies table; add mlua manually'
  )
  assert(
    not text:match('autoexamples%s*=%s*false'),
    'Cargo example discovery is disabled; add an explicit example in Cargo.toml manually'
  )
  local in_example = false
  for line in (text .. '\n'):gmatch('(.-)\r?\n') do
    if line:match('^%s*%[') then
      in_example = line:match('^%s*%[%[%s*[\'"]?example[\'"]?%s*%]%]') ~= nil
    elseif in_example then
      local existing = line:match('^%s*name%s*=%s*[\'"]([^\'"]+)[\'"]')
      assert(existing ~= example, 'Cargo.toml already declares this example: ' .. example)
    end
  end
  return path, text
end
function M.plan(root, options)
  local project, model = require('rivet.project'), require('rivet.model')
  root, options = project.canonical(root), options or {}
  local spec, manifest_before = project.inspect(root)
  assert(
    spec.language == 'c' or spec.language == 'cpp' or spec.language == 'rust',
    'Embedded Lua starters support C, C++, and Rust hosts'
  )
  local stem, id = name(assert(options.name, 'Example name is required'))
  local script_path, target = 'scripts/' .. stem .. '.lua', id .. '_lua'
  local files, expected, notes = {}, {}, {}
  local function create(path, content)
    local full = rt.confined(root, path)
    assert(not rt.exists(full), 'Refusing to overwrite existing file: ' .. path)
    for _, existing in ipairs(spec.files or {}) do
      assert(existing:lower() ~= path:lower(), 'File is already registered: ' .. path)
    end
    files[path], expected[path] = content, false
  end
  local function replace(path, before, after)
    rt.confined(root, path)
    files[path], expected[path] = after, before
  end
  create(script_path, script)
  if not spec.external then
    spec.file_languages = spec.file_languages or {}
    spec.file_languages[script_path] = 'lua'
  end
  if spec.language == 'rust' then
    local manifest, before = cargo_package(root, spec, options, id)
    local prefix = manifest == 'Cargo.toml' and '' or manifest:sub(1, -#'Cargo.toml' - 1)
    local source = prefix .. 'examples/' .. id .. '.rs'
    -- examples/foo.rs is one directory below its package; workspace packages
    -- add one ../ for each component of the package directory.
    local relative = '../'
    for _ in prefix:gmatch('[^/]+') do
      relative = relative .. '../'
    end
    create(
      source,
      'fn main() -> mlua::Result<()> {\n'
        .. '    let lua = mlua::Lua::new();\n'
        .. '    let host_add = lua.create_function(|_, (a, b): (f64, f64)| Ok(a + b))?;\n'
        .. '    lua.globals().set("host_add", host_add)?;\n'
        .. '    lua.load(include_str!("'
        .. relative
        .. script_path
        .. '"))\n'
        .. '        .set_name("'
        .. script_path
        .. '")\n'
        .. '        .exec()\n}\n'
    )
    replace(
      manifest,
      before,
      append(
        before,
        '# Lua runtime for the standalone Rivet example.\n[dependencies.mlua]\nversion = "=0.12.2"\nfeatures = ["lua54", "vendored"]\n'
      )
    )
    notes[#notes + 1] = 'Run: cargo run --manifest-path ' .. manifest .. ' --example ' .. id
    notes[#notes + 1] =
      'Adds the pinned mlua 0.12.2 dependency with Lua 5.4 and vendored features. Creation downloads nothing; the next Cargo build may fetch crates and builds the bundled Lua runtime.'
    notes[#notes + 1] =
      'The example embeds the Lua script with include_str!, independent of the working directory. Rebuild after changing the script.'
  else
    for _, existing in ipairs(spec.targets or {}) do
      assert(existing.name:lower() ~= target:lower(), 'Target already exists: ' .. target)
    end
    local source = 'examples/' .. stem .. '/main.' .. (spec.language == 'c' and 'c' or 'cpp')
    local fragment = 'cmake/Lua_' .. id .. '.cmake'
    local before = assert(rt.read(rt.confined(root, 'CMakeLists.txt')), 'CMakeLists.txt is missing')
    assert(
      not before:find(target, 1, true),
      'CMakeLists.txt already refers to ' .. target .. '; choose a different example name'
    )
    create(source, host)
    create(
      fragment,
      '# Standalone Lua host. Edit this extension directly for custom integration.\n'
        .. 'find_package(Lua REQUIRED)\n'
        .. 'if(TARGET '
        .. target
        .. ')\n  message(FATAL_ERROR "Target '
        .. target
        .. ' already exists")\nendif()\n'
        .. 'add_executable('
        .. target
        .. ' "${CMAKE_CURRENT_LIST_DIR}/../'
        .. source
        .. '")\n'
        .. 'target_include_directories('
        .. target
        .. ' PRIVATE ${LUA_INCLUDE_DIR})\n'
        .. 'target_link_libraries('
        .. target
        .. ' PRIVATE ${LUA_LIBRARIES})\n'
        .. 'target_compile_definitions('
        .. target
        .. ' PRIVATE\n'
        .. '  "RIVET_LUA_SCRIPT=\\"${CMAKE_CURRENT_LIST_DIR}/../'
        .. script_path
        .. '\\"")\n'
        .. 'set_target_properties('
        .. target
        .. ' PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED YES C_EXTENSIONS NO CXX_SCAN_FOR_MODULES OFF)\n'
        .. (
          spec.external
            and ('# Discovery treats CMake hosts uniformly; use an already enabled compiler.\n' .. 'if(CMAKE_CXX_COMPILER_LOADED)\n' .. '  set_source_files_properties("${CMAKE_CURRENT_LIST_DIR}/../' .. source .. '" PROPERTIES LANGUAGE CXX)\n' .. 'elseif(CMAKE_C_COMPILER_LOADED)\n' .. '  set_source_files_properties("${CMAKE_CURRENT_LIST_DIR}/../' .. source .. '" PROPERTIES LANGUAGE C)\n' .. 'else()\n  message(FATAL_ERROR "Enable C or CXX before including this Lua example")\nendif()\n')
          or ''
        )
    )
    replace(
      'CMakeLists.txt',
      before,
      append(
        before,
        '# Standalone Lua scripting example.\ninclude("${CMAKE_CURRENT_LIST_DIR}/'
          .. fragment
          .. '")\n'
      )
    )
    if not spec.external then
      spec.targets[#spec.targets + 1] = {
        name = target,
        type = 'executable',
        kind = 'app',
        external = true,
        source_dir = 'examples/' .. stem,
        sources = { source },
        modules = {},
        headers = {},
        links = {},
        include_dirs = {},
      }
    end
    notes[#notes + 1] = 'Build/run the new '
      .. target
      .. ' executable. It is independent of existing application entry points.'
    notes[#notes + 1] =
      'Requires installed Lua development headers and libraries discoverable by CMake FindLua. Creation downloads nothing.'
    notes[#notes + 1] =
      'The default script path points into this source checkout, independent of the working directory. Pass another script path as the executable’s first argument when deploying.'
    notes[#notes + 1] =
      'The host and CMake extension remain editable. Change their source paths together when moving the example.'
  end
  if not spec.external then
    local registered = {}
    for _, path in ipairs(spec.files) do
      registered[path] = true
    end
    for path in pairs(files) do
      if not registered[path] then
        spec.files[#spec.files + 1] = path
      end
    end
    table.sort(spec.files)
    spec = model.normalize(spec)
    files['.rivet.json'], expected['.rivet.json'] = json.encode(spec), assert(manifest_before)
  end
  return { root = root, spec = spec, files = files, expected = expected, notes = notes }
end
return M
