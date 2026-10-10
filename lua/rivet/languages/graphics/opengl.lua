return {
  setup = 'find_package(OpenGL REQUIRED)\nfind_package(glfw3 3.3 CONFIG REQUIRED)\n',
  source = [=[#define GLFW_INCLUDE_NONE
#define GL_GLEXT_PROTOTYPES
#include <GLFW/glfw3.h>
#ifdef __APPLE__
#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl3.h>
#else
#include <GL/glcorearb.h>
#endif
#include <array>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
template<class T> T load(const char *name) {
  auto p = glfwGetProcAddress(name);
  if (!p) throw std::runtime_error(std::string("Missing GL function: ") + name);
  return reinterpret_cast<T>(p);
}
std::string read(const char *file) {
  std::ifstream stream(std::string(RIVET_SHADER_DIR) + "/" + file);
  if (!stream) throw std::runtime_error("Shader file missing");
  return {std::istreambuf_iterator<char>(stream),std::istreambuf_iterator<char>()};
}
int main(int argc,char **) {
  glfwSetErrorCallback([](int code,const char *message){ std::cerr << code << ": " << message << '\n'; });
  if (!glfwInit()) return 77;
  const bool test = argc > 1;
  glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR,3); glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR,3);
  glfwWindowHint(GLFW_OPENGL_PROFILE,GLFW_OPENGL_CORE_PROFILE);
  glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT,GLFW_TRUE);
  glfwWindowHint(GLFW_VISIBLE,test ? GLFW_FALSE : GLFW_TRUE);
  auto *window = glfwCreateWindow(640,480,"Rivet OpenGL",nullptr,nullptr);
  if (!window) { glfwTerminate(); return 77; }
  glfwMakeContextCurrent(window); glfwSwapInterval(1);
  try {
#define LOAD(name) const auto p##name = load<decltype(&name)>(#name)
    LOAD(glCreateShader); LOAD(glShaderSource); LOAD(glCompileShader); LOAD(glGetShaderiv); LOAD(glGetShaderInfoLog);
    LOAD(glCreateProgram); LOAD(glAttachShader); LOAD(glLinkProgram); LOAD(glGetProgramiv); LOAD(glGetProgramInfoLog);
    LOAD(glUseProgram); LOAD(glGenVertexArrays); LOAD(glBindVertexArray); LOAD(glDeleteVertexArrays); LOAD(glDeleteShader); LOAD(glDeleteProgram);
#undef LOAD
    auto shader = [&](GLenum stage,const char *filename) {
      const std::string source=read(filename); const char *text=source.c_str();
      GLuint value=pglCreateShader(stage); pglShaderSource(value,1,&text,nullptr); pglCompileShader(value);
      GLint ok=0; pglGetShaderiv(value,GL_COMPILE_STATUS,&ok);
      if (!ok) { char log[4096]{}; pglGetShaderInfoLog(value,sizeof(log),nullptr,log); throw std::runtime_error(log); }
      return value;
    };
    GLuint vertex=shader(GL_VERTEX_SHADER,"triangle.vert"), fragment=shader(GL_FRAGMENT_SHADER,"triangle.frag");
    GLuint program=pglCreateProgram(); pglAttachShader(program,vertex); pglAttachShader(program,fragment); pglLinkProgram(program);
    GLint linked=0; pglGetProgramiv(program,GL_LINK_STATUS,&linked);
    if (!linked) { char log[4096]{}; pglGetProgramInfoLog(program,sizeof(log),nullptr,log); throw std::runtime_error(log); }
    pglDeleteShader(vertex); pglDeleteShader(fragment);
    GLuint vao=0; pglGenVertexArrays(1,&vao); pglBindVertexArray(vao); pglUseProgram(program);
    bool valid=false;
    do {
      int width=0,height=0; glfwGetFramebufferSize(window,&width,&height);
      glViewport(0,0,width,height); glClearColor(0.05f,0.05f,0.08f,1.0f); glClear(GL_COLOR_BUFFER_BIT); glDrawArrays(GL_TRIANGLES,0,3);
      std::array<unsigned char,4> pixel{}; glReadPixels(width/2,height/2,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel.data());
      valid=pixel[0]>150 && glGetError()==GL_NO_ERROR;
      glfwSwapBuffers(window); glfwPollEvents();
    } while (!test && !glfwWindowShouldClose(window));
    pglDeleteVertexArrays(1,&vao); pglDeleteProgram(program); glfwDestroyWindow(window); glfwTerminate();
    return valid ? 0 : 1;
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; glfwDestroyWindow(window); glfwTerminate(); return 1; }
}
]=],
  shaders = {
    ['triangle.vert'] = [=[#version 330 core
void main() {
  const vec2 p[3]=vec2[3](vec2(-0.8,-0.8),vec2(0.8,-0.8),vec2(0.0,0.8));
  gl_Position=vec4(p[gl_VertexID],0.0,1.0);
}
]=],
    ['triangle.frag'] = [=[#version 330 core
out vec4 color;
void main() { color=vec4(0.92,0.35,0.45,1.0); }
]=],
  },
  finish = function(name)
    return 'target_link_libraries(' .. name .. ' PRIVATE OpenGL::GL glfw)\n'
  end,
}
