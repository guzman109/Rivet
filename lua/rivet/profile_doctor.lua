local rt = require('rivet.runtime')
local M = {}
function M.inspect(spec, context, cache)
  local profile = spec.profile
  if not profile or profile == 'general' then
    return {}
  end
  local report = {
    {
      level = 'info',
      message = 'Workload profile: '
        .. profile
        .. '. Compilation and runtime capability are checked separately.',
    },
  }
  local function entry(level, message)
    report[#report + 1] = { level = level, message = message }
  end
  local configured = rt.read(rt.confined(context.binaryDir, 'CMakeCache.txt')) ~= nil
  if profile == 'cuda' then
    local compiler = cache.CMAKE_CUDA_COMPILER
    entry(
      compiler and not compiler:match('NOTFOUND$') and 'ok' or 'warn',
      'CUDA compiler: ' .. (compiler or 'configure to discover NVCC')
    )
    entry(
      'info',
      'Host C++'
        .. spec.standard
        .. '; CUDA C++'
        .. spec.cuda_standard
        .. '; architectures '
        .. spec.cuda_architectures
    )
    entry(
      'info',
      'NVCC host compiler compatibility is independent of the host C++ target. Set CMAKE_CUDA_HOST_COMPILER and explicit architectures in a fresh local preset for cross/cluster builds.'
    )
  elseif profile == 'mpi' then
    entry(
      cache.MPI_CXX_COMPILER and 'ok' or 'warn',
      'MPI C API from C++: '
        .. (cache.MPI_CXX_COMPILER or 'configure with an MPI installation or wrapper compiler')
    )
    entry(
      'info',
      'Use an explicit mpiexec/srun launcher for multiple ranks. Build jobs do not set MPI ranks.'
    )
  elseif profile == 'openmp' then
    entry(
      cache.OpenMP_CXX_FLAGS and 'ok' or 'warn',
      'OpenMP flags: ' .. (cache.OpenMP_CXX_FLAGS or 'configure to discover the compiler runtime')
    )
  elseif profile == 'metal' then
    entry(
      rt.run({ 'uname', '-s' }).stdout:match('Darwin') and 'ok' or 'error',
      'Metal-cpp requires macOS and Xcode Metal tools'
    )
    local metal = rt.executable('xcrun') and rt.run({ 'xcrun', '--find', 'metal' })
    entry(
      metal and metal.code == 0 and 'ok' or 'error',
      'Metal shader compiler: ' .. (metal and metal.stdout:gsub('%s+$', '') or 'unavailable')
    )
    entry(
      cache.RIVET_METAL_CPP_INCLUDE and 'info' or 'warn',
      'Metal-cpp headers: '
        .. (cache.RIVET_METAL_CPP_INCLUDE or 'set RIVET_METAL_CPP_DIR in CMakeUserPresets.json')
    )
  elseif profile == 'webgpu' then
    entry(
      cache.Dawn_DIR and not cache.Dawn_DIR:match('NOTFOUND$') and 'ok' or 'warn',
      'Native Dawn SDK: ' .. (cache.Dawn_DIR or 'set CMAKE_PREFIX_PATH to a Dawn installation')
    )
    entry(
      'info',
      'This profile is native C++/WGSL. Browser WebGPU is a separate deployment workflow.'
    )
  elseif profile == 'vulkan' then
    entry(
      cache.Vulkan_LIBRARY and not cache.Vulkan_LIBRARY:match('NOTFOUND$') and 'ok' or 'warn',
      'Vulkan loader: ' .. (cache.Vulkan_LIBRARY or 'install/select the Vulkan SDK')
    )
    entry(
      'info',
      'Debug needs VK_LAYER_KHRONOS_validation; shaders need glslc. Apple platforms use the portability subset (such as MoltenVK).'
    )
  elseif profile == 'opengl' then
    entry(
      cache.glfw3_DIR and not cache.glfw3_DIR:match('NOTFOUND$') and 'ok' or 'warn',
      'GLFW: ' .. (cache.glfw3_DIR or 'select GLFW 3.3+ with CMAKE_PREFIX_PATH')
    )
    entry(
      'info',
      'Requests an OpenGL 3.3 core context, loads core functions with GLFW, and validates GLSL at runtime. macOS OpenGL is deprecated.'
    )
  end
  entry(
    'info',
    configured
        and 'Run CTest for correctness. A test executable returning 77 is skipped; CTest itself may still exit 0. Inspect skipped tests separately from passing GPU checks.'
      or 'Run configure to resolve dependencies; Doctor never installs an SDK.'
  )
  return report
end
return M
