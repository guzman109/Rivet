return {
  setup = 'find_package(Vulkan REQUIRED COMPONENTS glslc)\n',
  source = [=[#include <vulkan/vulkan.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
namespace {
std::atomic<unsigned> validation_errors{0};
void check(VkResult result) { if (result != VK_SUCCESS) throw std::runtime_error("Vulkan result " + std::to_string(result)); }
VKAPI_ATTR VkBool32 VKAPI_CALL debug(VkDebugUtilsMessageSeverityFlagBitsEXT severity, VkDebugUtilsMessageTypeFlagsEXT, const VkDebugUtilsMessengerCallbackDataEXT *data, void *) {
  std::cerr << data->pMessage << '\n';
  if (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) ++validation_errors;
  return VK_FALSE;
}
struct Cleanup {
  std::vector<std::function<void()>> jobs;
  ~Cleanup() { for (auto it=jobs.rbegin();it!=jobs.rend();++it) (*it)(); }
};
std::vector<std::uint32_t> shader(const char *filename) {
  std::ifstream input(std::string(RIVET_SHADER_DIR)+"/"+filename,std::ios::binary|std::ios::ate);
  if (!input) throw std::runtime_error("Missing SPIR-V shader");
  auto size=input.tellg();
  if (size<=0 || size%4!=0) throw std::runtime_error("Invalid SPIR-V byte count");
  std::vector<std::uint32_t> data(static_cast<std::size_t>(size)/4);
  input.seekg(0);input.read(reinterpret_cast<char*>(data.data()),size);
  if (!input) throw std::runtime_error("Cannot read shader");return data;
}
}
int main() {
  try {
    Cleanup cleanup;
    std::uint32_t count=0;check(vkEnumerateInstanceExtensionProperties(nullptr,&count,nullptr));
    std::vector<VkExtensionProperties> available(count);check(vkEnumerateInstanceExtensionProperties(nullptr,&count,available.data()));
    auto has=[&](const char *name){return std::any_of(available.begin(),available.end(),[&](const auto &e){return std::strcmp(e.extensionName,name)==0;});};
    std::vector<const char*> extensions,layers;
    VkInstanceCreateInfo ci{};ci.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    VkApplicationInfo app{};app.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO;app.pApplicationName="Rivet Vulkan";app.apiVersion=VK_API_VERSION_1_0;ci.pApplicationInfo=&app;
    if (has(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) { extensions.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);ci.flags|=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR; }
#ifdef RIVET_VULKAN_VALIDATION
    check(vkEnumerateInstanceLayerProperties(&count,nullptr));std::vector<VkLayerProperties> layer_list(count);check(vkEnumerateInstanceLayerProperties(&count,layer_list.data()));
    if (!std::any_of(layer_list.begin(),layer_list.end(),[](const auto &l){return std::strcmp(l.layerName,"VK_LAYER_KHRONOS_validation")==0;})) throw std::runtime_error("Install the Vulkan SDK validation layers, or use Release");
    layers.push_back("VK_LAYER_KHRONOS_validation");
    if (!has(VK_EXT_DEBUG_UTILS_EXTENSION_NAME)) throw std::runtime_error("Debug-utils extension unavailable");
    extensions.push_back(VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
#endif
    ci.enabledExtensionCount=static_cast<std::uint32_t>(extensions.size());ci.ppEnabledExtensionNames=extensions.data();ci.enabledLayerCount=static_cast<std::uint32_t>(layers.size());ci.ppEnabledLayerNames=layers.data();
    VkInstance instance{};const auto status=vkCreateInstance(&ci,nullptr,&instance);
    if (status==VK_ERROR_INCOMPATIBLE_DRIVER) return 77;check(status);cleanup.jobs.push_back([=]{vkDestroyInstance(instance,nullptr);});
#ifdef RIVET_VULKAN_VALIDATION
    VkDebugUtilsMessengerCreateInfoEXT debug_ci{};debug_ci.sType=VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;debug_ci.messageSeverity=VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;debug_ci.messageType=VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;debug_ci.pfnUserCallback=debug;
    auto create_debug=reinterpret_cast<PFN_vkCreateDebugUtilsMessengerEXT>(vkGetInstanceProcAddr(instance,"vkCreateDebugUtilsMessengerEXT"));
    auto destroy_debug=reinterpret_cast<PFN_vkDestroyDebugUtilsMessengerEXT>(vkGetInstanceProcAddr(instance,"vkDestroyDebugUtilsMessengerEXT"));
    if (!create_debug || !destroy_debug) throw std::runtime_error("Missing debug-utils entry points");
    VkDebugUtilsMessengerEXT messenger{};check(create_debug(instance,&debug_ci,nullptr,&messenger));cleanup.jobs.push_back([=]{destroy_debug(instance,messenger,nullptr);});
#endif
    check(vkEnumeratePhysicalDevices(instance,&count,nullptr));if (!count) return 77;
    std::vector<VkPhysicalDevice> devices(count);check(vkEnumeratePhysicalDevices(instance,&count,devices.data()));
    VkPhysicalDevice physical{};std::uint32_t family=0;
    for (auto candidate:devices) { std::uint32_t n=0;vkGetPhysicalDeviceQueueFamilyProperties(candidate,&n,nullptr);std::vector<VkQueueFamilyProperties> queues(n);vkGetPhysicalDeviceQueueFamilyProperties(candidate,&n,queues.data());for (std::uint32_t i=0;i<n;++i) if (queues[i].queueFlags&VK_QUEUE_GRAPHICS_BIT) {physical=candidate;family=i;break;} if (physical) break; }
    if (!physical) return 77;
    const float priority=1;VkDeviceQueueCreateInfo qci{};qci.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;qci.queueFamilyIndex=family;qci.queueCount=1;qci.pQueuePriorities=&priority;
    std::vector<const char*> device_extensions;check(vkEnumerateDeviceExtensionProperties(physical,nullptr,&count,nullptr));std::vector<VkExtensionProperties> properties(count);check(vkEnumerateDeviceExtensionProperties(physical,nullptr,&count,properties.data()));
    for (const auto &e:properties) if (std::strcmp(e.extensionName,"VK_KHR_portability_subset")==0) device_extensions.push_back("VK_KHR_portability_subset");
    VkDeviceCreateInfo dci{};dci.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;dci.queueCreateInfoCount=1;dci.pQueueCreateInfos=&qci;dci.enabledExtensionCount=static_cast<std::uint32_t>(device_extensions.size());dci.ppEnabledExtensionNames=device_extensions.data();
    VkDevice device{};check(vkCreateDevice(physical,&dci,nullptr,&device));cleanup.jobs.push_back([=]{vkDeviceWaitIdle(device);vkDestroyDevice(device,nullptr);});
    VkQueue queue{};vkGetDeviceQueue(device,family,0,&queue);
    auto allocate=[&](VkMemoryRequirements req,VkMemoryPropertyFlags flags){ VkPhysicalDeviceMemoryProperties memory{};vkGetPhysicalDeviceMemoryProperties(physical,&memory);for (std::uint32_t i=0;i<memory.memoryTypeCount;++i) if ((req.memoryTypeBits&(1u<<i)) && (memory.memoryTypes[i].propertyFlags&flags)==flags) {VkMemoryAllocateInfo ai{};ai.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;ai.allocationSize=req.size;ai.memoryTypeIndex=i;VkDeviceMemory block{};check(vkAllocateMemory(device,&ai,nullptr,&block));return block;} throw std::runtime_error("No compatible device memory");};
    VkImageCreateInfo image_ci{};image_ci.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;image_ci.imageType=VK_IMAGE_TYPE_2D;image_ci.format=VK_FORMAT_R8G8B8A8_UNORM;image_ci.extent={64,64,1};image_ci.mipLevels=1;image_ci.arrayLayers=1;image_ci.samples=VK_SAMPLE_COUNT_1_BIT;image_ci.tiling=VK_IMAGE_TILING_OPTIMAL;image_ci.usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT;image_ci.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
    VkImage image{};check(vkCreateImage(device,&image_ci,nullptr,&image));VkMemoryRequirements requirements{};vkGetImageMemoryRequirements(device,image,&requirements);auto image_memory=allocate(requirements,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);check(vkBindImageMemory(device,image,image_memory,0));cleanup.jobs.push_back([=]{vkDestroyImage(device,image,nullptr);vkFreeMemory(device,image_memory,nullptr);});
    VkImageViewCreateInfo view_ci{};view_ci.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;view_ci.image=image;view_ci.viewType=VK_IMAGE_VIEW_TYPE_2D;view_ci.format=image_ci.format;view_ci.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};VkImageView view{};check(vkCreateImageView(device,&view_ci,nullptr,&view));cleanup.jobs.push_back([=]{vkDestroyImageView(device,view,nullptr);});
    VkBufferCreateInfo bci{};bci.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;bci.size=64*64*4;bci.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;bci.sharingMode=VK_SHARING_MODE_EXCLUSIVE;VkBuffer buffer{};check(vkCreateBuffer(device,&bci,nullptr,&buffer));vkGetBufferMemoryRequirements(device,buffer,&requirements);auto buffer_memory=allocate(requirements,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);check(vkBindBufferMemory(device,buffer,buffer_memory,0));cleanup.jobs.push_back([=]{vkDestroyBuffer(device,buffer,nullptr);vkFreeMemory(device,buffer_memory,nullptr);});
    VkAttachmentDescription attachment{};attachment.format=image_ci.format;attachment.samples=VK_SAMPLE_COUNT_1_BIT;attachment.loadOp=VK_ATTACHMENT_LOAD_OP_CLEAR;attachment.storeOp=VK_ATTACHMENT_STORE_OP_STORE;attachment.stencilLoadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE;attachment.stencilStoreOp=VK_ATTACHMENT_STORE_OP_DONT_CARE;attachment.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED;attachment.finalLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    VkAttachmentReference reference{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};VkSubpassDescription subpass{};subpass.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS;subpass.colorAttachmentCount=1;subpass.pColorAttachments=&reference;
    VkSubpassDependency dependency{};dependency.srcSubpass=0;dependency.dstSubpass=VK_SUBPASS_EXTERNAL;dependency.srcStageMask=VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;dependency.dstStageMask=VK_PIPELINE_STAGE_TRANSFER_BIT;dependency.srcAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;dependency.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
    VkRenderPassCreateInfo rpci{};rpci.sType=VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;rpci.attachmentCount=1;rpci.pAttachments=&attachment;rpci.subpassCount=1;rpci.pSubpasses=&subpass;rpci.dependencyCount=1;rpci.pDependencies=&dependency;VkRenderPass render_pass{};check(vkCreateRenderPass(device,&rpci,nullptr,&render_pass));cleanup.jobs.push_back([=]{vkDestroyRenderPass(device,render_pass,nullptr);});
    VkFramebufferCreateInfo fci{};fci.sType=VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;fci.renderPass=render_pass;fci.attachmentCount=1;fci.pAttachments=&view;fci.width=64;fci.height=64;fci.layers=1;VkFramebuffer framebuffer{};check(vkCreateFramebuffer(device,&fci,nullptr,&framebuffer));cleanup.jobs.push_back([=]{vkDestroyFramebuffer(device,framebuffer,nullptr);});
    auto module=[&](const char *file){auto code=shader(file);VkShaderModuleCreateInfo sci{};sci.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;sci.codeSize=code.size()*4;sci.pCode=code.data();VkShaderModule m{};check(vkCreateShaderModule(device,&sci,nullptr,&m));cleanup.jobs.push_back([=]{vkDestroyShaderModule(device,m,nullptr);});return m;};
    std::array<VkPipelineShaderStageCreateInfo,2> stages{};for (auto &stage:stages) {stage.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;stage.pName="main";}stages[0].stage=VK_SHADER_STAGE_VERTEX_BIT;stages[0].module=module("triangle.vert.spv");stages[1].stage=VK_SHADER_STAGE_FRAGMENT_BIT;stages[1].module=module("triangle.frag.spv");
    VkPipelineLayoutCreateInfo lci{};lci.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;VkPipelineLayout layout{};check(vkCreatePipelineLayout(device,&lci,nullptr,&layout));cleanup.jobs.push_back([=]{vkDestroyPipelineLayout(device,layout,nullptr);});
    VkPipelineVertexInputStateCreateInfo vertex{};vertex.sType=VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    VkPipelineInputAssemblyStateCreateInfo assembly{};assembly.sType=VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;assembly.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkViewport viewport{0,0,64,64,0,1};VkRect2D scissor{{0,0},{64,64}};VkPipelineViewportStateCreateInfo vp{};vp.sType=VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;vp.viewportCount=1;vp.pViewports=&viewport;vp.scissorCount=1;vp.pScissors=&scissor;
    VkPipelineRasterizationStateCreateInfo raster{};raster.sType=VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;raster.polygonMode=VK_POLYGON_MODE_FILL;raster.cullMode=VK_CULL_MODE_NONE;raster.frontFace=VK_FRONT_FACE_COUNTER_CLOCKWISE;raster.lineWidth=1;
    VkPipelineMultisampleStateCreateInfo ms{};ms.sType=VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;ms.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState blend_attachment{};blend_attachment.colorWriteMask=VK_COLOR_COMPONENT_R_BIT|VK_COLOR_COMPONENT_G_BIT|VK_COLOR_COMPONENT_B_BIT|VK_COLOR_COMPONENT_A_BIT;VkPipelineColorBlendStateCreateInfo blend{};blend.sType=VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;blend.attachmentCount=1;blend.pAttachments=&blend_attachment;
    VkGraphicsPipelineCreateInfo pci{};pci.sType=VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;pci.stageCount=2;pci.pStages=stages.data();pci.pVertexInputState=&vertex;pci.pInputAssemblyState=&assembly;pci.pViewportState=&vp;pci.pRasterizationState=&raster;pci.pMultisampleState=&ms;pci.pColorBlendState=&blend;pci.layout=layout;pci.renderPass=render_pass;
    VkPipeline pipeline{};check(vkCreateGraphicsPipelines(device,VK_NULL_HANDLE,1,&pci,nullptr,&pipeline));cleanup.jobs.push_back([=]{vkDestroyPipeline(device,pipeline,nullptr);});
    VkCommandPoolCreateInfo pool_ci{};pool_ci.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;pool_ci.queueFamilyIndex=family;VkCommandPool pool{};check(vkCreateCommandPool(device,&pool_ci,nullptr,&pool));cleanup.jobs.push_back([=]{vkDestroyCommandPool(device,pool,nullptr);});
    VkCommandBufferAllocateInfo cai{};cai.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;cai.commandPool=pool;cai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;cai.commandBufferCount=1;VkCommandBuffer cmd{};check(vkAllocateCommandBuffers(device,&cai,&cmd));VkCommandBufferBeginInfo begin{};begin.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;check(vkBeginCommandBuffer(cmd,&begin));
    VkClearValue clear{};clear.color.float32[3]=1;VkRenderPassBeginInfo rbi{};rbi.sType=VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;rbi.renderPass=render_pass;rbi.framebuffer=framebuffer;rbi.renderArea=scissor;rbi.clearValueCount=1;rbi.pClearValues=&clear;vkCmdBeginRenderPass(cmd,&rbi,VK_SUBPASS_CONTENTS_INLINE);vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline);vkCmdDraw(cmd,3,1,0,0);vkCmdEndRenderPass(cmd);
    VkBufferImageCopy region{};region.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1};region.imageExtent={64,64,1};vkCmdCopyImageToBuffer(cmd,image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,buffer,1,&region);
    VkMemoryBarrier barrier{};barrier.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER;barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;barrier.dstAccessMask=VK_ACCESS_HOST_READ_BIT;vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&barrier,0,nullptr,0,nullptr);check(vkEndCommandBuffer(cmd));
    VkFenceCreateInfo fence_ci{};fence_ci.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;VkFence fence{};check(vkCreateFence(device,&fence_ci,nullptr,&fence));cleanup.jobs.push_back([=]{vkDestroyFence(device,fence,nullptr);});VkSubmitInfo submit{};submit.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;submit.commandBufferCount=1;submit.pCommandBuffers=&cmd;check(vkQueueSubmit(queue,1,&submit,fence));cleanup.jobs.push_back([=]{vkDeviceWaitIdle(device);});check(vkWaitForFences(device,1,&fence,VK_TRUE,10000000000ULL));
    void *mapped=nullptr;check(vkMapMemory(device,buffer_memory,0,VK_WHOLE_SIZE,0,&mapped));const auto *pixel=static_cast<const std::uint8_t*>(mapped)+(32*64+32)*4;const bool valid=pixel[0]>150 && pixel[3]>200;std::cout<<"Vulkan center pixel: "<<int(pixel[0])<<','<<int(pixel[1])<<','<<int(pixel[2])<<'\n';vkUnmapMemory(device,buffer_memory);
    return valid && validation_errors==0 ? 0 : 1;
  } catch (const std::exception &error) { std::cerr<<error.what()<<'\n';return 1; }
}
]=],
  shaders = {
    ['triangle.vert'] = [=[#version 450
void main() {
  const vec2 p[3]=vec2[3](vec2(-0.8,-0.8),vec2(0.8,-0.8),vec2(0.0,0.8));
  gl_Position=vec4(p[gl_VertexIndex],0.0,1.0);
}
]=],
    ['triangle.frag'] = [=[#version 450
layout(location=0) out vec4 color;
void main() { color=vec4(0.92,0.35,0.45,1.0); }
]=],
  },
  finish = function(name)
    return 'target_link_libraries('
      .. name
      .. ' PRIVATE Vulkan::Vulkan)\ntarget_compile_definitions('
      .. name
      .. ' PRIVATE "$<$<CONFIG:Debug>:RIVET_VULKAN_VALIDATION=1>")\n'
      .. [=[file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/shaders")
foreach(stage vert frag)
  add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/shaders/triangle.${stage}.spv"
    COMMAND Vulkan::glslc "${PROJECT_SOURCE_DIR}/shaders/triangle.${stage}" -o "${CMAKE_CURRENT_BINARY_DIR}/shaders/triangle.${stage}.spv"
    DEPENDS "${PROJECT_SOURCE_DIR}/shaders/triangle.${stage}" VERBATIM)
endforeach()
add_custom_target(rivet_shaders DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/shaders/triangle.vert.spv" "${CMAKE_CURRENT_BINARY_DIR}/shaders/triangle.frag.spv")
]=]
      .. 'add_dependencies('
      .. name
      .. ' rivet_shaders)\n'
  end,
}
