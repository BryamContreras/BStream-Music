# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(bstream_music LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "bstream_music")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)
set(CMAKE_SUPPRESS_DEVELOPER_WARNINGS 1 CACHE INTERNAL "Suppress CMake developer warnings")

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)
add_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Windows plugins invoke NuGet from CMake, while smtc_windows 1.1.0 also
# needs a small compatibility patch for hidden AppData paths.  Bootstrap the
# pinned, SHA-256-verified NuGet executable during configuration so a plain
# `flutter run -d windows` behaves the same as CI.  The script is idempotent;
# it only downloads on the first build and leaves newer smtc versions alone.
if(WIN32)
  set(BSTREAM_NUGET_DIR "$ENV{LOCALAPPDATA}/BStream Music/tools")
  set(BSTREAM_WINDOWS_BOOTSTRAP
      "${CMAKE_CURRENT_SOURCE_DIR}/../tool/ensure_windows_build_dependencies.ps1")
  if(EXISTS "${BSTREAM_WINDOWS_BOOTSTRAP}")
    execute_process(
      COMMAND powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
              -File "${BSTREAM_WINDOWS_BOOTSTRAP}"
              -RepositoryRoot "${CMAKE_CURRENT_SOURCE_DIR}/.."
              -InstallDirectory "${BSTREAM_NUGET_DIR}"
      RESULT_VARIABLE BSTREAM_BOOTSTRAP_RESULT
      OUTPUT_VARIABLE BSTREAM_BOOTSTRAP_OUTPUT
      ERROR_VARIABLE BSTREAM_BOOTSTRAP_ERROR
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_STRIP_TRAILING_WHITESPACE)
    if(NOT BSTREAM_BOOTSTRAP_RESULT EQUAL 0)
      message(FATAL_ERROR
        "Windows build dependency bootstrap failed: ${BSTREAM_BOOTSTRAP_ERROR}")
    endif()
    # find_program() in flutter_inappwebview_windows searches this CMake path.
    list(PREPEND CMAKE_PROGRAM_PATH "${BSTREAM_NUGET_DIR}")
    set(ENV{PATH} "${BSTREAM_NUGET_DIR};$ENV{PATH}")
    set(ENV{NUGET_EXE} "${BSTREAM_NUGET_DIR}/nuget.exe")
    set(ENV{NUGET_EXECUTABLE} "${BSTREAM_NUGET_DIR}/nuget.exe")
    unset(NUGET CACHE)
  endif()
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Remove external-runtime directories left by older incremental builds. The
# current integrations run in Dart and ship no companion executables.
install(CODE "
  file(REMOVE_RECURSE
    \"${CMAKE_INSTALL_PREFIX}/tools\"
    \"${CMAKE_INSTALL_PREFIX}/scripts\")
  "
  COMPONENT Runtime)

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../THIRD_PARTY_NOTICES.md"
  DESTINATION "${CMAKE_INSTALL_PREFIX}"
  CONFIGURATIONS Release Profile
  COMPONENT Runtime)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
