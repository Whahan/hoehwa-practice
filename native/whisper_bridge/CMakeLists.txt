# WhisperBridge: whisper.cpp wrapped as a Godot GDExtension (docs/v200_phone_design.md section 1.2, path A: one CMake build).
# Use native/whisper_bridge/build.ps1 (it checks the pinned commits and the NDK first). Direct use:
#   cmake -S native/whisper_bridge -B <build> -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=<ndk>/build/cmake/android.toolchain.cmake
#         -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_static
cmake_minimum_required(VERSION 3.22)
project(whisper_bridge LANGUAGES C CXX)

set(WB_DEPS "${CMAKE_CURRENT_LIST_DIR}/../_deps" CACHE PATH "folder with godot-cpp and whisper.cpp (not tracked)")
set(WB_WHISPER_COMMIT "unknown" CACHE STRING "whisper.cpp commit shown by WhisperBridge.version()")
set(WB_BRIDGE_VERSION "1" CACHE STRING "bridge version shown by WhisperBridge.version()")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "static whisper.cpp and ggml" FORCE)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release)
endif()

# ---- godot-cpp (first: on Windows it sets the static MSVC runtime in the cache, whisper.cpp then uses the same one)
set(GODOTCPP_TARGET template_release CACHE STRING "" FORCE)
add_subdirectory("${WB_DEPS}/godot-cpp" godot-cpp)

# ---- whisper.cpp + ggml, static, CPU only
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CCACHE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_ACCELERATE OFF CACHE BOOL "" FORCE)
add_subdirectory("${WB_DEPS}/whisper.cpp" whisper.cpp EXCLUDE_FROM_ALL)

# ---- the bridge
add_library(whisper_bridge SHARED
    src/register_types.cpp
    src/register_types.h
    src/whisper_bridge.cpp
    src/whisper_bridge.h
    src/model_check.cpp
    src/model_check.h
    src/wb_guard.cpp
    src/wb_guard.h
)
# godot-cpp compiles with -fno-exceptions; the guard file catches exceptions thrown inside whisper.cpp, so it needs them (not on MSVC,
# where godot-cpp sets _HAS_EXCEPTIONS=0: there the guard compiles to a plain call)
if(NOT MSVC)
    set_source_files_properties(src/wb_guard.cpp PROPERTIES COMPILE_OPTIONS "-fexceptions")
endif()
target_link_libraries(whisper_bridge PRIVATE godot-cpp whisper)
target_include_directories(whisper_bridge PRIVATE
    src
    "${WB_DEPS}/whisper.cpp/include"
    "${WB_DEPS}/whisper.cpp/ggml/include"
)
target_compile_definitions(whisper_bridge PRIVATE
    WB_WHISPER_COMMIT="${WB_WHISPER_COMMIT}"
    WB_BRIDGE_VERSION="${WB_BRIDGE_VERSION}"
)

if(ANDROID)
    set(WB_LIBNAME "whisper_bridge.android.arm64")
    set_target_properties(whisper_bridge PROPERTIES PREFIX "lib" OUTPUT_NAME "${WB_LIBNAME}")
    # only whisper_bridge_init is exported; 16 KB pages (the NDK r28 default, stated explicitly)
    target_link_options(whisper_bridge PRIVATE -Wl,--exclude-libs,ALL -Wl,--gc-sections -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384)
elseif(WIN32)
    set(WB_LIBNAME "whisper_bridge.windows.x86_64")
    set_target_properties(whisper_bridge PROPERTIES PREFIX "" OUTPUT_NAME "${WB_LIBNAME}")
else()
    message(FATAL_ERROR "WhisperBridge builds only for Android arm64 and Windows x64")
endif()

set_target_properties(whisper_bridge PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    LIBRARY_OUTPUT_DIRECTORY "$<1:${CMAKE_BINARY_DIR}/out>"
    RUNTIME_OUTPUT_DIRECTORY "$<1:${CMAKE_BINARY_DIR}/out>"
)
if(MSVC)
    set_target_properties(whisper_bridge PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded")
endif()
