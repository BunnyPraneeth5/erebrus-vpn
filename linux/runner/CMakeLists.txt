cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "browser_proxy_plugin.cc"
  "main.cc"
  "my_application.cc"
  "url_scheme_registration.cc"
  "singbox_plugin.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
pkg_check_modules(EREBRUS_WEBKIT REQUIRED IMPORTED_TARGET webkit2gtk-4.1)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::EREBRUS_WEBKIT)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

if(EREBRUS_BUILD_NATIVE_TESTS)
  add_executable(url_scheme_registration_test
    "url_scheme_registration.cc"
    "url_scheme_registration_test.cc"
  )
  target_compile_features(url_scheme_registration_test PRIVATE cxx_std_14)
  target_compile_options(url_scheme_registration_test PRIVATE -Wall -Werror)
  target_link_libraries(url_scheme_registration_test PRIVATE PkgConfig::GTK)
  add_test(NAME url_scheme_registration COMMAND url_scheme_registration_test)
endif()
