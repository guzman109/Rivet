local M = {}
M.items = {
  { id = 'general', label = 'General C++' },
  { id = 'cpu', label = 'Parallel CPU (std::thread)' },
  { id = 'openmp', label = 'OpenMP parallel reduction' },
  { id = 'mpi', label = 'MPI distributed reduction' },
  { id = 'cuda', label = 'CUDA vector addition' },
  { id = 'metal', label = 'Metal-cpp offscreen triangle (macOS)' },
  { id = 'webgpu', label = 'Native WebGPU / Dawn offscreen triangle' },
  { id = 'vulkan', label = 'Vulkan offscreen triangle' },
  { id = 'opengl', label = 'OpenGL 3.3 / GLFW triangle' },
}
local descriptions = {
  general = 'A reusable core library, application, and correctness test. Choose modules or headers independently.',
  cpu = 'A std::thread example partitions an uneven array, joins workers, and checks every result.',
  openmp = 'A parallel reduction with an explicit OpenMP compiler/runtime dependency and a correctness test.',
  mpi = 'A distributed all-reduce checked against the actual rank count. Requires MPI and a launcher.',
  cuda = 'A vector-add kernel with CUDA error checks and host readback. Choose GPU architectures and a separate CUDA standard.',
  metal = 'Metal-cpp and compiled MSL shaders draw an offscreen triangle and verify a pixel. Requires macOS, Metal tools, and Metal-cpp headers.',
  webgpu = 'Native Dawn C++ and WGSL draw an offscreen triangle with readback. Requires a Dawn SDK and C++20 or newer.',
  vulkan = 'A Vulkan pipeline and compiled SPIR-V triangle with readback. Requires the Vulkan SDK; Debug uses validation layers.',
  opengl = 'GLFW creates an OpenGL 3.3 core context; loaded functions draw a GLSL triangle. Tests use a hidden window.',
}
for _, item in ipairs(M.items) do
  item.description = descriptions[item.id]
  item.preview =
    'The final review shows every generated source, shader, and build rule.\n\nBuild and runtime checks are separate. Choose the profile executable with :RivetRunTarget.\n\nToolchains and SDKs are selected from your environment; creation does not install them.'
end
function M.normalize(spec)
  spec.profile = spec.profile or 'general'
  local valid = false
  for _, item in ipairs(M.items) do
    if spec.profile == item.id then
      valid = true
    end
  end
  assert(valid, 'Unknown C++ profile: ' .. tostring(spec.profile))
  if spec.profile == 'webgpu' then
    assert(spec.standard >= 20, 'The native Dawn C++ API requires C++20 or newer')
  end
  if spec.profile == 'cuda' then
    spec.cuda_standard = tonumber(spec.cuda_standard or 20)
    assert(
      spec.cuda_standard == 17 or spec.cuda_standard == 20 or spec.cuda_standard == 23,
      'CUDA supports a separate 17/20/23 mode; host C++26 remains independent'
    )
    spec.cuda_architectures = spec.cuda_architectures or 'native'
    local a = spec.cuda_architectures
    assert(type(a) == 'string' and a ~= '', 'Choose CUDA GPU architectures')
    if a ~= 'native' and a ~= 'all' and a ~= 'all-major' then
      for part in a:gmatch('[^;]+') do
        assert(
          part:match('^%d+$') or part:match('^%d+%-real$') or part:match('^%d+%-virtual$'),
          'Invalid CUDA architecture'
        )
      end
      assert(
        not a:find(';;', 1, true) and a:sub(1, 1) ~= ';' and a:sub(-1) ~= ';',
        'Invalid CUDA architecture list'
      )
    end
  end
