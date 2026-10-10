local rt = require('rivet.runtime')
local M = {}

local function run(executable, args)
  -- Git launched from another repository must not redirect initialization there.
  local argv = { 'env' }
  for _, key in ipairs({
    'GIT_DIR',
    'GIT_WORK_TREE',
    'GIT_COMMON_DIR',
    'GIT_INDEX_FILE',
    'GIT_OBJECT_DIRECTORY',
    'GIT_ALTERNATE_OBJECT_DIRECTORIES',
    'GIT_CEILING_DIRECTORIES',
    'GIT_DISCOVERY_ACROSS_FILESYSTEM',
  }) do
    argv[#argv + 1], argv[#argv + 2] = '-u', key
  end
  argv[#argv + 1], argv[#argv + 2] = 'LC_ALL=C', executable
  for _, arg in ipairs(args) do
    argv[#argv + 1] = arg
  end
  return rt.run(argv)
end

local function repository(root, executable)
  local directory = root
  while not rt.is_dir(directory) do
    assert(not rt.exists(directory), 'Project destination is not a directory: ' .. directory)
    directory = rt.dirname(directory)
    if directory == '' then
      directory = '/'
    end
  end
  local result = run(executable, { '-C', directory, 'rev-parse', '--absolute-git-dir' })
  if result.code == 0 then
    local bare = run(executable, { '-C', directory, 'rev-parse', '--is-bare-repository' })
    assert(
      bare.code == 0 and bare.stdout:match('^false'),
      'Cannot create a project inside a bare Git repository'
    )
    return result.stdout:gsub('[\r\n]+$', '')
  end
  -- Broken .git files and permission/ownership errors are not an absent repo.
  local parent = directory
  while true do
    assert(
      not rt.exists(rt.join(parent, '.git')),
      'Cannot inspect existing Git repository: ' .. result.stderr
    )
    if parent == '/' then
      break
    end
    parent = rt.dirname(parent)
    if parent == '' then
      parent = '/'
    end
  end
  assert(
    result.stderr:find('not a git repository', 1, true),
    'Cannot inspect Git repository: ' .. result.stderr
  )
  return false
end

function M.plan(root)
  local executable =
    assert(rt.executable('git'), 'Git was not found; install it or skip Git initialization.')
  local existing = repository(root, executable)
  return {
    executable = executable,
    existing = existing,
    summary = existing and ('Git: use existing repository at ' .. existing)
      or ('Git: initialize a repository in ' .. root .. ' after creating the files.'),
  }
end

function M.check(root, plan)
  assert(
    repository(root, plan.executable) == plan.existing,
    'Git repository changed since preview; review the project again.'
  )
end

function M.apply(root, plan)
  M.check(root, plan)
  if not plan.existing then
    local result = run(plan.executable, { '-C', root, 'init', '--quiet', '.' })
    assert(result.code == 0, result.stderr)
  end
end

return M
