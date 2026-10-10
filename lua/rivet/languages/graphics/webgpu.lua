return {
  setup = 'find_package(Threads REQUIRED)\nfind_package(Dawn CONFIG REQUIRED)\n',
  source = [=[#include <webgpu/webgpu_cpp.h>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
int main() {
  const wgpu::InstanceFeatureName feature=wgpu::InstanceFeatureName::TimedWaitAny;
  wgpu::InstanceDescriptor instance_desc{};instance_desc.requiredFeatureCount=1;instance_desc.requiredFeatures=&feature;
  auto instance=wgpu::CreateInstance(&instance_desc);
  if (!instance) { std::cerr<<"Dawn instance unavailable\n";return 1; }
  wgpu::Adapter adapter;
  wgpu::RequestAdapterOptions options{};
  const auto requested=instance.RequestAdapter(&options,wgpu::CallbackMode::WaitAnyOnly,
    [](wgpu::RequestAdapterStatus status,wgpu::Adapter value,wgpu::StringView,void *userdata){if(status==wgpu::RequestAdapterStatus::Success)*static_cast<wgpu::Adapter*>(userdata)=value;},&adapter);
  if (instance.WaitAny(requested,UINT64_MAX)!=wgpu::WaitStatus::Success || !adapter) {std::cerr<<"No WebGPU adapter\n";return 77;}
  wgpu::AdapterInfo info{};adapter.GetInfo(&info);
  if (info.backendType==wgpu::BackendType::Null) {std::cerr<<"No hardware backend available\n";return 77;}
  wgpu::Device device;
  wgpu::DeviceDescriptor device_desc{};
  const auto device_request=adapter.RequestDevice(&device_desc,wgpu::CallbackMode::WaitAnyOnly,
    [](wgpu::RequestDeviceStatus status,wgpu::Device value,wgpu::StringView,void *userdata){if(status==wgpu::RequestDeviceStatus::Success)*static_cast<wgpu::Device*>(userdata)=value;},&device);
  if (instance.WaitAny(device_request,UINT64_MAX)!=wgpu::WaitStatus::Success || !device) return 1;
  std::ifstream stream(std::string(RIVET_SHADER_DIR)+"/triangle.wgsl");
  if (!stream) {std::cerr<<"Missing WGSL shader\n";return 1;}
  const std::string source{std::istreambuf_iterator<char>(stream),std::istreambuf_iterator<char>()};
  wgpu::ShaderSourceWGSL wgsl{};wgsl.code=source.c_str();wgpu::ShaderModuleDescriptor shader_desc{};shader_desc.nextInChain=&wgsl;
  auto shader=device.CreateShaderModule(&shader_desc);
  wgpu::ColorTargetState color_target{};color_target.format=wgpu::TextureFormat::RGBA8Unorm;
  wgpu::FragmentState fragment{};fragment.module=shader;fragment.entryPoint="fragment_main";fragment.targetCount=1;fragment.targets=&color_target;
  wgpu::RenderPipelineDescriptor pipeline_desc{};pipeline_desc.vertex.module=shader;pipeline_desc.vertex.entryPoint="vertex_main";pipeline_desc.fragment=&fragment;pipeline_desc.primitive.topology=wgpu::PrimitiveTopology::TriangleList;
  auto pipeline=device.CreateRenderPipeline(&pipeline_desc);
  wgpu::TextureDescriptor texture_desc{};texture_desc.size={64,64,1};texture_desc.format=wgpu::TextureFormat::RGBA8Unorm;texture_desc.usage=wgpu::TextureUsage::RenderAttachment|wgpu::TextureUsage::CopySrc;
  auto texture=device.CreateTexture(&texture_desc);
  wgpu::BufferDescriptor buffer_desc{};buffer_desc.size=64*64*4;buffer_desc.usage=wgpu::BufferUsage::CopyDst|wgpu::BufferUsage::MapRead;
  auto buffer=device.CreateBuffer(&buffer_desc);
  wgpu::RenderPassColorAttachment attachment{};attachment.view=texture.CreateView();attachment.loadOp=wgpu::LoadOp::Clear;attachment.storeOp=wgpu::StoreOp::Store;attachment.clearValue={0,0,0,1};
  wgpu::RenderPassDescriptor pass_desc{};pass_desc.colorAttachmentCount=1;pass_desc.colorAttachments=&attachment;
  auto encoder=device.CreateCommandEncoder();auto pass=encoder.BeginRenderPass(&pass_desc);pass.SetPipeline(pipeline);pass.Draw(3);pass.End();
  wgpu::TexelCopyTextureInfo from{};from.texture=texture;
  wgpu::TexelCopyBufferInfo to{};to.buffer=buffer;to.layout.bytesPerRow=256;to.layout.rowsPerImage=64;
  const wgpu::Extent3D extent{64,64,1};encoder.CopyTextureToBuffer(&from,&to,&extent);
  auto commands=encoder.Finish();device.GetQueue().Submit(1,&commands);
  bool mapped=false;
  auto mapping=buffer.MapAsync(wgpu::MapMode::Read,0,buffer_desc.size,wgpu::CallbackMode::WaitAnyOnly,
    [](wgpu::MapAsyncStatus status,wgpu::StringView,void *userdata){*static_cast<bool*>(userdata)=status==wgpu::MapAsyncStatus::Success;},&mapped);
  if(instance.WaitAny(mapping,UINT64_MAX)!=wgpu::WaitStatus::Success || !mapped) {std::cerr<<"GPU readback failed\n";return 1;}
  const auto *data=static_cast<const std::uint8_t*>(buffer.GetConstMappedRange());
  if(!data) return 1;
  const auto *pixel=data+(32*64+32)*4;const bool valid=pixel[0]>150 && pixel[3]>200;
  std::cout<<"WebGPU center pixel: "<<int(pixel[0])<<','<<int(pixel[1])<<','<<int(pixel[2])<<'\n';buffer.Unmap();return valid ? 0 : 1;
}
]=],
  shaders = {
    ['triangle.wgsl'] = [=[@vertex fn vertex_main(@builtin(vertex_index) id: u32) -> @builtin(position) vec4f {
  let positions=array<vec2f,3>(vec2f(-0.8,-0.8),vec2f(0.8,-0.8),vec2f(0.0,0.8));
  return vec4f(positions[id],0.0,1.0);
}
@fragment fn fragment_main() -> @location(0) vec4f { return vec4f(0.92,0.35,0.45,1.0); }
]=],
  },
  finish = function(name)
    return 'target_link_libraries(' .. name .. ' PRIVATE dawn::webgpu_dawn)\n'
  end,
}
