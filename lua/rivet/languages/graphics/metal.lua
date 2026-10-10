return {
  setup = [=[if(NOT APPLE)
  message(FATAL_ERROR "The Metal profile requires macOS and Xcode's Metal tools")
endif()
set(RIVET_METAL_CPP_DIR "" CACHE PATH "Directory containing Metal/Metal.hpp from Apple's Metal-cpp SDK")
find_path(RIVET_METAL_CPP_INCLUDE Metal/Metal.hpp HINTS "${RIVET_METAL_CPP_DIR}" REQUIRED)
find_program(RIVET_XCRUN xcrun REQUIRED)
find_library(RIVET_METAL Metal REQUIRED)
find_library(RIVET_FOUNDATION Foundation REQUIRED)
]=],
  source = [=[#define NS_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <array>
#include <cstdint>
#include <iostream>
int main() {
  auto *pool = NS::AutoreleasePool::alloc()->init();
  auto *device = MTL::CreateSystemDefaultDevice();
  if (!device) { std::cerr << "No Metal device\n"; pool->release(); return 77; }
  NS::Error *error = nullptr;
  auto *path = NS::String::string(RIVET_SHADER_DIR "/triangle.metallib", NS::UTF8StringEncoding);
  auto *library = device->newLibrary(path, &error);
  if (!library) { std::cerr << (error ? error->localizedDescription()->utf8String() : "Library load failed") << '\n'; device->release(); pool->release(); return 1; }
  auto *vertex = library->newFunction(NS::String::string("vertex_main", NS::UTF8StringEncoding));
  auto *fragment = library->newFunction(NS::String::string("fragment_main", NS::UTF8StringEncoding));
  auto *descriptor = MTL::RenderPipelineDescriptor::alloc()->init();
  descriptor->setVertexFunction(vertex); descriptor->setFragmentFunction(fragment);
  descriptor->colorAttachments()->object(0)->setPixelFormat(MTL::PixelFormatRGBA8Unorm);
  auto *pipeline = device->newRenderPipelineState(descriptor, &error);
  if (!pipeline) { std::cerr << (error ? error->localizedDescription()->utf8String() : "Pipeline failed") << '\n'; return 1; }
  auto *td = MTL::TextureDescriptor::texture2DDescriptor(MTL::PixelFormatRGBA8Unorm,64,64,false);
  td->setUsage(MTL::TextureUsageRenderTarget); td->setStorageMode(MTL::StorageModeShared);
  auto *texture = device->newTexture(td);
  auto *pass = MTL::RenderPassDescriptor::renderPassDescriptor();
  auto *color = pass->colorAttachments()->object(0);
  color->setTexture(texture); color->setLoadAction(MTL::LoadActionClear); color->setStoreAction(MTL::StoreActionStore);
  color->setClearColor(MTL::ClearColor(0.0,0.0,0.0,1.0));
  auto *queue = device->newCommandQueue(); auto *command = queue->commandBuffer();
  auto *encoder = command->renderCommandEncoder(pass);
  encoder->setRenderPipelineState(pipeline); encoder->drawPrimitives(MTL::PrimitiveTypeTriangle,NS::UInteger(0),NS::UInteger(3)); encoder->endEncoding();
  command->commit(); command->waitUntilCompleted();
  std::array<std::uint8_t,4> pixel{};
  texture->getBytes(pixel.data(),4,MTL::Region::Make2D(32,32,1,1),0);
  const bool valid = command->status()!=MTL::CommandBufferStatusError && pixel[0]>150 && pixel[3]>200;
  std::cout << "Metal center pixel: " << int(pixel[0]) << ',' << int(pixel[1]) << ',' << int(pixel[2]) << '\n';
  queue->release(); texture->release(); pipeline->release(); descriptor->release(); vertex->release(); fragment->release(); library->release(); device->release(); pool->release();
  return valid ? 0 : 1;
}
]=],
  shaders = {
    ['triangle.metal'] = [=[#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_main(uint id [[vertex_id]]) {
  const float2 positions[3] = {float2(-0.8,-0.8),float2(0.8,-0.8),float2(0.0,0.8)};
  return float4(positions[id],0.0,1.0);
}
fragment float4 fragment_main() { return float4(0.92,0.35,0.45,1.0); }
]=],
  },
  finish = function(name)
    return 'target_include_directories('
      .. name
      .. ' PRIVATE "${RIVET_METAL_CPP_INCLUDE}")\ntarget_link_libraries('
      .. name
      .. ' PRIVATE "${RIVET_METAL}" "${RIVET_FOUNDATION}")\n'
      .. [=[file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/shaders")
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/shaders/triangle.metallib"
  COMMAND "${RIVET_XCRUN}" -sdk macosx metal "-fmodules-cache-path=${CMAKE_CURRENT_BINARY_DIR}/metal-module-cache" "${PROJECT_SOURCE_DIR}/shaders/triangle.metal" -o "${CMAKE_CURRENT_BINARY_DIR}/shaders/triangle.metallib"
  DEPENDS "${PROJECT_SOURCE_DIR}/shaders/triangle.metal" VERBATIM)
add_custom_target(rivet_shaders DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/shaders/triangle.metallib")
]=]
      .. 'add_dependencies('
      .. name
      .. ' rivet_shaders)\n'
  end,
}
