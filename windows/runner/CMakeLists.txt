cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "browser_proxy_plugin.cpp"
  "deep_link_plugin.cpp"
  "flutter_window.cpp"
  "protocol_registration.cpp"
  "single_instance.cpp"
  "singbox_plugin.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

add_executable(deep_link_native_test EXCLUDE_FROM_ALL
  "tests/deep_link_native_test.cpp"
)
apply_standard_settings(deep_link_native_test)
target_compile_definitions(deep_link_native_test PRIVATE NOMINMAX)
target_include_directories(deep_link_native_test PRIVATE
  "${FLUTTER_MANAGED_DIR}/ephemeral"
  "${FLUTTER_MANAGED_DIR}/ephemeral/cpp_client_wrapper/include"
)
set_target_properties(deep_link_native_test PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/tests"
)

add_executable(browser_proxy_smoke_test EXCLUDE_FROM_ALL
  "tests/browser_proxy_smoke_test.cpp"
  "browser_proxy_plugin.cpp"
)
apply_standard_settings(browser_proxy_smoke_test)
target_compile_definitions(browser_proxy_smoke_test PRIVATE NOMINMAX)
target_include_directories(browser_proxy_smoke_test PRIVATE
  "${CMAKE_BINARY_DIR}/packages/Microsoft.Web.WebView2/build/native/include"
)
target_link_libraries(browser_proxy_smoke_test PRIVATE
  flutter flutter_wrapper_app
  "${CMAKE_BINARY_DIR}/packages/Microsoft.Web.WebView2/build/native/x64/WebView2LoaderStatic.lib"
  version.lib ole32.lib oleaut32.lib user32.lib shlwapi.lib
)
add_dependencies(browser_proxy_smoke_test webview_win_floating_DEPENDENCIES_DOWNLOAD)
set_target_properties(browser_proxy_smoke_test PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/tests"
  VS_GLOBAL_WebView2LoaderPreference Static
)