end
local cpu = [=[#include <algorithm>
#include <iostream>
#include <thread>
#include <vector>
int main() {
  std::vector<int> values(10003, 0);
  const unsigned workers = std::max(1u, std::min(4u, std::thread::hardware_concurrency()));
  std::vector<std::thread> threads;
  for (unsigned rank = 0; rank < workers; ++rank) {
    threads.emplace_back([&, rank] {
      const auto begin = values.size() * rank / workers;
      const auto end = values.size() * (rank + 1) / workers;
      for (auto i = begin; i < end; ++i) values[i] = static_cast<int>(i * 2);
    });
  }
  for (auto &thread : threads) thread.join();
  for (std::size_t i = 0; i < values.size(); ++i) if (values[i] != static_cast<int>(i * 2)) return 1;
  std::cout << "CPU correctness passed with " << workers << " workers\n";
}
]=]
local openmp = [=[#include <iostream>
#include <omp.h>
int main() {
  constexpr long long n = 10003;
  long long sum = 0;
#pragma omp parallel for reduction(+:sum)
  for (long long i = 1; i <= n; ++i) sum += i;
  if (sum != n * (n + 1) / 2) return 1;
  std::cout << "OpenMP correctness passed; max threads = " << omp_get_max_threads() << "\n";
}
]=]
local mpi = [=[#include <iostream>
#include <mpi.h>
int main(int argc, char **argv) {
  if (MPI_Init(&argc, &argv) != MPI_SUCCESS) return 1;
  int rank = 0, size = 0;
  MPI_Comm_rank(MPI_COMM_WORLD, &rank);
  MPI_Comm_size(MPI_COMM_WORLD, &size);
  long long local = rank + 1, total = 0;
  const int status = MPI_Allreduce(&local, &total, 1, MPI_LONG_LONG_INT, MPI_SUM, MPI_COMM_WORLD);
  const bool valid = status == MPI_SUCCESS && total == static_cast<long long>(size) * (size + 1) / 2;
  if (rank == 0) std::cout << "MPI ranks: " << size << ", reduction: " << total << "\n";
  MPI_Finalize();
  return valid ? 0 : 1;
}
]=]
local cuda = [=[#include <cuda_runtime.h>
#include <cstdio>
#include <vector>
__global__ void add(const float *a, const float *b, float *out, int n) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) out[i] = a[i] + b[i];
}
int main() {
  int devices = 0;
  if (cudaGetDeviceCount(&devices) != cudaSuccess || devices == 0) {
    std::fprintf(stderr, "No CUDA device available; runtime test skipped\n"); return 77;
  }
  constexpr int n = 10003;
  std::vector<float> a(n, 1.0f), b(n, 2.0f), out(n);
  float *da = nullptr, *db = nullptr, *dc = nullptr;
  auto cleanup = [&] { cudaFree(da); cudaFree(db); cudaFree(dc); };
  auto check = [](cudaError_t status) { if (status != cudaSuccess) std::fprintf(stderr, "%s\n", cudaGetErrorString(status)); return status == cudaSuccess; };
  const auto bytes = n * sizeof(float);
  if (!check(cudaMalloc(&da, bytes)) || !check(cudaMalloc(&db, bytes)) || !check(cudaMalloc(&dc, bytes))) { cleanup(); return 1; }
  if (!check(cudaMemcpy(da, a.data(), bytes, cudaMemcpyHostToDevice)) || !check(cudaMemcpy(db, b.data(), bytes, cudaMemcpyHostToDevice))) { cleanup(); return 1; }
  add<<<(n + 255) / 256, 256>>>(da, db, dc, n);
  if (!check(cudaGetLastError()) || !check(cudaDeviceSynchronize()) || !check(cudaMemcpy(out.data(), dc, bytes, cudaMemcpyDeviceToHost))) { cleanup(); return 1; }
  cleanup();
  for (float value : out) if (value != 3.0f) return 1;
  std::puts("CUDA correctness passed");
}
]=]
function M.apply(spec, files)
  if spec.profile == 'general' then
    return
  end
  local name = spec.name .. '_' .. spec.profile
  local target = {
    name = name,
    type = 'executable',
    kind = 'app',
    source_dir = 'examples/' .. spec.profile,
    sources = {},
    headers = {},
    modules = {},
    include_dirs = {},
    links = {},
  }
  spec.targets[#spec.targets + 1] = target
  local function add(path, text, field)
    assert(not files[path], 'Duplicate profile file')
    files[path] = text
    spec.files[#spec.files + 1] = path
    if field then
      target[field] = target[field] or {}
      target[field][#target[field] + 1] = path
    end
  end
  local extension = spec.profile == 'cuda' and 'cu' or 'cpp'
  local setup, finish = '', ''
  local source = ({ cpu = cpu, openmp = openmp, mpi = mpi, cuda = cuda })[spec.profile]
  if source then
    add(
      target.source_dir .. '/main.' .. extension,
      require('rivet.headers').render(
        spec.comment_header,
        { filename = 'main.' .. extension, project = spec.name }
      ) .. source,
      'sources'
    )
  end
  if spec.profile == 'cpu' then
    setup = 'find_package(Threads REQUIRED)\n'
    target.links = { 'Threads::Threads' }
  elseif spec.profile == 'openmp' then
    setup = 'find_package(OpenMP REQUIRED COMPONENTS CXX)\n'
    target.links = { 'OpenMP::OpenMP_CXX' }
  elseif spec.profile == 'mpi' then
    setup = 'find_package(MPI REQUIRED COMPONENTS CXX)\n'
    target.links = { 'MPI::MPI_CXX' }
  elseif spec.profile == 'cuda' then
    setup = 'enable_language(CUDA)\nfind_package(CUDAToolkit REQUIRED)\n'
    target.links = { 'CUDA::cudart' }
    finish = 'set_target_properties('
      .. name
      .. ' PROPERTIES CUDA_STANDARD '
      .. spec.cuda_standard
      .. ' CUDA_STANDARD_REQUIRED YES CUDA_EXTENSIONS NO CUDA_ARCHITECTURES "'
      .. spec.cuda_architectures
      .. '")\n'
  else
    setup, finish = require('rivet.languages.graphics').apply(spec, target, add)
  end
  finish = finish .. 'if(BUILD_TESTING)\n'
  if spec.profile == 'mpi' then
    finish = finish
      .. '  add_test(NAME '
      .. name
      .. '_runtime COMMAND "${MPIEXEC_EXECUTABLE}" "${MPIEXEC_NUMPROC_FLAG}" 2 ${MPIEXEC_PREFLAGS} $<TARGET_FILE:'
      .. name
      .. '> ${MPIEXEC_POSTFLAGS})\n'
  else
    finish = finish .. '  add_test(NAME ' .. name .. '_runtime COMMAND ' .. name .. ' --test)\n'
  end
  finish = finish
    .. '  set_tests_properties('
    .. name
    .. '_runtime PROPERTIES LABELS "runtime;'
    .. spec.profile
    .. '" SKIP_RETURN_CODE 77 TIMEOUT 60)\n'
  if spec.profile == 'openmp' then
    finish = finish
      .. '  set_tests_properties('
      .. name
      .. '_runtime PROPERTIES ENVIRONMENT "OMP_NUM_THREADS=2" PROCESSORS 2)\n'
  end
  finish = finish .. 'endif()\n'
  add('cmake/ProfileSetup.cmake', setup)
  add('cmake/Profile.cmake', finish)
  add(
    'PROFILE.md',
    '# '
      .. spec.profile
      .. ' profile\n\nBuild target: `'
      .. name
      .. '`. Select it with `:RivetRunTarget`.\nThe ordinary core correctness test remains independent; the profile test is labeled `runtime;'
      .. spec.profile
      .. '`.\nGPU/context absence returns 77 (CTest skip), never a successful hardware test.\n\nBuild jobs, MPI ranks, OpenMP threads, and GPU allocation are independent.\nSet local arguments/environment and optional launcher hooks with `:RivetRunOptions`.\nNo SDKs or dependencies are downloaded by this profile. See the Rivet HPC/graphics guide for prerequisites.\n'
  )
end
return M
