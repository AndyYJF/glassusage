cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "desktop_glass")
project(${PROJECT_NAME} LANGUAGES CXX)
set(PLUGIN_NAME "desktop_glass_plugin")
add_library(${PLUGIN_NAME} SHARED
  "desktop_glass_plugin.cpp"
  "mini_desktop_capture.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin d3d11 dxgi)
set(desktop_glass_bundled_libraries "" PARENT_SCOPE)
